@echo off
title M.ONUR SERVER OLUŞTURUCU (AUTO-INSTALL)
color 0A

echo ===================================================
echo   1. GEREKLI KUTUPHANELER YUKLENIYOR...
echo      (pystray, pillow, qrcode, flask vb.)
echo ===================================================
pip install pystray pillow qrcode[pil] flask pyinstaller werkzeug keyboard pyperclip pystray

echo.
echo ===================================================
echo   2. ESKI DOSYALAR TEMIZLENIYOR...
echo ===================================================
rmdir /s /q build
rmdir /s /q dist
del /q *.spec

echo.
echo ===================================================
echo   3. EXE OLUSTURULUYOR (IKON GOMULUYOR)...
echo ===================================================

REM --noconsole: Siyah ekranı gizler
REM --add-data: Ikonu icine gömer
python -m PyInstaller --noconsole --onefile --icon=icon.png --add-data "icon.png;." karekod_sunucu.py

echo.
echo ===================================================
echo   ISLEM TAMAM! 
echo   EXE Dosyaniz: dist\karekod_sunucu.exe
echo ===================================================
pause 