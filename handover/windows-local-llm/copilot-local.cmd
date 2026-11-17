@echo off
powershell.exe -NoProfile -File "%~dp0Run-LocalLlm.ps1" -Client copilot %*
exit /b %errorlevel%
