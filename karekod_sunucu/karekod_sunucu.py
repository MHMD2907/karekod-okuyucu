import tkinter as tk
from tkinter import ttk, messagebox
import threading
import os
import sys
import socket
import qrcode
import time
import winsound
import subprocess
import ctypes
import base64
import json
from werkzeug.utils import secure_filename
from datetime import datetime
from queue import Queue
from flask import Flask, request, jsonify, send_from_directory
import pyperclip
import keyboard 
import pystray
from PIL import Image, ImageTk, ImageDraw # ImageDraw eklendi

app = Flask(__name__)
ui_queue = Queue()
last_ping_time = 0

# --- HAVUZ LİSTESİ ---
TEMP_BARCODE_POOL = [] 

DESKTOP = os.path.join(os.path.expanduser('~'), 'Desktop')
IMG_PATH = os.path.join(DESKTOP, "M_ONUR_RESIMLER")
PKG_PATH = os.path.join(DESKTOP, "M_ONUR_PAKETLER")
SHARE_PATH = os.path.join(DESKTOP, "M_ONUR_PAYLASIM") 

for p in [IMG_PATH, PKG_PATH, SHARE_PATH]:
    os.makedirs(p, exist_ok=True)

def resource_path(relative_path):
    try: base_path = sys._MEIPASS
    except: base_path = os.path.abspath(".")
    return os.path.join(base_path, relative_path)

def is_admin():
    try: return ctypes.windll.shell32.IsUserAnAdmin()
    except: return False

if not is_admin():
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, " ".join(sys.argv), None, 1)
    sys.exit()
else:
    subprocess.run('netsh advfirewall firewall add rule name="MONUR_BARKOD" dir=in action=allow protocol=TCP localport=5000', shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def fast_paste(text):
    try:
        pyperclip.copy(text)
        time.sleep(0.05)
        keyboard.press_and_release('ctrl+v')
    except: pass

@app.route('/append_pool', methods=['POST'])
def append_pool():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = request.json
        added_count = 0
        if 'codes' in data and isinstance(data['codes'], list):
            for code in data['codes']:
                code = str(code).strip()
                if code and code not in TEMP_BARCODE_POOL:
                    TEMP_BARCODE_POOL.append(code)
                    added_count += 1
        elif 'code' in data: # Tekli destek
             code = str(data['code']).strip()
             if code and code not in TEMP_BARCODE_POOL:
                 TEMP_BARCODE_POOL.append(code)
                 added_count = 1

        if added_count > 0:
            timestamp = datetime.now().strftime('%H:%M:%S')
            ui_queue.put(("LOG", f"[{timestamp}] +{added_count} Adet ({len(TEMP_BARCODE_POOL)})"))
            
        return jsonify({"status": "added", "total": len(TEMP_BARCODE_POOL)}), 200
    except Exception as e: return jsonify({"status": "error"}), 500

@app.route('/clear_pool', methods=['POST'])
def clear_pool():
    global TEMP_BARCODE_POOL
    TEMP_BARCODE_POOL = []
    ui_queue.put(("LOG", "--- HAVUZ TEMİZLENDİ ---"))
    ui_queue.put(("STATUS", {'text': 'HAVUZ BOŞ', 'color': '#e74c3c'}))
    return jsonify({"status": "ok"}), 200

@app.route('/paste_pool', methods=['POST'])
def paste_pool():
    if not TEMP_BARCODE_POOL: return jsonify({"status": "empty"}), 200
    joined_codes = "\n".join(TEMP_BARCODE_POOL)
    fast_paste(joined_codes)
    count = len(TEMP_BARCODE_POOL)
    ui_queue.put(("LOG", f"AKTARILDI: {count} ADET"))
    ui_queue.put(("STATUS", {'text': 'AKTARILDI', 'color': '#2ecc71'}))
    winsound.Beep(800, 200)
    return jsonify({"status": "ok", "count": count}), 200

@app.route('/send', methods=['POST'])
def handle_barcode():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = request.json
        codes = [c.strip() for c in data.get('barcodes', []) if c.strip()]
        if not codes: return jsonify({"status": "empty"}), 200
        fast_paste(codes[0])
        keyboard.press_and_release('enter')
        ui_queue.put(("LOG", f"ANLIK: {codes[0][:15]}..."))
        winsound.Beep(700, 50)
        return jsonify({"status": "ok"}), 200
    except Exception as e: return jsonify({"error": str(e)}), 500

@app.route('/package', methods=['POST'])
def handle_package():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = request.json
        pkg_name = data.get('name', 'Paket')
        items = data.get('barcodes', [])
        joined_codes = "\n".join(items)
        ts = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
        safe_name = secure_filename(pkg_name)
        json_path = os.path.join(PKG_PATH, f"{safe_name}.json")
        with open(json_path, 'w', encoding='utf-8') as f: json.dump(items, f)

        qr = qrcode.QRCode(box_size=6, border=2)
        if len(joined_codes) < 2000: qr.add_data(joined_codes)
        else: qr.add_data(f"PKT_{pkg_name}")
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        from io import BytesIO
        buffered = BytesIO()
        img.save(buffered, format="PNG")
        img_b64 = base64.b64encode(buffered.getvalue()).decode("utf-8")

        html_content = f"""<html><head><title>{pkg_name}</title>
        <script>function copyAll(){{var c=document.getElementById("codeArea");c.select();document.execCommand("copy");alert("Kopyalandı: "+{len(items)});}}</script>
        </head><body style="text-align:center; font-family:sans-serif;">
            <h2>PAKET: {pkg_name}</h2><div>Tarih: {ts} | Adet: {len(items)}</div>
            <img src="data:image/png;base64,{img_b64}"/><br>
            <button onclick="copyAll()" style="padding:10px; background:green; color:white; cursor:pointer;">TÜMÜNÜ KOPYALA</button><br><br>
            <textarea id="codeArea" style="width:100%; height:400px;">{joined_codes}</textarea>
        </body></html>"""
        with open(os.path.join(PKG_PATH, f"{safe_name}.html"), 'w', encoding='utf-8') as f: f.write(html_content)

        ui_queue.put(("LOG", f"PAKET: {pkg_name}"))
        winsound.Beep(600, 100)
        return jsonify({"status": "ok"}), 200
    except Exception as e: return jsonify({"error": str(e)}), 500

@app.route('/get_package', methods=['GET'])
def get_package_content():
    name = request.args.get('name')
    if not name: return jsonify({"error": "No name"}), 400
    safe_name = secure_filename(name)
    json_path = os.path.join(PKG_PATH, f"{safe_name}.json")
    if os.path.exists(json_path):
        with open(json_path, 'r', encoding='utf-8') as f: return jsonify({"barcodes": json.load(f)}), 200
    return jsonify({"error": "Not found"}), 404

# --- GENEL DOSYA YÜKLEME ---
@app.route('/upload_general', methods=['POST'])
def handle_general_upload():
    if 'file' not in request.files: return jsonify({"error": "No file"}), 400
    files = request.files.getlist('file')
    count = 0
    for f in files:
        if f:
            fn = secure_filename(f.filename)
            ts = datetime.now().strftime('%Y%m%d_%H%M%S')
            f.save(os.path.join(SHARE_PATH, f"{ts}_{fn}"))
            count += 1
    if count > 0:
        ui_queue.put(("LOG", f"{count} DOSYA ALINDI"))
        winsound.Beep(1000, 100)
    return jsonify({"status": "ok"}), 200

@app.route('/upload', methods=['POST']) # Resim upload uyumluluğu
def handle_image_upload():
    if 'image' in request.files:
         # Eski yöntem (Resimler klasörüne)
         files = request.files.getlist('image')
         for f in files:
             ts = datetime.now().strftime('%Y%m%d_%H%M%S')
             f.save(os.path.join(IMG_PATH, f"{ts}_{secure_filename(f.filename)}"))
         ui_queue.put(("LOG", f"{len(files)} RESİM ALINDI"))
         winsound.Beep(1000, 100)
         return jsonify({"status": "ok"}), 200
    return handle_general_upload() # Değilse genele at

@app.route('/files', methods=['GET'])
def list_files():
    try: files = [f for f in os.listdir(SHARE_PATH) if os.path.isfile(os.path.join(SHARE_PATH, f))]; return jsonify({"files": files}), 200
    except: return jsonify({"files": []}), 200

@app.route('/files/<path:filename>', methods=['GET'])
def download_file(filename): return send_from_directory(SHARE_PATH, filename)

@app.route('/ping', methods=['GET'])
def ping(): global last_ping_time; last_ping_time = time.time(); return jsonify({"status": "ok"}), 200

def get_ip():
    try: s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('10.255.255.255', 1)); ip = s.getsockname()[0]; s.close(); return ip
    except: return '127.0.0.1'

class AppGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("M.ONUR SERVER (V59 - FIXED)")
        self.root.geometry("450x600")
        self.root.configure(bg="#202020")
        
        # --- İKON YÜKLEME (GARANTİLİ) ---
        self.icon_path = resource_path("icon.png")
        if os.path.exists(self.icon_path):
             try:
                img = tk.PhotoImage(file=self.icon_path)
                self.root.iconphoto(True, img)
             except: pass
        
        self.root.protocol('WM_DELETE_WINDOW', self.hide_window)

        f_top = tk.Frame(root, bg="#202020"); f_top.pack(side="top", fill="x", padx=15, pady=15)
        self.qr_lbl = tk.Label(f_top, bg="#202020"); self.qr_lbl.pack(side="left")
        f_info = tk.Frame(f_top, bg="#202020"); f_info.pack(side="left", fill="both", expand=True, padx=15)
        tk.Label(f_info, text="M-ONUR SERVER", font=("Arial", 16, "bold"), bg="#202020", fg="#3498db").pack(anchor="w")
        tk.Label(f_info, text=f"IP: {get_ip()}:5000", font=("Consolas", 14, "bold"), bg="#202020", fg="#f1c40f").pack(anchor="w")
        self.status = tk.Label(f_info, text="BEKLENİYOR...", bg="#202020", fg="#e74c3c", font=("Arial", 10, "bold")); self.status.pack(anchor="w", pady=5)

        f_mid = tk.Frame(root, bg="#202020"); f_mid.pack(fill="x", padx=10, pady=5)
        btn = {"font": ("Arial", 9, "bold"), "fg": "white", "height": 2, "bd": 0, "width": 10}
        tk.Button(f_mid, text="PAKETLER", bg="#2980b9", command=lambda: os.startfile(PKG_PATH), **btn).pack(side="left", padx=2)
        tk.Button(f_mid, text="DOSYALAR", bg="#8e44ad", command=lambda: os.startfile(SHARE_PATH), **btn).pack(side="left", padx=2)
        tk.Button(f_mid, text="RESİMLER", bg="#e67e22", command=lambda: os.startfile(IMG_PATH), **btn).pack(side="left", padx=2)
        tk.Button(f_mid, text="TEMİZLE", bg="#c0392b", command=lambda: self.log_list.delete(0, tk.END), **btn).pack(side="left", padx=2)

        f_log = tk.LabelFrame(root, text="Canlı Akış", bg="#202020", fg="white", font=("Arial", 9)); f_log.pack(fill="both", expand=True, padx=10, pady=10)
        self.log_list = tk.Listbox(f_log, font=("Consolas", 9), bg="#2d2d2d", fg="#ecf0f1", borderwidth=0, highlightthickness=0); self.log_list.pack(side="left", fill="both", expand=True)

        self.update_qr(); self.process_queue(); self.check_connection_timeout()
        self.tray_icon = None
        threading.Thread(target=self.setup_tray, daemon=True).start()

    def update_qr(self): img = qrcode.make(f"{get_ip()}:5000").resize((90, 90)); self.tk_img = ImageTk.PhotoImage(img); self.qr_lbl.config(image=self.tk_img)
    def process_queue(self):
        while not ui_queue.empty():
            t, d = ui_queue.get_nowait()
            if t == "STATUS": self.status.config(text=d['text'], fg=d['color'])
            elif t == "LOG": self.log_list.insert(0, d); (self.log_list.delete(99, tk.END) if self.log_list.size() > 100 else None)
        self.root.after(200, self.process_queue)
    def check_connection_timeout(self):
        if time.time() - last_ping_time > 5: self.status.config(text="CİHAZ YOK", fg="#e74c3c") 
        else: self.status.config(text="CİHAZ BAĞLI", fg="#2ecc71")
        self.root.after(1000, self.check_connection_timeout)
    
    def hide_window(self): self.root.withdraw()
    def show_window(self): self.root.deiconify(); self.root.lift()
    def quit_app(self, icon, item): icon.stop(); self.root.quit(); os._exit(0)

    def setup_tray(self):
        # Eğer icon.png yoksa program kırılmasın, otomatik kare oluştursun
        if os.path.exists(self.icon_path):
            image = Image.open(self.icon_path)
        else:
            image = Image.new('RGB', (64, 64), color=(0, 122, 204))
            d = ImageDraw.Draw(image)
            d.rectangle([16,16,48,48], fill=(255,255,255))
            
        menu = pystray.Menu(pystray.MenuItem("Göster", self.show_window, default=True), pystray.MenuItem("Kapat", self.quit_app))
        self.tray_icon = pystray.Icon("M.ONUR", image, "Barkod Sunucu", menu)
        self.tray_icon.run()

def start_flask(): app.run(host='0.0.0.0', port=5000, use_reloader=False)
if __name__ == '__main__': threading.Thread(target=start_flask, daemon=True).start(); root = tk.Tk(); gui = AppGUI(root); root.mainloop()