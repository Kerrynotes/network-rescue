@echo off
chcp 65001 >nul
start "断网急救" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0Watch-NetworkOwnership.ps1"

