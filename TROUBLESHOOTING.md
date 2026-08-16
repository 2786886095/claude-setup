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

若 v1.0.x 留下的 `vm-rebuild-active.json` 仍指向 AppX 私有目录，而 Claude 已切换到健康的 `%LOCALAPPDATA%\Claude-3p`，最新版会先区分两种情况：旧备份仍存在时归档为 Superseded 并保持备份不动；旧活动目录和引用备份均已不存在时，Auto 先安装/验证官方包，记录本次 UTC 锚点并默认等待 180 秒（可配置 30–1800 秒）。请在 Claude 中进入 Cowork；只有 VM、Daemon、Network、API 四项成功时间都不早于锚点，且当前 VM 完整、关键路径无 EFS、双签名有效时才归档 Abandoned。若超时或证据不足，状态保持不动并列出原因。

Diagnose 会区分当前未解决错误、已被后续完整成功序列覆盖的历史错误和成功事件；`CoworkVMService` 无法自行设置 recovery actions 的 Access denied 会单列为非致命警告，不会覆盖服务与 VM 的实际健康结论。无法验证的孤立状态会单独提示缺少的健康或签名条件。

正式修改前可在普通 PowerShell 中运行：

```powershell
.\ClaudeSetup.ps1 -Action Plan
```

它只向标准输出写一个 JSON 对象，不创建 `reports`/`downloads`，不请求 UAC，也不改变 AppX、服务、进程、TEMP/TMP、RunOnce、状态文件或 VM。若只想解除已经验证的旧状态阻断，请在管理员 PowerShell 中运行：

```powershell
.\ClaudeSetup.ps1 -Action ResolveLegacyState
```

该动作不会下载或安装 Claude。状态不是可证明的 Superseded/Abandoned 时会保持原文件并报错；若它仍是有效的当前重建状态，则原样保留并正常退出。

## 从 PowerShell 7、Codex 或 IDE 运行时签名模块无法加载

若旧版出现 `Microsoft.PowerShell.Security could not be loaded`、`ObjectSecurity TypeData` 重复或 `Get-AuthenticodeSignature` 不可用，不代表 Claude 签名已经损坏。常见原因是 PowerShell 7 父进程经 `cmd.exe` 把自己的 `PSModulePath` 传给 Windows PowerShell 5.1。

最新版 `install.bat` 使用系统绝对路径启动 Windows PowerShell，并只在该批处理进程内设置系统模块路径；`ClaudeSetup.ps1` 也按 `$PSHOME` 绝对路径导入安全模块。它不会调用 `setx`，不会永久覆盖用户/系统 `PSModulePath`。请使用最新版完整 ZIP 中的 `install.bat`，不要单独复制旧批处理与新脚本混用。

## 官方下载失败

官方下载最多尝试三次，并使用同目录、保持最终格式扩展名的暂存文件，例如目标 `Claude-latest-x64.msix` 对应 `Claude-latest-x64.partial.msix`。Content-Length（若服务器提供）、Anthropic 签名、包身份、架构和 SHA-256 全部在转正前验证，拒绝的候选不会覆盖已有可信缓存。请勿使用 v1.2.2 做全新安装或重装：该版的 `*.msix.partial` 命名会让 Windows Authenticode 对有效 MSIX 返回 `UnknownError`；v1.2.3 已修复。最终失败时，诊断 JSON 的 `DownloadFailure.Code` 会区分 `DOWNLOAD_DNS`、`DOWNLOAD_PROXY`、`DOWNLOAD_TLS`、`DOWNLOAD_HTTP`、`DOWNLOAD_TIMEOUT`、`DOWNLOAD_DISK`、`DOWNLOAD_EMPTY`、`DOWNLOAD_LENGTH_MISMATCH`、`DOWNLOAD_SIGNATURE_INVALID`、`DOWNLOAD_IDENTITY_INVALID`、`DOWNLOAD_ARCHITECTURE_INVALID` 与 `DOWNLOAD_UNKNOWN`，每次失败还记录候选长度和 SHA-256（若文件可读）。Claude 自己下载 VM bundle 的 CDN/代理故障只能由本项目诊断和触发官方重试，工具不会把网络问题伪装成本地文件修复成功。

## 实时 VM、历史成功与主动探测

Diagnose 分开输出 `CurrentLiveVm`、`RecentVerifiedLifecycle` 和 `LastSuccessAgeSeconds`。`CurrentLiveVm=false` 只表示当前 HCS/服务/进程组合未检测到正在运行的 Cowork VM；若最近完整生命周期仍有效，它不是新的启动失败。普通 Diagnose 不会启动服务、Claude 或 VM。

只有用户明确运行 `-Action Diagnose -ActiveProbe` 时，工具才会在 Anthropic 双签名通过后尝试启动 CoworkVMService 和 Claude，并等待当前握手/VM 证据。若尚未进入 Cowork，报告会给出 `ExpectedUserAction=OpenClaudeCowork`，不会把历史成功伪装成当前运行。

## 服务恢复动作与待重启

`service-CoworkVMService` 表示服务当前是否运行；`service-recovery-policy` 表示服务异常退出后 SCM 是否配置推荐策略。两者互不替代。报告同时查询 `sc.exe qfailure` 与 `qfailureflag`，严格要求 86400 秒重置期、三次 5000 ms 重启以及 non-crash failure flag；服务日志只写 Access Denied 而没有数字时，Win32 5 会明确标为推断。

Auto、Install、Repair 和 Diagnose 都不会修改恢复策略。确认 Claude.exe/cowork-svc.exe 签名和服务二进制路径正常后，可在管理员 PowerShell 中显式运行：

```powershell
.\ClaudeSetup.ps1 -Action ConfigureServiceRecovery -ConfirmServiceRecovery
```

该动作执行固定的两条 `sc.exe` 配置并立即重新查询；任何原始退出码非零或复核不一致都会失败，不会把部分配置报告为成功。Windows 对打包服务仍可能返回 Access Denied，这属于可观察的系统限制，不影响当前 VM 健康语义。

`pending-restart` 的 `Classification=Recommended` 表示 Windows 存在系统级待处理标记，但当前检查没有证明它阻断 Claude；`Required` 只用于 ClaudeSetup 本轮修改虚拟化先决条件、VM 重建正处于 AwaitingRestart 或 VirtualMachinePlatform 明确处于 Pending 状态。

## Cowork 需要用户进入与等待时间

孤立状态恢复不是所有场景完全无人值守。安装器能启动 Claude，但必须由用户进入 Cowork 才能产生本轮 VM、daemon、Network 和 API 新鲜证据。等待日志持续输出 `ProgressPercent`、`RemainingSeconds`、`ExpectedUserAction`、中文 `UserInstruction` 与 `MissingEvidence`，并明确提醒保持 Claude 和安装器窗口开启。可用 `-LegacyEvidenceWaitSeconds 600` 把默认 180 秒延长到 10 分钟，允许范围 30–1800 秒；超时只保留状态，不降低归档门槛。

## 备份库存与安全清理

`-Action Inventory` 和 `-Action CleanupPlan` 都是零写入 JSON 操作。它们只自动管理已知 Claude `vm_bundles` 根目录下的 `claudevm.bundle.backup-*` 和 `claudevm.bundle.*isolated*`；外部完整 E2E 备份可用 `-BackupPath` 列出，但标为 `ExternalExplicit`，工具拒绝删除。

删除必须另行执行 `CleanupBackup`。CleanupPlan 为可删除项生成 `RecommendedCleanupCommand`，其中绑定当前绝对路径与令牌；也可手动复制相同字段。令牌会在大小或最后写入时间变化后失效。工具拒绝重解析点、活动状态引用、结构不完整/不可读/带 EFS 的候选、当前活动 VM 不健康，以及会删除最后一份健康受管备份的请求。该动作不可恢复，不要把它放进无人值守 Auto 流程。

## 分享诊断报告

普通 `diagnose.cmd` 报告可能包含用户名、设备型号和绝对路径。准备公开上传时请运行 `share-diagnose.cmd` 或 `ClaudeSetup.ps1 -Action Diagnose -Redact`；输出文件名为 `claude-diagnostic-share-*`，会替换用户名、设备名、SID、邮箱、用户目录和工具工作目录。脱敏是降低泄露风险，不保证能识别日志中的所有自由文本秘密，分享前仍应人工浏览一次。
