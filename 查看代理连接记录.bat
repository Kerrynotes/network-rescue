@echo off
chcp 65001 >nul
set "DATA=%LOCALAPPDATA%\KerryNetworkRescue\monitor_data"
if not exist "%DATA%" (
  echo 尚未安装断网急救。请先双击“安装断网急救.bat”。
  echo.
  pause
  exit /b 1
)
start "代理连接记录" explorer.exe "%DATA%"
