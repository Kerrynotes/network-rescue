@echo off
setlocal
set "DATA=%LOCALAPPDATA%\KerryNetworkRescue\monitor_data"
if not exist "%DATA%" (
  echo ERROR: Network Rescue data directory was not found.
  echo Run Install-NetworkRescue.bat first.
  pause
  exit /b 1
)
start "Network Rescue Logs" explorer.exe "%DATA%"
endlocal
