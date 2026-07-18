@echo off
setlocal
set "INSTALLER=%LOCALAPPDATA%\KerryNetworkRescue\Install-NetworkRescue.ps1"
if not exist "%INSTALLER%" (
  echo ERROR: Network Rescue is not installed.
  echo Run Install-NetworkRescue.bat from the extracted release package first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Mode Start
if errorlevel 1 echo ERROR: Network Rescue could not be started.
echo.
pause
endlocal
