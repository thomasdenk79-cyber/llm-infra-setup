@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Copilot-Local.ps1" %*
exit /b %errorlevel%
