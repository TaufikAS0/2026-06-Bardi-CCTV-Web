@echo off
setlocal
cd /d "%~dp0"

echo Menyalakan CCTV_HACK Ghost Grid...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-bardi-cctv-web.ps1"
if errorlevel 1 (
  echo.
  echo Launcher gagal. Cek pesan error di atas.
  pause
  exit /b %errorlevel%
)

start "" "http://localhost:18081/"
exit /b 0
