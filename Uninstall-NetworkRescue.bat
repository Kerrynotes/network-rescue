@echo off
setlocal
set "INSTALLER=%~dp0Install-NetworkRescue.ps1"
if not exist "%INSTALLER%" set "INSTALLER=%LOCALAPPDATA%\KerryNetworkRescue\Install-NetworkRescue.ps1"
if not exist "%INSTALLER%" (
  echo ERROR: Install-NetworkRescue.ps1 was not found.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Mode Uninstall
if errorlevel 1 echo ERROR: Network Rescue uninstall failed.
echo.
pause
endlocal
