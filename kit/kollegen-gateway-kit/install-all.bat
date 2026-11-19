@echo off
rem LUNI Gateway-Kit Installer - richtet alles ein (Zertifikat, CLIs, Umgebung, API-Key)
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-gateway.ps1" %*
echo.
pause
