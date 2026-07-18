@echo off
setlocal
set "INSTALLER=%~dp0Install-NetworkRescue.ps1"
if not exist "%INSTALLER%" (
  echo ERROR: Install-NetworkRescue.ps1 was not found.
  echo Extract the complete release package before running this file.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Mode Install
if errorlevel 1 echo ERROR: Network Rescue installation failed.
echo.
pause
endlocal
