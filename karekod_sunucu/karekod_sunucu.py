# karekod_sunucu.py - V2.2 (2026-10-16): kompakt yan yana düzen, keskin ve küçük QR (pencere ekrana sığar)
# V2.1: kullanım kılavuzu düğmesi, açılışta telefon güncellemesini GitHub'dan otomatik alma
# V2.0: PyQt6 modern arayüz, kalıcı havuz, silme/senkron uçları, TİTCK ilaç listesi, APK güncelleme, isteğe bağlı PIN
# Eski uçlar (V59) aynen korunur: /append_pool /clear_pool /paste_pool /send /package /get_package
#                                 /upload_general /upload /files /files/<ad> /ping
import os
import sys
import re
import io
import json
import gzip
import time
import socket
import random
import threading
import subprocess
import urllib.request
from queue import Queue, Empty
from datetime import datetime, timedelta

import qrcode
from flask import Flask, request, jsonify, send_from_directory, Response
from werkzeug.utils import secure_filename

try:
    import winsound
except ImportError:          # Windows dışı (test)
    winsound = None
try:
    import pyperclip
    import keyboard
except Exception:            # Windows dışı (test)
    pyperclip = None
    keyboard = None

SURUM = "2.2"
PORT = 5000

# ---------------------------------------------------------------------------
# KLASÖRLER (eskileriyle aynı yerler) + program verisi
# ---------------------------------------------------------------------------
DESKTOP = os.path.join(os.path.expanduser('~'), 'Desktop')
IMG_PATH = os.path.join(DESKTOP, "M_ONUR_RESIMLER")
PKG_PATH = os.path.join(DESKTOP, "M_ONUR_PAKETLER")
SHARE_PATH = os.path.join(DESKTOP, "M_ONUR_PAYLASIM")
UPDATE_PATH = os.path.join(DESKTOP, "M_ONUR_GUNCELLEME")      # yeni: telefona güncelleme APK'ları
DATA_PATH = os.path.join(os.environ.get('APPDATA', os.path.expanduser('~')), 'M_ONUR_SUNUCU')
for _p in [IMG_PATH, PKG_PATH, SHARE_PATH, UPDATE_PATH, DATA_PATH]:
    os.makedirs(_p, exist_ok=True)

AYAR_DOSYA = os.path.join(DATA_PATH, "ayarlar.json")
HAVUZ_DOSYA = os.path.join(DATA_PATH, "havuz.json")
ILAC_JSON = os.path.join(DATA_PATH, "ilac_listesi.json")
ILAC_GZ = os.path.join(DATA_PATH, "ilac_listesi.json.gz")
SERVER_DIR = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__))

TITCK_SAYFA = "https://www.titck.gov.tr/dinamikmodul/43"
GITHUB_SON = "https://api.github.com/repos/MHMD2907/karekod-okuyucu/releases/latest"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) M-ONUR-Sunucu/" + SURUM}


def resource_path(relative_path):
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(os.path.dirname(__file__))
    return os.path.join(base_path, relative_path)


def json_oku(yol, varsayilan):
    try:
        with open(yol, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return varsayilan


def json_yaz(yol, veri):
    tmp = yol + ".tmp"
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(veri, f, ensure_ascii=False)
    os.replace(tmp, yol)


AYARLAR = json_oku(AYAR_DOSYA, {})
AYARLAR.setdefault("pin_aktif", False)
AYARLAR.setdefault("pin", f"{random.randint(0, 9999):04d}")
AYARLAR.setdefault("titck_son_kontrol", "")


def ayar_kaydet():
    json_yaz(AYAR_DOSYA, AYARLAR)


ayar_kaydet()

# ---------------------------------------------------------------------------
# YÖNETİCİ İZNİ + GÜVENLİK DUVARI (Windows)
# ---------------------------------------------------------------------------
def is_admin():
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return True   # Windows dışı


if os.name == 'nt' and not is_admin():
    import ctypes
    if getattr(sys, 'frozen', False):
        params = subprocess.list2cmdline(sys.argv[1:])
    else:
        params = subprocess.list2cmdline(sys.argv)          # V2.0: boşluklu yollar tırnaklanır
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1)
    sys.exit()

if os.name == 'nt':
    try:
        # V2.0: kural varsa tekrar eklenmez (eskiden her açılışta yeni kural birikiyordu)
        var = subprocess.run('netsh advfirewall firewall show rule name="MONUR_BARKOD"', shell=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not var:
            subprocess.run(f'netsh advfirewall firewall add rule name="MONUR_BARKOD" dir=in action=allow protocol=TCP localport={PORT}',
                           shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

# ---------------------------------------------------------------------------
# ORTAK DURUM
# ---------------------------------------------------------------------------
app = Flask(__name__)
ui_queue = Queue()
last_ping_time = 0
havuz_kilit = threading.Lock()


class Havuz:
    """Sıra korunan + tekrarsız + diske kaydedilen karekod havuzu (V2.0)."""

    def __init__(self):
        self.liste = [str(c) for c in json_oku(HAVUZ_DOSYA, []) if str(c).strip()]
        self.kume = set(self.liste)

    def _kaydet(self):
        try:
            json_yaz(HAVUZ_DOSYA, self.liste)
        except Exception:
            pass

    def ekle(self, kodlar):
        n = 0
        with havuz_kilit:
            for c in kodlar:
                c = str(c).strip()
                if c and c not in self.kume:
                    self.liste.append(c)
                    self.kume.add(c)
                    n += 1
            if n:
                self._kaydet()
        return n

    def cikar(self, kodlar):
        sil = {str(c).strip() for c in kodlar}
        with havuz_kilit:
            once = len(self.liste)
            self.liste = [c for c in self.liste if c not in sil]
            self.kume = set(self.liste)
            n = once - len(self.liste)
            if n:
                self._kaydet()
        return n

    def degistir(self, kodlar):
        with havuz_kilit:
            yeni, kume = [], set()
            for c in kodlar:
                c = str(c).strip()
                if c and c not in kume:
                    yeni.append(c)
                    kume.add(c)
            self.liste, self.kume = yeni, kume
            self._kaydet()

    def temizle(self):
        self.degistir([])

    def kopya(self):
        with havuz_kilit:
            return list(self.liste)

    def __len__(self):
        return len(self.liste)


HAVUZ = Havuz()


def log(metin):
    ui_queue.put(("LOG", f"[{datetime.now().strftime('%H:%M:%S')}] {metin}"))


def bip(f, ms):
    try:
        if winsound:
            winsound.Beep(f, ms)
    except Exception:
        pass


def fast_paste(text):
    try:
        pyperclip.copy(text)
        time.sleep(0.05)
        keyboard.press_and_release('ctrl+v')
    except Exception:
        pass


def get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'


def qr_metni():
    """Telefonun okuduğu bağlantı karekodu. PIN açıksa '#PIN' eklenir (uygulama 2.2+ anlar)."""
    t = f"{get_ip()}:{PORT}"
    if AYARLAR.get("pin_aktif"):
        t += f"#{AYARLAR['pin']}"
    return t


# ---------------------------------------------------------------------------
# PIN KONTROLÜ (isteğe bağlı, varsayılan kapalı)
# ---------------------------------------------------------------------------
@app.before_request
def pin_kontrol():
    if not AYARLAR.get("pin_aktif"):
        return None
    gelen = request.headers.get("X-PIN") or request.args.get("pin") or ""
    if gelen != AYARLAR.get("pin"):
        return jsonify({"status": "pin", "error": "PIN hatalı"}), 401
    return None


def _json():
    return request.get_json(silent=True) or {}


# ---------------------------------------------------------------------------
# ESKİ UÇLAR (davranış aynı)
# ---------------------------------------------------------------------------
@app.route('/append_pool', methods=['POST'])
def append_pool():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = _json()
        if isinstance(data.get('codes'), list):
            kodlar = data['codes']
        elif 'code' in data:
            kodlar = [data['code']]
        else:
            kodlar = []
        n = HAVUZ.ekle(kodlar)
        if n > 0:
            log(f"+{n} Adet ({len(HAVUZ)})")
            ui_queue.put(("HAVUZ", len(HAVUZ)))
        return jsonify({"status": "added", "total": len(HAVUZ)}), 200
    except Exception:
        return jsonify({"status": "error"}), 500


@app.route('/clear_pool', methods=['POST'])
def clear_pool():
    HAVUZ.temizle()
    log("--- HAVUZ TEMİZLENDİ ---")
    ui_queue.put(("HAVUZ", 0))
    return jsonify({"status": "ok"}), 200


@app.route('/paste_pool', methods=['POST'])
def paste_pool():
    # V2.0: telefon tam listesini gönderirse havuz önce onunla eşitlenir (sunucu yeniden başlamış olsa bile eksik yapıştırılmaz)
    data = _json()
    if isinstance(data.get('codes'), list):
        HAVUZ.degistir(data['codes'])
        ui_queue.put(("HAVUZ", len(HAVUZ)))
    kodlar = HAVUZ.kopya()
    if not kodlar:
        return jsonify({"status": "empty", "count": 0}), 200
    fast_paste("\n".join(kodlar))
    log(f"AKTARILDI: {len(kodlar)} ADET")
    bip(800, 200)
    return jsonify({"status": "ok", "count": len(kodlar)}), 200


@app.route('/send', methods=['POST'])
def handle_barcode():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = _json()
        codes = [str(c).strip() for c in data.get('barcodes', []) if str(c).strip()]
        if not codes:
            return jsonify({"status": "empty"}), 200
        fast_paste(codes[0])
        try:
            keyboard.press_and_release('enter')
        except Exception:
            pass
        log(f"ANLIK: {codes[0][:15]}...")
        bip(700, 50)
        return jsonify({"status": "ok"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def _sade(ad):
    return re.sub(r'[^A-Za-z0-9]', '', ad or '')


@app.route('/package', methods=['POST'])
def handle_package():
    global last_ping_time
    last_ping_time = time.time()
    try:
        data = _json()
        pkg_name = (data.get('name') or '').strip() or datetime.now().strftime('Paket%Y%m%d%H%M%S')
        items = [str(c) for c in data.get('barcodes', [])]
        joined_codes = "\n".join(items)
        ts = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
        safe_name = secure_filename(pkg_name) or datetime.now().strftime('Paket%Y%m%d%H%M%S')
        with open(os.path.join(PKG_PATH, f"{safe_name}.json"), 'w', encoding='utf-8') as f:
            json.dump(items, f)

        qr = qrcode.QRCode(box_size=6, border=2)
        qr.add_data(joined_codes if len(joined_codes) < 2000 else f"PKT_{safe_name}")
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        import base64
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        img_b64 = base64.b64encode(buf.getvalue()).decode("utf-8")
        from html import escape
        ad = escape(pkg_name)
        html_content = f"""<html><head><meta charset="utf-8"><title>{ad}</title>
        <script>function copyAll(){{var c=document.getElementById("codeArea");c.select();document.execCommand("copy");alert("Kopyalandı: "+{len(items)});}}</script>
        </head><body style="text-align:center; font-family:sans-serif;">
            <h2>PAKET: {ad}</h2><div>Tarih: {ts} | Adet: {len(items)}</div>
            <img src="data:image/png;base64,{img_b64}"/><br>
            <button onclick="copyAll()" style="padding:10px; background:green; color:white; cursor:pointer;">TÜMÜNÜ KOPYALA</button><br><br>
            <textarea id="codeArea" style="width:100%; height:400px;">{escape(joined_codes)}</textarea>
        </body></html>"""
        with open(os.path.join(PKG_PATH, f"{safe_name}.html"), 'w', encoding='utf-8') as f:
            f.write(html_content)
        log(f"PAKET: {pkg_name}")
        bip(600, 100)
        return jsonify({"status": "ok", "name": safe_name}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/get_package', methods=['GET'])
def get_package_content():
    name = request.args.get('name')
    if not name:
        return jsonify({"error": "No name"}), 400
    json_path = os.path.join(PKG_PATH, f"{secure_filename(name)}.json")
    if not os.path.exists(json_path):
        # V2.0: "Koli 1" -> Koli_1.json ama okutulan "Koli1"; harf/rakam sadeleştirilerek de aranır
        hedef = _sade(name).lower()
        json_path = None
        for f in os.listdir(PKG_PATH):
            if f.lower().endswith('.json') and _sade(f[:-5]).lower() == hedef:
                json_path = os.path.join(PKG_PATH, f)
                break
    if json_path and os.path.exists(json_path):
        with open(json_path, 'r', encoding='utf-8') as f:
            return jsonify({"barcodes": json.load(f)}), 200
    return jsonify({"error": "Not found"}), 404


@app.route('/upload_general', methods=['POST'])
def handle_general_upload():
    if 'file' not in request.files:
        return jsonify({"error": "No file"}), 400
    count = 0
    for f in request.files.getlist('file'):
        if f:
            fn = secure_filename(f.filename) or "dosya"
            ts = datetime.now().strftime('%Y%m%d_%H%M%S')
            f.save(os.path.join(SHARE_PATH, f"{ts}_{fn}"))
            count += 1
    if count > 0:
        log(f"{count} DOSYA ALINDI")
        bip(1000, 100)
    return jsonify({"status": "ok"}), 200


@app.route('/upload', methods=['POST'])
def handle_image_upload():
    if 'image' in request.files:
        files = request.files.getlist('image')
        for f in files:
            ts = datetime.now().strftime('%Y%m%d_%H%M%S')
            f.save(os.path.join(IMG_PATH, f"{ts}_{secure_filename(f.filename) or 'foto.jpg'}"))
        log(f"{len(files)} RESİM ALINDI")
        bip(1000, 100)
        return jsonify({"status": "ok"}), 200
    return handle_general_upload()


@app.route('/files', methods=['GET'])
def list_files():
    try:
        files = sorted((f for f in os.listdir(SHARE_PATH) if os.path.isfile(os.path.join(SHARE_PATH, f))),
                       key=lambda f: os.path.getmtime(os.path.join(SHARE_PATH, f)), reverse=True)
        return jsonify({"files": files}), 200
    except Exception:
        return jsonify({"files": []}), 200


@app.route('/files/<path:filename>', methods=['GET'])
def download_file(filename):
    return send_from_directory(SHARE_PATH, filename)


@app.route('/ping', methods=['GET'])
def ping():
    global last_ping_time
    last_ping_time = time.time()
    return jsonify({"status": "ok", "sunucu": SURUM, "havuz": len(HAVUZ),
                    "ilac_surum": ILAC_DURUM.get("surum", "")}), 200


# ---------------------------------------------------------------------------
# YENİ UÇLAR (V2.0)
# ---------------------------------------------------------------------------
@app.route('/remove_pool', methods=['POST'])
def remove_pool():
    kodlar = _json().get('codes') or []
    n = HAVUZ.cikar(kodlar)
    if n:
        log(f"-{n} Adet silindi ({len(HAVUZ)})")
        ui_queue.put(("HAVUZ", len(HAVUZ)))
    return jsonify({"status": "ok", "removed": n, "total": len(HAVUZ)}), 200


@app.route('/sync_pool', methods=['POST'])
def sync_pool():
    kodlar = _json().get('codes')
    if isinstance(kodlar, list):
        HAVUZ.degistir(kodlar)
        ui_queue.put(("HAVUZ", len(HAVUZ)))
        log(f"HAVUZ EŞİTLENDİ: {len(HAVUZ)}")
    return jsonify({"status": "ok", "total": len(HAVUZ)}), 200


@app.route('/pool', methods=['GET'])
def pool_get():
    return jsonify({"codes": HAVUZ.kopya(), "total": len(HAVUZ)}), 200


APK_DESEN = re.compile(r'^M-ONUR-KAREKOD-(\d+\.\d+\.\d+)-(\d+)\.apk$', re.I)


def son_apk():
    en = None
    for f in os.listdir(UPDATE_PATH):
        m = APK_DESEN.match(f)
        if m:
            b = int(m.group(2))
            if not en or b > en[2]:
                en = (f, m.group(1), b)
    return en


@app.route('/surum', methods=['GET'])
def surum():
    en = son_apk()
    if not en:
        return jsonify({"apk": None, "version": "", "build": 0}), 200
    return jsonify({"apk": en[0], "version": en[1], "build": en[2]}), 200


@app.route('/guncelleme/<path:filename>', methods=['GET'])
def guncelleme_indir(filename):
    return send_from_directory(UPDATE_PATH, filename, mimetype="application/vnd.android.package-archive",
                               as_attachment=True)


ILAC_DURUM = json_oku(ILAC_JSON, {})
ILAC_DURUM = {"surum": ILAC_DURUM.get("surum", ""), "adet": len(ILAC_DURUM.get("ilaclar", {}))}


@app.route('/ilac_listesi_surum', methods=['GET'])
def ilac_listesi_surum():
    return jsonify(ILAC_DURUM), 200


@app.route('/ilac_listesi', methods=['GET'])
def ilac_listesi():
    if not os.path.exists(ILAC_GZ):
        return jsonify({"error": "Liste yok"}), 404
    with open(ILAC_GZ, 'rb') as f:
        veri = f.read()
    return Response(veri, mimetype="application/json", headers={"Content-Encoding": "gzip"})


# ---------------------------------------------------------------------------
# TİTCK SKRS E-REÇETE İLAÇ LİSTESİ (V2.0)
# Sayfa: dinamikmodul/43; bağlantı: .../AKLST02DD.MM.YYYYskrserecet...xlsx
# Sayfalar: "AKTİF ÜRÜNLER LİSTESİ" + "PASİF ÜRÜNLER LİSTESİ"; başlık 3. satır, veri 4. satırdan
# Sütunlar: İlaç Adı | Barkod | ATC Kodu | ATC Adı | Firma | Reçete Türü | Durumu | ...
# ---------------------------------------------------------------------------
TITCK_LINK = re.compile(r'href="(https?://[^"]*?AKLST02(\d{2})\.(\d{2})\.(\d{4})[^"]*?\.xlsx)"', re.I)


def titck_son_bag():
    req = urllib.request.Request(TITCK_SAYFA, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        html = r.read().decode('utf-8', 'ignore')
    adaylar = [(datetime(int(y), int(m), int(d)), url) for url, d, m, y in TITCK_LINK.findall(html)]
    if not adaylar:
        raise RuntimeError("TİTCK sayfasında liste bağlantısı bulunamadı")
    return max(adaylar)


def _sutun(basliklar, *adlar):
    for i, h in enumerate(basliklar):
        h2 = re.sub(r'\s+', ' ', str(h or '')).strip().lower()
        for a in adlar:
            if h2 == a.lower():
                return i
    return None


def xlsx_ayristir(yol):
    import openpyxl
    wb = openpyxl.load_workbook(yol, read_only=True, data_only=True)
    ilaclar, surum_metni = {}, ""
    for sayfa_adi, kod in (("AKTİF", "A"), ("PASİF", "P")):
        ws = next((w for w in wb.worksheets if w.title.upper().startswith(sayfa_adi) and "ALINACAK" not in w.title.upper()), None)
        if ws is None:
            continue
        rows = ws.iter_rows(values_only=True)
        basliklar, ilk = None, []
        for r in rows:
            ilk.append(r)
            if r and any(str(c).strip() == "Barkod" for c in r if c is not None):
                basliklar = r
                break
            if len(ilk) > 10:
                break
        if basliklar is None:
            continue
        if kod == "A":
            for r in ilk:
                if r and r[0] and "arası" in str(r[0]):
                    m = re.search(r'\((.*?)\s*arası', str(r[0]))
                    surum_metni = m.group(1).strip() if m else str(r[0]).strip()
        i_ad, i_bk = _sutun(basliklar, "İlaç Adı"), _sutun(basliklar, "Barkod")
        i_atc, i_atca = _sutun(basliklar, "ATC Kodu"), _sutun(basliklar, "ATC Adı")
        i_rt = _sutun(basliklar, "Reçete Türü")
        for r in rows:
            if not r or i_bk is None or r[i_bk] is None:
                continue
            bk = re.sub(r'\D', '', str(r[i_bk]).split('.')[0])
            if not bk:
                continue
            gtin = bk.zfill(14)                       # Excel baştaki 0'ları atmış olabilir
            if kod == "P" and gtin in ilaclar:        # aktif kayıt öncelikli
                continue
            ad = re.sub(r'\s+', ' ', str(r[i_ad] or '')).strip()
            rt = str(r[i_rt] or '').strip().capitalize() if i_rt is not None else ''
            ilaclar[gtin] = [ad, str(r[i_atc] or '').strip(), str(r[i_atca] or '').strip(), rt, kod]
    wb.close()
    if len(ilaclar) < 1000:
        raise RuntimeError(f"Listede çok az ürün var ({len(ilaclar)}); dosya biçimi değişmiş olabilir")
    return {"surum": surum_metni or datetime.now().strftime('%d.%m.%Y'),
            "olusturma": datetime.now().isoformat(timespec='seconds'), "ilaclar": ilaclar}


def ilac_listesi_kaydet(veri):
    global ILAC_DURUM
    json_yaz(ILAC_JSON, veri)
    ham = json.dumps(veri, ensure_ascii=False, separators=(",", ":")).encode('utf-8')
    with open(ILAC_GZ + ".tmp", 'wb') as f:
        f.write(gzip.compress(ham, 9))
    os.replace(ILAC_GZ + ".tmp", ILAC_GZ)
    ILAC_DURUM = {"surum": veri["surum"], "adet": len(veri["ilaclar"])}
    ui_queue.put(("ILAC", ILAC_DURUM))


def titck_guncelle(zorla=False):
    """Önce klasördeki elle konmuş AKLST*.xlsx'e bakar, yoksa TİTCK'den indirir. Excel işlenince silinir."""
    try:
        yerel = sorted((f for f in os.listdir(SERVER_DIR) if re.match(r'AKLST02.*\.xlsx$', f, re.I)),
                       key=lambda f: os.path.getmtime(os.path.join(SERVER_DIR, f)), reverse=True)
        if yerel:
            yol = os.path.join(SERVER_DIR, yerel[0])
            log("İlaç listesi klasörden okunuyor...")
            veri = xlsx_ayristir(yol)
            ilac_listesi_kaydet(veri)
            for f in yerel:
                try:
                    os.remove(os.path.join(SERVER_DIR, f))
                except Exception:
                    pass
        else:
            log("TİTCK listesi kontrol ediliyor...")
            tarih, url = titck_son_bag()
            if not zorla and ILAC_DURUM.get("surum") and tarih.strftime('%d.%m.%Y') in ILAC_DURUM.get("surum", "") \
                    and os.path.exists(ILAC_GZ):
                log(f"İlaç listesi güncel ({ILAC_DURUM['surum']})")
                AYARLAR["titck_son_kontrol"] = datetime.now().isoformat(timespec='seconds')
                ayar_kaydet()
                return True
            log(f"İndiriliyor: {tarih:%d.%m.%Y} listesi")
            tmp = os.path.join(DATA_PATH, "titck_gecici.xlsx")
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as r, open(tmp, 'wb') as f:
                f.write(r.read())
            try:
                veri = xlsx_ayristir(tmp)
                veri["surum"] = f"{veri['surum']} (TİTCK {tarih:%d.%m.%Y})"
                ilac_listesi_kaydet(veri)
            finally:
                try:
                    os.remove(tmp)
                except Exception:
                    pass
        AYARLAR["titck_son_kontrol"] = datetime.now().isoformat(timespec='seconds')
        ayar_kaydet()
        log(f"İLAÇ LİSTESİ HAZIR: {ILAC_DURUM['adet']} ürün")
        return True
    except Exception as e:
        log(f"İlaç listesi hatası: {e}")
        return False


def github_apk_indir():
    """GitHub Releases'taki son APK'yı güncelleme klasörüne indirir (telefon oradan alır)."""
    try:
        log("GitHub'da son sürüm aranıyor...")
        req = urllib.request.Request(GITHUB_SON, headers={**UA, "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            rel = json.loads(r.read().decode('utf-8'))
        asset = next((a for a in rel.get("assets", []) if APK_DESEN.match(a["name"]) and "eski" not in a["name"]), None)
        if not asset:
            log("GitHub'da APK bulunamadı")
            return
        hedef = os.path.join(UPDATE_PATH, asset["name"])
        if os.path.exists(hedef) and os.path.getsize(hedef) == asset.get("size"):
            log(f"Zaten var: {asset['name']}")
            return
        req = urllib.request.Request(asset["browser_download_url"], headers=UA)
        with urllib.request.urlopen(req, timeout=300) as r, open(hedef + ".tmp", 'wb') as f:
            f.write(r.read())
        os.replace(hedef + ".tmp", hedef)
        for f in os.listdir(UPDATE_PATH):           # eski APK'lar temizlenir
            if APK_DESEN.match(f) and f != asset["name"]:
                try:
                    os.remove(os.path.join(UPDATE_PATH, f))
                except Exception:
                    pass
        log(f"YENİ APK HAZIR: {asset['name']}")
        ui_queue.put(("APK", asset["name"]))
    except Exception as e:
        log(f"APK indirme hatası: {e}")


def otomatik_kontroller():
    time.sleep(3)
    son = AYARLAR.get("titck_son_kontrol") or ""
    try:
        eski = (datetime.now() - datetime.fromisoformat(son)) > timedelta(days=6)
    except Exception:
        eski = True
    if eski or not os.path.exists(ILAC_GZ) or any(re.match(r'AKLST02.*\.xlsx$', f, re.I) for f in os.listdir(SERVER_DIR)):
        titck_guncelle()
    # V2.1: telefona hazır son APK GitHub'dan kendiliğinden alınır (varsa indirilmez)
    github_apk_indir()


def start_flask():
    app.run(host='0.0.0.0', port=PORT, use_reloader=False, threaded=True)


# ---------------------------------------------------------------------------
# ARAYÜZ (PyQt6)
# ---------------------------------------------------------------------------
from PyQt6.QtCore import Qt, QTimer, QSize
from PyQt6.QtGui import QIcon, QPixmap, QImage, QAction, QFont
from PyQt6.QtWidgets import (QApplication, QWidget, QLabel, QPushButton, QVBoxLayout, QHBoxLayout,
                             QGridLayout, QListWidget, QFrame, QSystemTrayIcon, QMenu, QMessageBox,
                             QCheckBox, QDialog, QDialogButtonBox, QTextBrowser)

KILAVUZ_HTML = """
<h2>M-ONUR Sunucu v{SURUM} – Kullanım Kılavuzu</h2>
<h3>1. Telefonu bağlama</h3>
<p>Telefonda kamerayı bu penceredeki büyük karekoda tutun; üstte <b>BAĞLI</b> yazar ve burada <b>CİHAZ BAĞLI</b> yeşil olur.
Olmazsa karekodun altındaki adresi (örn. 192.168.1.20:5000) telefonda <i>Ayarlar → PC IP</i> kutusuna yazın.</p>
<h3>2. ANLIK mod</h3>
<p>Telefonda okunan karekod, PC'de <b>imlecin bulunduğu yere</b> (Medula/TEBRP kutusu) yapıştırılır ve Enter'a basılır.
İmleci önce doğru kutuya koyun.</p>
<h3>3. LİSTE mod ve Havuz</h3>
<p>Telefonda sayılan kutular buradaki <b>HAVUZ</b>'a gelir ve diske kaydedilir (PC kapansa da kaybolmaz).
Telefonda <i>Menü → PC'ye Aktar</i> deyince havuzdaki bütün kodlar imlecin olduğu yere alt alta yapıştırılır.
<i>📋 Havuzu Göster</i> ile içeriği görebilir, <i>🧹 Havuzu Temizle</i> ile PC tarafını boşaltabilirsiniz.</p>
<h3>4. Klasörler (Masaüstü)</h3>
<ul>
<li><b>M_ONUR_PAKETLER</b> – telefonda oluşturulan paketler (karekodlu HTML + liste)</li>
<li><b>M_ONUR_PAYLASIM</b> – telefonla paylaşılan dosyalar, sayım CSV'leri</li>
<li><b>M_ONUR_RESIMLER</b> – telefondan gelen reçete fotoğrafları</li>
<li><b>M_ONUR_GUNCELLEME</b> – telefona verilecek uygulama güncellemesi (APK)</li>
</ul>
<h3>5. İlaç listesi (TİTCK)</h3>
<p>Sunucu TİTCK <i>SKRS E-Reçete İlaç ve Diğer Farmasötik Ürünler Listesi</i>'ni haftada bir kendisi kontrol edip indirir,
JSON'a çevirir, Excel'i siler. Telefon bağlanınca listeyi alır. Elle yenilemek için <i>💊 İlaç Listesini Güncelle</i>.</p>
<h3>6. Telefon güncellemesi</h3>
<p>Sunucu açılışta son telefon sürümünü internetten (GitHub) <b>M_ONUR_GUNCELLEME</b> klasörüne indirir
(<i>⬇ Telefon Güncellemesini Al</i> ile elle de yapılır). Telefon bağlandığında yeni sürümü görür ve
"Yeni sürüm var – İNDİR" diye sorar; indirilen dosya açılıp <b>GÜNCELLE</b> denir, liste ve ayarlar korunur.
Telefonun interneti varsa güncellemeyi PC olmadan da kendisi bulur.</p>
<h3>7. PIN (isteğe bağlı)</h3>
<p>Aynı Wi-Fi'daki başka cihazların bu PC'ye kod yazdırmasını engeller. <i>⚙ Ayarlar → PIN ile koru</i>.
Açınca PIN karekoda eklenir; telefonda karekodu bir kez yeniden okutun.</p>
<h3>8. Kapatma</h3>
<p>Pencerenin X'i sunucuyu kapatmaz, sağ alttaki simgeye gizler. Tamamen kapatmak için simgeye sağ tıklayıp <b>Kapat</b>.</p>
"""

STIL = """
QWidget { background:#0f1324; color:#e6e9f2; font-family:'Segoe UI'; font-size:10pt; }
QFrame#kart { background:#171c33; border:1px solid #262d4d; border-radius:14px; }
QLabel#baslik { font-size:16pt; font-weight:700; color:#ffffff; background:transparent; }
QLabel#alt { color:#8b93b5; background:transparent; }
QLabel#ip { font-family:Consolas; font-size:17pt; font-weight:700; color:#ffd166; background:transparent; }
QLabel#chip { border-radius:10px; padding:6px 10px; font-weight:600; }
QPushButton { background:#232a4a; border:1px solid #2f3863; border-radius:10px; padding:9px 10px; font-weight:600; }
QPushButton:hover { background:#2d3660; }
QPushButton#kirmizi { background:#5a1f2a; border-color:#7a2a38; }
QPushButton#kirmizi:hover { background:#73263a; }
QPushButton#mavi { background:#1f4fd1; border-color:#2b5ff0; }
QPushButton#mavi:hover { background:#2b5ff0; }
QListWidget { background:#0b0f1d; border:1px solid #262d4d; border-radius:10px; font-family:Consolas; font-size:9pt; padding:4px; }
QCheckBox { background:transparent; }
"""


def qr_pixmap(metin, boy=160):
    # V2.2: kare boyu tam piksel seçilir, ölçekleme yok -> keskin, ekrandan kolay okunur
    q = qrcode.QRCode(border=2, error_correction=qrcode.constants.ERROR_CORRECT_M)
    q.add_data(metin)
    q.make(fit=True)
    q.box_size = max(2, boy // (q.modules_count + 4))
    img = q.make_image(fill_color="black", back_color="white").convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    pm = QPixmap()
    pm.loadFromData(buf.getvalue(), "PNG")
    return pm


def ac(yol):
    try:
        os.startfile(yol)
    except Exception:
        pass


class AnaPencere(QWidget):
    def __init__(self, uygulama):
        super().__init__()
        self.uygulama = uygulama
        self.setWindowTitle(f"M-ONUR SUNUCU v{SURUM}")
        self.ikon = QIcon(resource_path("icon.png"))
        self.setWindowIcon(self.ikon)
        self.setStyleSheet(STIL)
        # V2.2: yan yana kompakt düzen (solda QR, sağda bilgiler) – pencere her ekrana sığar
        self.qr_boy = 160
        self.kucuk = True
        self.resize(580, 660)

        kok = QVBoxLayout(self)
        kok.setContentsMargins(12, 12, 12, 12)
        kok.setSpacing(8)

        kart = QFrame()
        kart.setObjectName("kart")
        kl = QHBoxLayout(kart)
        kl.setContentsMargins(12, 12, 12, 12)
        kl.setSpacing(14)
        self.qr_lbl = QLabel()
        self.qr_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.qr_lbl.setStyleSheet("background:white; border-radius:8px;")
        self.qr_lbl.setFixedSize(self.qr_boy + 12, self.qr_boy + 12)
        kl.addWidget(self.qr_lbl)

        sag = QVBoxLayout()
        sag.setSpacing(6)
        bas = QHBoxLayout()
        logo = QLabel()
        logo.setPixmap(QPixmap(resource_path("icon.png")).scaled(36, 36, Qt.AspectRatioMode.KeepAspectRatio,
                                                                  Qt.TransformationMode.SmoothTransformation))
        logo.setStyleSheet("background:transparent;")
        bas.addWidget(logo)
        b1 = QLabel("M-ONUR SUNUCU")
        b1.setObjectName("baslik")
        bas.addWidget(b1)
        bas.addStretch()
        sag.addLayout(bas)
        b2 = QLabel(f"Karekod okuyucu PC sunucusu  •  v{SURUM}")
        b2.setObjectName("alt")
        sag.addWidget(b2)
        sag.addSpacing(6)
        self.ip_lbl = QLabel()
        self.ip_lbl.setObjectName("ip")
        sag.addWidget(self.ip_lbl)
        ipucu = QLabel("Telefonda bu karekodu okutun ya da adresi telefonda Ayarlar → PC IP kutusuna yazın")
        ipucu.setObjectName("alt")
        ipucu.setWordWrap(True)
        sag.addWidget(ipucu)
        sag.addStretch()
        kl.addLayout(sag, 1)
        kok.addWidget(kart)

        # Durum çipleri
        cips = QHBoxLayout()
        self.cihaz = QLabel()
        self.cihaz.setObjectName("chip")
        self.havuz = QLabel()
        self.havuz.setObjectName("chip")
        self.ilac = QLabel()
        self.ilac.setObjectName("chip")
        for c in (self.cihaz, self.havuz, self.ilac):
            c.setAlignment(Qt.AlignmentFlag.AlignCenter)
            cips.addWidget(c)
        kok.addLayout(cips)

        # Düğmeler
        g = QGridLayout()
        g.setSpacing(8)
        dugmeler = [
            ("📦 Paketler", lambda: ac(PKG_PATH), ""), ("📁 Dosyalar", lambda: ac(SHARE_PATH), ""),
            ("🖼 Resimler", lambda: ac(IMG_PATH), ""), ("💊 İlaç Listesini Güncelle", self.ilac_guncelle, "mavi"),
            ("⬇ Telefon Güncellemesini Al", self.apk_al, "mavi"), ("📂 Güncelleme Klasörü", lambda: ac(UPDATE_PATH), ""),
            ("🧹 Havuzu Temizle", self.havuz_temizle, "kirmizi"), ("⚙ Ayarlar", self.ayarlar, ""),
            ("❓ Kullanım Kılavuzu", self.kilavuz, ""), ("📋 Havuzu Göster", self.havuz_goster, ""),
        ]
        for i, (t, f, ad) in enumerate(dugmeler):
            b = QPushButton(t)
            if ad:
                b.setObjectName(ad)
            b.clicked.connect(f)
            g.addWidget(b, i // 2, i % 2)
        kok.addLayout(g)

        # Canlı akış
        ak = QHBoxLayout()
        a1 = QLabel("Canlı Akış")
        a1.setStyleSheet("font-weight:700; background:transparent;")
        ak.addWidget(a1)
        ak.addStretch()
        temizle = QPushButton("Temizle")
        temizle.setFixedWidth(90)
        ak.addWidget(temizle)
        kok.addLayout(ak)
        self.akis = QListWidget()
        self.akis.setMinimumHeight(90)
        temizle.clicked.connect(self.akis.clear)
        kok.addWidget(self.akis, 1)

        # Tepsi (V2.0: Qt'nin kendi tepsisi; pystray'deki iş parçacığı donması yok)
        self.tepsi = QSystemTrayIcon(self.ikon, self)
        self.tepsi.setToolTip("M-ONUR Sunucu")
        m = QMenu()
        g1 = QAction("Göster", self)
        g1.triggered.connect(self.goster)
        k1 = QAction("Kapat", self)
        k1.triggered.connect(self.kapat)
        m.addAction(g1)
        m.addAction(k1)
        self.tepsi.setContextMenu(m)
        self.tepsi.activated.connect(lambda r: self.goster() if r in (QSystemTrayIcon.ActivationReason.Trigger,
                                                                     QSystemTrayIcon.ActivationReason.DoubleClick) else None)
        self.tepsi.show()

        self.qr_yenile()
        self.durum_yenile()
        self.t1 = QTimer(self)
        self.t1.timeout.connect(self.kuyruk)
        self.t1.start(200)
        self.t2 = QTimer(self)
        self.t2.timeout.connect(self.durum_yenile)
        self.t2.start(1000)
        self.t3 = QTimer(self)
        self.t3.timeout.connect(self.qr_yenile)
        self.t3.start(30000)           # IP değişirse QR güncellenir

    # --- yardımcılar
    def chip(self, lbl, metin, renk):
        lbl.setText(metin)
        lbl.setStyleSheet(f"background:{renk}; color:white; border-radius:10px; padding:6px 10px; font-weight:600;")

    def qr_yenile(self):
        t = qr_metni()
        if getattr(self, "_son_qr", None) != t:
            self._son_qr = t
            self.qr_lbl.setPixmap(qr_pixmap(t, self.qr_boy))
            pin = f"   PIN: {AYARLAR['pin']}" if AYARLAR.get("pin_aktif") else ""
            self.ip_lbl.setText(f"{get_ip()}:{PORT}{pin}")

    def durum_yenile(self):
        if time.time() - last_ping_time > 6:
            self.chip(self.cihaz, "● CİHAZ YOK", "#7a2a38")
        else:
            self.chip(self.cihaz, "● CİHAZ BAĞLI", "#1f7a4a")
        self.chip(self.havuz, f"HAVUZ: {len(HAVUZ)} kutu", "#2b3a7a")
        if ILAC_DURUM.get("adet"):
            self.chip(self.ilac, f"İLAÇ LİSTESİ: {ILAC_DURUM['adet']}", "#3d2b7a")
            self.ilac.setToolTip(ILAC_DURUM.get("surum", ""))
        else:
            self.chip(self.ilac, "İLAÇ LİSTESİ YOK", "#6b4a12")

    def kuyruk(self):
        try:
            while True:
                t, d = ui_queue.get_nowait()
                if t == "LOG":
                    self.akis.insertItem(0, d)
                    while self.akis.count() > 200:
                        self.akis.takeItem(self.akis.count() - 1)
                elif t == "APK":
                    self.tepsi.showMessage("M-ONUR", f"Telefon güncellemesi hazır: {d}")
        except Empty:
            pass

    # --- eylemler
    def ilac_guncelle(self):
        threading.Thread(target=titck_guncelle, kwargs={"zorla": True}, daemon=True).start()

    def apk_al(self):
        threading.Thread(target=github_apk_indir, daemon=True).start()

    def havuz_temizle(self):
        if QMessageBox.question(self, "Havuzu Temizle", f"PC havuzundaki {len(HAVUZ)} kutu silinsin mi?\n"
                                "(Telefondaki liste etkilenmez)") == QMessageBox.StandardButton.Yes:
            HAVUZ.temizle()
            log("--- HAVUZ TEMİZLENDİ (PC) ---")

    def ayarlar(self):
        d = QDialog(self)
        d.setWindowTitle("Ayarlar")
        d.setStyleSheet(STIL)
        lay = QVBoxLayout(d)
        cb = QCheckBox("PIN ile koru (aynı Wi-Fi'daki başka cihazlar bağlanamaz)")
        cb.setChecked(bool(AYARLAR.get("pin_aktif")))
        lay.addWidget(cb)
        pl = QLabel(f"PIN: {AYARLAR['pin']}   (karekodun içine eklenir; telefonda karekodu yeniden okutun)")
        pl.setObjectName("alt")
        pl.setWordWrap(True)
        lay.addWidget(pl)
        yeni = QPushButton("Yeni PIN üret")

        def pin_uret():
            AYARLAR["pin"] = f"{random.randint(0, 9999):04d}"
            pl.setText(f"PIN: {AYARLAR['pin']}   (karekodun içine eklenir; telefonda karekodu yeniden okutun)")
        yeni.clicked.connect(pin_uret)
        lay.addWidget(yeni)
        bilgi = QLabel(f"Veri klasörü: {DATA_PATH}")
        bilgi.setObjectName("alt")
        bilgi.setWordWrap(True)
        lay.addWidget(bilgi)
        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        bb.accepted.connect(d.accept)
        bb.rejected.connect(d.reject)
        lay.addWidget(bb)
        if d.exec():
            AYARLAR["pin_aktif"] = cb.isChecked()
            ayar_kaydet()
            self._son_qr = None
            self.qr_yenile()
            log("PIN " + ("AÇIK" if cb.isChecked() else "KAPALI"))

    def kilavuz(self):
        d = QDialog(self)
        d.setWindowTitle("Kullanım Kılavuzu")
        d.setStyleSheet(STIL)
        d.resize(620, 680)
        lay = QVBoxLayout(d)
        t = QTextBrowser()
        t.setHtml(KILAVUZ_HTML.replace("{SURUM}", SURUM))
        t.setStyleSheet("QTextBrowser{background:#0b0f1d;border:1px solid #262d4d;border-radius:10px;padding:8px;font-size:10pt;}")
        lay.addWidget(t)
        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        bb.rejected.connect(d.reject)
        lay.addWidget(bb)
        d.exec()

    def havuz_goster(self):
        kodlar = HAVUZ.kopya()
        d = QDialog(self)
        d.setWindowTitle(f"PC Havuzu ({len(kodlar)} kutu)")
        d.setStyleSheet(STIL)
        d.resize(620, 520)
        lay = QVBoxLayout(d)
        lst = QListWidget()
        ilaclar = json_oku(ILAC_JSON, {}).get("ilaclar", {}) if kodlar else {}
        for c in kodlar:
            g = c[2:16] if c.startswith("01") and len(c) >= 16 else ""
            ad = (ilaclar.get(g) or [""])[0]
            lst.addItem(f"{ad[:40]:<40}  {c}" if ad else c)
        lay.addWidget(lst)
        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        bb.rejected.connect(d.reject)
        lay.addWidget(bb)
        d.exec()

    def goster(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def closeEvent(self, e):
        # Kapatma düğmesi pencereyi tepsiye gizler (eskisi gibi)
        e.ignore()
        self.hide()
        self.tepsi.showMessage("M-ONUR", "Sunucu arka planda çalışıyor (sağ alttaki simge)")

    def kapat(self):
        self.tepsi.hide()
        QApplication.quit()
        os._exit(0)


def main():
    threading.Thread(target=start_flask, daemon=True).start()
    threading.Thread(target=otomatik_kontroller, daemon=True).start()
    uyg = QApplication(sys.argv)
    uyg.setQuitOnLastWindowClosed(False)
    p = AnaPencere(uyg)
    p.show()
    log(f"Sunucu başladı: {get_ip()}:{PORT}")
    sys.exit(uyg.exec())


if __name__ == '__main__':
    main()
