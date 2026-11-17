@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-OpenCode-Local.ps1" %*
exit /b %errorlevel%
