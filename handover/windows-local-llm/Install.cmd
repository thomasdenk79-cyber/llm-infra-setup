@echo off
setlocal
title LUNI Local LLM setup

echo This launcher removes the Internet-zone marker from the bundled PowerShell
echo scripts so Windows RemoteSigned can run them. It does not change policy.
echo Continue only if you downloaded this ZIP from the trusted LUNI guide and
echo verified its SHA-256 against the value shown there.
choice /C YN /N /M "Do you trust this package and want to continue? [Y/N] "
if errorlevel 2 exit /b 1

set "LUNI_PACKAGE_DIR=%~dp0"
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { $root = $env:LUNI_PACKAGE_DIR; Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | Unblock-File; & (Join-Path $root 'Install-LocalLlm.ps1'); exit 0 } catch { Write-Error $_; exit 1 }"
set "RESULT=%ERRORLEVEL%"
set "LUNI_PACKAGE_DIR="
if not "%RESULT%"=="0" pause
exit /b %RESULT%
