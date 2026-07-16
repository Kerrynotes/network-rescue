@echo off
chcp 65001 >nul
echo 将退出全部已识别的代理客户端、核心和后台服务，并清理已知代理残留。
echo 完成后会分别验证系统代理、代理残留和普通网络；Codex、终端等已运行程序需要重启。
choice /C YN /N /M "是否继续？[Y/N] "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-Network.ps1" -Mode EmergencyDirect -AutoElevate -Force -UserConfirmed
echo.
pause
