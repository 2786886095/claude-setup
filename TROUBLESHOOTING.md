# 故障类型与脚本行为

## 自动寻找已安装 Claude

工具依次收集 AppX/MSIX 注册、卸载注册表、运行中进程、开始菜单/桌面快捷方式、用户安装目录，以及所有固定磁盘上的有限常见移动目录。它不会递归扫描整块磁盘。候选排序固定为：

1. Anthropic 签名有效、包含 Cowork 服务组件的官方 MSIX；
2. 签名损坏但可从官方 MSIX 修复的 Claude MSIX；
3. Anthropic 签名有效的官网 EXE/便携目录；
4. 其他能够确认包含 `resources/app.asar` 的 Claude 目录。

普通 EXE 或移动版不会被直接修改，也不会被误认为能提供 Cowork 服务；脚本会保留它们，并安装官方 MSIX。

如果 AppX 注册仍存在，但默认系统路径或 `Claude.exe/resources/app.asar` 缺失，工具会把它识别为半损坏安装。`PreserveApplicationData` 只适用于松散注册的开发包，不能当作普通签名 MSIX 的数据保护。工具会先把可保留配置迁移到独立目录、排除 VM/缓存/临时文件并复核官方 MSIX 签名，之后才卸载当前用户的损坏包并重装。

## `RPC pipe closed`

优先检查 `Claude.exe` 的 Authenticode 签名。若状态为 `HashMismatch`，通常是主程序或 `app.asar` 被第三方补丁修改。脚本会下载 Anthropic 官方 MSIX，验证签名与包身份，并恢复官方版本。

## `rootfs.vhdx` / `sessiondata.vhdx` not found

脚本会区分以下情况：

- 全新安装且尚未打开 Cowork：只提示，不判断为损坏；
- 已存在 `claudevm.bundle`，但核心磁盘缺失：先检查 AppX 409/应用受保护证据；命中时保持目录原样并报告，不自动归档；
- VM 文件写入 `%APPDATA%`、读取 AppX `LocalCache`：检查 Claude 是否从 AppX 入口启动、AppX 默认卷是否为系统卷；
- 目录或文件带 Encrypted(0x4000)：保持原样并报告；该属性在 AppX 私有目录中不能安全地自动解释为经典 EFS；
- `vm_bundles` 是 junction/symlink：停止自动修复，避免移动链接指向的未知数据。

## `EXDEV: cross-device link not permitted`

可能是 `%TEMP%` 与 `%LOCALAPPDATA%` 位于不同磁盘，也可能是官方 MSIX 把同一个 C 盘上的 Roaming 与 LocalCache 暴露为不同的虚拟文件系统。脚本会修复真实跨盘的用户级 TEMP/TMP；不会创建 junction/symlink，因为 Claude 会拒绝重解析点，而且公开问题报告确认这种方式不能绕过 MSIX 边界。

## `UNKNOWN: unknown error, copyfile *.zst.*.partial` / `*.tmp`

这表示新版 Claude 已在 `rename` 失败后尝试 `copyFile`，但最终提交仍被 Windows 拒绝。若同时出现 Encrypted(0x4000)、`409/0x199`、`ERROR_APPX_FILE_NOT_ENCRYPTED` 或 `CreateVirtualDisk failed: 0x199`，应按 AppX 应用受保护存储故障处理，而不是下载速度或普通 EFS 问题。

最新版在命中上述证据后绝不改写包私有 bundle：不会解密、归档、转正 `.tmp/.partial`、自行解压写回或创建硬链接。Auto/Repair 会改用 `%LOCALAPPDATA%\Claude-3p` 独立目录，让 Claude 自己重新下载 VM；原 AppX 私有目录保留作诊断证据。

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

脚本把未来 AppX 安装的默认卷设置为 Windows 系统卷，并始终把官方 Claude MSIX 安装到该卷。它不只比较 `InstallLocation` 字符串，还通过 `GetFinalPathNameByHandleW` 解析最终物理位置，所以能识别注册在 C 盘、实际重定向到 D 盘的包。现有 Claude 优先通过 `Move-AppxPackage` 移动；失败时先迁移配置到独立目录并复核已下载官方包，随后卸载当前用户错位包、重装并再次验证物理位置。

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
# Encrypted Cowork VM bundle / Win32 87 / AppX 409

如果真实 VM 文件带 `Encrypted` 属性，而 `DecryptFileW` 返回 Win32 87，这不足以证明文件损坏；在包私有 `LocalCache` 中，它可能属于“应用程序受保护”加密。最新版绝不会再用这一组合自动触发 bundle 备份或重建。

`409 (0x199)` 的系统名称是 `ERROR_APPX_FILE_NOT_ENCRYPTED`。若 `cowork-service.log` 显示 `CreateVirtualDisk failed: 0x199`，工具会标记为上游/系统兼容性失败并停止修改。不要运行未经完整哈希与版本验证的 `fix_commit.bat`，也不要把活动 VHDX 硬链接到唯一备份；硬链接两侧共享同一文件内容，活动写入会同时改变所谓备份。

## `CreateVirtualDisk failed: 0x1772`

这与 AppX 409 不是同一种错误。0x1772 表示目标文件/目录使用了普通 EFS，而运行 `CoworkVMService` 的 LocalSystem 没有当前用户的解密能力。工具仅在以下条件全部满足时自动解除 EFS：

1. 活动数据目录来自 `CLAUDE_USER_DATA_DIR` 或 `--user-data-dir`；
2. 路径位于当前用户的 `LocalAppData`，且不在 `Packages`/`WindowsApps` 中；
3. 路径及父级不是重解析点；
4. 当前用户能读取加密文件；
5. 日志明确出现当前 0x1772，且它尚未被后续完整的 VM、Daemon、Network、API 成功序列覆盖。

不满足任意一项时只报告，不调用 `DecryptFileW`。

自动解密范围只包括活动数据根目录、`vm_bundles`、`claudevm.bundle` 和五个 VM 运行文件。会话 `.jsonl`、`local-agent-mode-sessions`、`claude-code-sessions`、outputs、uploads、配置及缓存即使使用 EFS，也只显示为 Info，不会阻断 Cowork 或被自动解密。

若 v1.0.x 留下的 `vm-rebuild-active.json` 仍指向 AppX 私有目录，而 Claude 已切换到健康的 `%LOCALAPPDATA%\Claude-3p`，v1.1.2 会先区分两种情况：旧备份仍存在时归档为 Superseded 并保持备份不动；旧活动目录和旧备份均已不存在时，只有当前 VM 完整、VM 关键路径无 EFS、完整成功日志成立且 Claude/cowork-svc 双签名有效，才归档为 Abandoned。若只缺一侧、路径异常或任一健康证据不足，Auto 继续失效保护并停止。

Diagnose 会把已经验证的孤立状态明确显示为“当前独立 VM 健康，Auto 对该状态只执行归档和旧 RunOnce 清理，随后继续常规安装验证”；无法验证的孤立状态会单独提示缺少的健康或签名条件，不再误称重建仍在正常进行。
