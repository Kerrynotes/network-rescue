# 断网急救 v0.4.1-beta

断网急救用于处理 Windows 上多个代理客户端互相打架、退出后残留核心、TUN 或系统代理，导致无法正常上网的问题。

## 核心功能

面向普通用户只保留一个主要动作：

> 一键退出全部代理并恢复普通网络

它会：

1. 备份当前系统代理、PAC、WinHTTP、环境变量、进程、服务、端口、TUN、路由和 DNS；
2. 关闭 Windows 系统代理；
3. 请求全部已知代理客户端正常退出，最多等待 5 秒；
4. 停止已知代理服务，并精确结束残留核心；
5. 清理已知 TUN、`198.18.*` 路由、代理 DNS、WinHTTP 和本地代理环境变量；
6. 分别验证系统代理、代理残留和普通网络。

成功后会提示：

> 普通网络已经恢复；如需代理，请只打开一个客户端。

## 适合解决的问题

- Clash Verge 界面退出了，但 `verge-mihomo` 仍占用 7890；
- Clash Party 使用通用 `mihomo.exe` 时，根据安装路径识别为 Clash Party，不再误报为 Clash Verge；
- 龙猫、全球、唯兔等 FlClash 同源客户端同时运行并互相影响；
- 一个客户端开系统代理，另一个客户端开 TUN；
- 客户端 UI/Core 还在，但动态本地控制端口已经失效；
- 系统代理指向无人监听的 127.0.0.1 端口；
- TUN、`198.18.*` 路由或代理 DNS 残留；
- Codex、终端仍读取旧的本地代理环境变量。

它不负责机场线路质量，不自动登录、更新订阅、选择节点或重连。

## 安装

解压完整压缩包后，双击：

```text
安装断网急救.bat
```

普通安装写入当前用户的 `%LOCALAPPDATA%\KerryNetworkRescue`，不需要管理员权限。安装后会创建开机启动快捷方式，并显示托盘盾牌图标。

如果你在托盘菜单中选择了“退出断网急救”，不需要重新安装。双击压缩包或安装目录中的 `启动断网急救.bat`，即可恢复托盘监控。

只有停止受保护服务、清理高权限 TUN 或机器级代理设置时才需要管理员权限：

- 未安装 Helper：普通权限步骤完成后，仍有残留才弹一次 UAC；
- 安装 Helper：双击 `安装高权限Helper_仅需一次UAC.bat`，安装时确认一次 UAC，以后高权限动作仍需产品内确认，但不再弹 UAC。

## 托盘菜单

一级菜单固定为四项：

1. 网络状态；
2. 一键退出全部代理并恢复普通网络；
3. 系统代理异常时自动急救；
4. 退出断网急救。

诊断报告和运行记录仅作为内部排查能力保留，不占用新手托盘菜单。

当后台检测到正在运行的龙猫云核心 `lmclientCore` 时，会自动启动龙猫云断连监控；它每 5 秒检查一次本地代理端口及代理联网情况，连续 3 次失败才记录断连。退出断网急救时，这个子监控也会一同停止。可双击 `查看龙猫云断连记录.bat` 打开记录目录。

### 网络状态

查看当前系统代理 Owner、地址、TUN、诊断状态、直连和代理联网结果。基础状态使用“项目 / 当前状态”两列表格展示；诊断说明、风险项和建议单独分段并按编号列出。发现风险时提供“退出全部代理并恢复普通网络”和“暂不处理”两个选项。选择修复后仍会显示完整清场对象并再次确认，不会直接无提示结束客户端。

### 一键退出全部代理并恢复普通网络

执行完整清场。操作前会列出准备关闭的组件并确认一次。

工具不会处理未知进程、未知网卡、未知路由或企业 PAC。

### 系统代理异常时自动急救

后台自动急救只处理两类证据充分的低风险情况。

第一类是系统代理仍开启，但本地端口已经失效：

- 系统代理开启；
- 地址是本地回环端口；
- 连续 3 次无人监听；
- 普通直连正常；
- 没有代理守护抢写设置。

第二类是退出非主客户端时，Windows 系统代理被一起误关：

- 关闭前的系统代理 Owner 和端口归属明确；
- 原代理已经通过联网检测；
- 退出的是另一个非主客户端，原 Owner 的核心和同一 PID 仍监听原端口；
- 没有 TUN 接管，也没有代理守护争抢；
- 后台再次通过原代理完成联网检测。

只有以上证据同时成立时，断网急救才把当前用户的 `ProxyEnable` 恢复为开启。单独手动关闭系统代理、主代理核心退出、端口监听者变化或代理联网失败时都不会自动重开。

自动模式不结束进程、不停止服务、不清理 TUN、不重置 DNS，也不处理节点超时。

## 使用建议

切换代理客户端时使用下面的固定顺序：

1. 点击“一键退出全部代理并恢复普通网络”；
2. 等待三项结果全部显示成功；
3. 确认普通网页能打开；
4. 只打开一个代理客户端；
5. 在该客户端里手动选择节点并连接；
6. 重启仍读取旧环境变量的 Codex、终端或其他应用。

不要同时运行多个 FlClash 同源客户端。仅修改 7890/7892 不能消除共享 Helper、服务生命周期和系统代理争用。

如果把龙猫云从 7890 改为 7892，可以避免它与仍占用 7890 的 Clash Verge 核心直接争抢同一个监听端口，但需要同时注意：

- Windows 系统代理应指向 `127.0.0.1:7892`；
- Codex、终端等已启动进程如果仍保留 `HTTP_PROXY=http://127.0.0.1:7890`，仍会继续走 7890，必须同步后重启；
- 改端口不能解决系统代理开关争抢、跨客户端 TUN 或 FlClash 同源 Helper 冲突；
- 龙猫云断连监控会自动识别 7890/7892，并优先跟随当前由龙猫云实际监听的 Windows 系统代理端口；检测到龙猫云运行后由主监控自动启动。

## CLI 兼容入口

### 完整清场

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Repair-Network.ps1 `
  -Mode EmergencyDirect `
  -AutoElevate `
  -UserConfirmed `
  -Force
```

预演：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Repair-Network.ps1 `
  -Mode EmergencyDirect `
  -WhatIf
```

### 低风险恢复

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Repair-Network.ps1 `
  -Mode RestoreDirect `
  -Force
```

### 旧模式兼容

- `StopAllClients` 映射到 `EmergencyDirect`；
- `PrepareSwitch` 和 `StopOtherClients` 已停止执行；
- `SyncApplicationProxy`、`ClearApplicationProxy` 和 `ResetDns` 保留 CLI 入口。

## 诊断状态

| 状态 | 说明 |
|---|---|
| `SharedRuntimeConflict` | 多个 FlClash 同源客户端同时运行 |
| `ClientIpcBroken` | 核心命令行指定的动态控制端口无人监听 |
| `OrphanCore` | UI 已退出，核心仍监听代理端口 |
| `StaleSystemProxy` | 系统代理指向无人监听的本地端口 |
| `MultiOwnerConflict` | 系统代理、TUN、DNS 或环境变量属于不同客户端 |
| `TunResidual` | 核心退出后仍有已知 TUN 接管 |
| `ApplicationPathSplit` | 浏览器和 Codex/终端走不同代理路径 |
| `ProxyPathDegraded` | 本地端口正常，但多个代理目标失败 |
| `LocalNetworkFailure` | 普通直连也失败 |

## 安全边界

- 只结束适配器白名单中的进程；Clash Party 等通用 Mihomo 客户端还必须匹配专属安装路径；
- 结束前重新核对 PID、名称、路径和启动时间；只有名称、路径均无法确认时保持“未知客户端”并拒绝结束；
- Helper 只接受固定 `ClientId` 和固定动作；
- 不调用机场客户端自己的共享 `/stop` 接口；
- 不保存账号、订阅、节点名称、公网 IP、Cookie 或令牌；
- UAC 取消或任何最终验收项失败时只显示“部分完成”。

## 日志和备份

- 备份：`backups\network-backup-*.json`；
- 动作日志：`repair-actions.log`；
- 监控日志：`monitor_data\monitor.log`；
- 结构化事件：`monitor_data\monitor-events.jsonl`；
- 最后修复结果：`monitor_data\last-repair-result.json`；
- 扫描报告：`reports\network-ownership-*`。

后台文件使用固定保留上限，不会无限增长：

- 监控日志、修复动作日志、龙猫云断连监控日志和 Helper 日志：单文件最大 2 MB，保留 3 份归档；
- 结构化事件：单文件最大 5 MB，保留 3 份归档；
- 龙猫云断连记录：保留最近 180 天，同时最多保留 5000 条；
- `latest-state.json`、`龙猫云当前状态.json`和 `last-repair-result.json` 每次覆盖写入，只保留最新状态。

升级安装不会覆盖现有日志和备份。

## 卸载

双击：

```text
卸载断网急救.bat
```

卸载会停止托盘监控并移除开机启动项，但保留安装目录、日志和备份。卸载高权限 Helper 需要管理员权限。

## 文件说明

普通使用只需要下面四个入口：

1. `安装断网急救.bat`：首次安装或升级；
2. `启动断网急救.bat`：手动退出后重新启动；
3. `查看龙猫云断连记录.bat`：打开断连历史和当前状态；
4. `卸载断网急救.bat`：移除开机启动并停止监控。

其余 `.ps1`、`client_adapters.json` 和 `helper` 文件夹都是程序运行所需组件，不能单独删除。`安装高权限Helper_仅需一次UAC.bat` 与 `卸载高权限Helper.bat` 是可选的管理员功能，仅在你选择安装或移除 Helper 时使用。
