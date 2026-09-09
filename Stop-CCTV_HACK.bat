@echo off
setlocal
cd /d "%~dp0"

echo Mematikan CCTV_HACK Ghost Grid...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-bardi-cctv-web.ps1"
if errorlevel 1 (
  echo.
  echo Stop launcher gagal. Cek pesan error di atas.
  pause
  exit /b %errorlevel%
)

exit /b 0
