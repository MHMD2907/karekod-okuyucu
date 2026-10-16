@echo off
REM build.bat v2 – 2026-10-16: Sunucu EXE'sini bu bilgisayarda derler (normalde GitHub derliyor)
cd /d "%~dp0"
pip install -r requirements.txt pyinstaller
python -m PyInstaller --noconfirm --noconsole --onefile --icon=icon.png --add-data "icon.png;." -n Karekod_Sunucu karekod_sunucu.py
echo EXE: dist\Karekod_Sunucu.exe
pause
