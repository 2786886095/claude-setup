# 故障类型与脚本行为

## `RPC pipe closed`

优先检查 `Claude.exe` 的 Authenticode 签名。若状态为 `HashMismatch`，通常是主程序或 `app.asar` 被第三方补丁修改。脚本会下载 Anthropic 官方 MSIX，验证签名与包身份，并恢复官方版本。

## `rootfs.vhdx` / `sessiondata.vhdx` not found

脚本会区分以下情况：

- 全新安装且尚未打开 Cowork：只提示，不判断为损坏；
- 已存在 `claudevm.bundle`，但核心磁盘缺失：把整个旧 `vm_bundles` 目录归档到 `%ProgramData%\ClaudeSetup\backups`，再让 Claude 重建；
- VM 文件写入 `%APPDATA%`、读取 AppX `LocalCache`：检查 Claude 是否从 AppX 入口启动、AppX 默认卷是否为系统卷；
- 目录或文件有 EFS 属性：递归解密后复核；
- `vm_bundles` 是 junction/symlink：停止自动修复，避免移动链接指向的未知数据。

## `EXDEV: cross-device link not permitted`

通常是 `%TEMP%` 与 `%LOCALAPPDATA%` 位于不同磁盘。脚本把用户级 TEMP/TMP 设置回 `%LOCALAPPDATA%\Temp`，不修改系统级 TEMP。

## `CoworkVMService` 不存在

脚本先安装官方每用户 MSIX。如果服务仍未注册，再按 Anthropic 的企业部署说明使用 `Add-AppxProvisionedPackage` 预配，然后重新注册当前用户包。

## HCS、HNS 或虚拟化错误

脚本检查：

- `VirtualMachinePlatform`；
- `vmcompute` 与 `hns`；
- `hypervisorlaunchtype=Auto`；
- BIOS/UEFI 虚拟化或正在运行的 Windows Hypervisor；
- 当前系统是否可能运行在需要嵌套虚拟化的 VM/VDI 中。

启用 Windows 功能后必须使用“重新启动”，不能只关机再开机。快速启动可能保留未初始化的虚拟化状态。

## 非 C 盘 WindowsApps

脚本把未来 AppX 安装的默认卷设置为系统卷。现有 Claude 包优先通过 `Move-AppxPackage` 移动；若系统版本不支持或移动失败，脚本停止并要求先备份本地 Cowork 数据，不会擅自卸载。

## 企业设备

脚本不会绕过：

- AppLocker；
- WDAC；
- 组策略强制 EFS；
- 无管理员权限；
- 禁止嵌套虚拟化的 VDI；
- 安全软件对 Anthropic MSIX 或服务的阻止。

这些环境会生成诊断报告，交给设备管理员处理。

## 完整汉化与 Cowork

完整汉化若修改 `Claude.exe` 或 `app.asar`，会使签名失效。CoworkVMService 随后拒绝客户端并关闭 RPC 管道。工具不提供签名绕过，也不会自动启用完整汉化。

