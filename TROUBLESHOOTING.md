# 故障类型与脚本行为

## 自动寻找已安装 Claude

工具依次收集 AppX/MSIX 注册、卸载注册表、运行中进程、开始菜单/桌面快捷方式、用户安装目录，以及所有固定磁盘上的有限常见移动目录。它不会递归扫描整块磁盘。候选排序固定为：

1. Anthropic 签名有效、包含 Cowork 服务组件的官方 MSIX；
2. 签名损坏但可从官方 MSIX 修复的 Claude MSIX；
3. Anthropic 签名有效的官网 EXE/便携目录；
4. 其他能够确认包含 `resources/app.asar` 的 Claude 目录。

普通 EXE 或移动版不会被直接修改，也不会被误认为能提供 Cowork 服务；脚本会保留它们，并安装官方 MSIX。

如果 AppX 注册仍存在，但默认系统路径或 `Claude.exe/resources/app.asar` 缺失，工具会把它识别为半损坏安装。支持时使用 `Remove-AppxPackage -PreserveApplicationData` 保留应用数据，再从官方 MSIX 重新注册并安装。

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

可能是 `%TEMP%` 与 `%LOCALAPPDATA%` 位于不同磁盘，也可能是官方 MSIX 把同一个 C 盘上的 Roaming 与 LocalCache 暴露为不同的虚拟文件系统。脚本会修复真实跨盘的用户级 TEMP/TMP；不会创建 junction/symlink，因为 Claude 会拒绝重解析点，而且公开问题报告确认这种方式不能绕过 MSIX 边界。

## `UNKNOWN: unknown error, copyfile *.zst.*.partial` / `*.tmp`

这表示新版 Claude 已在 `rename` 失败后尝试 `copyFile`，但 Windows MSIX 虚拟化仍阻止压缩缓存或解压后运行文件的最终提交。它不是下载速度、C 盘空间或 EFS 的同义错误。

Auto 模式会检查 package LocalCache 与真实 `%APPDATA%` 两个 bundle 目录，读取近期 Cowork 日志，并从本轮已验证 Anthropic 数字签名的官方 MSIX 中解析当前 VM manifest。`.zst.<12位校验前缀>.partial` 只有在文件名、前缀和 bundle 版本匹配时才转正，之后 Claude 必须对解压结果完成完整 SHA-256 校验；`.tmp` 运行文件则由脚本先计算完整 SHA-256，完全一致才会转正。仍被写入、带 EFS、位于重解析点或校验不一致的文件一律不处理。旧的加密 bundle 备份不会删除。

相关上游问题：[anthropics/claude-code#36642](https://github.com/anthropics/claude-code/issues/36642)、[#51384](https://github.com/anthropics/claude-code/issues/51384)、[#66778](https://github.com/anthropics/claude-code/issues/66778)。

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

脚本把未来 AppX 安装的默认卷设置为 Windows 系统卷，并始终把官方 Claude MSIX 安装到该卷。通常路径为 `C:\Program Files\WindowsApps\Claude_版本...`；如果 Windows 本身安装在其他盘，则使用相应系统盘。现有 Claude 包优先通过 `Move-AppxPackage` 移动；若系统版本不支持或移动失败，脚本停止并要求先备份本地 Cowork 数据，不会擅自卸载。

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
# Encrypted Cowork VM bundle / Win32 87

如果真实 VM 文件（如 `smol-bin.vhdx`、`rootfs.vhdx`）带 `Encrypted` 属性，而标准 `DecryptFileW` 返回 Win32 87，运行最新版 `install.bat`。脚本会采用同卷重命名备份和重启后重建流程，不会自动删除备份。

重启后若脚本返回退出码 4，请在 Claude 中进入 Cowork，等待官方 VM 下载完成，然后再次运行 `install.bat`。活动状态与完成记录位于 `%ProgramData%\ClaudeSetup`，原备份位于原 `vm_bundles` 目录。
