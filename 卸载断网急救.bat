@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NetworkRescue.ps1" -Mode Uninstall
echo.
pause

