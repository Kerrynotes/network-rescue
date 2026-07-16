@echo off
chcp 65001 >nul
set "PORT=0"
if not "%~1"=="" set "PORT=%~1"
start "龙猫云断连监控" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Monitor-LongmaoConnection.ps1" -ProxyPort %PORT%
if "%PORT%"=="0" (
  echo 龙猫云断连监控已启动，端口将自动识别 7890 或 7892。
) else (
  echo 龙猫云断连监控已启动，固定监控端口：%PORT%
)
echo 记录保存在 monitor_data\longmao_connection
