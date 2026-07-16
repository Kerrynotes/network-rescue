@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-NetworkOwnership.ps1"
echo.
pause

