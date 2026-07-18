@echo off
chcp 65001 >nul
set "INSTALLER=%LOCALAPPDATA%\KerryNetworkRescue\Install-NetworkRescue.ps1"
if not exist "%INSTALLER%" (
  echo 尚未安装断网急救。请先双击“安装断网急救.bat”。
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Mode Start
echo.
pause
