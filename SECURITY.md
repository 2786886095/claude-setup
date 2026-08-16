# 安全公告：AppX 应用受保护 VM 数据

## 受影响版本

请勿使用 `v1.0.4` 至 `v1.0.13`。这些版本可能仅根据 `FILE_ATTRIBUTE_ENCRYPTED (0x4000)` 把 Claude AppX 私有 `LocalCache` 中的“应用程序受保护”文件误判为可自动解密的经典用户 EFS；解密失败后，还可能把活动 `claudevm.bundle` 重命名为时间戳备份并尝试外部重建。

`v1.0.14` 起采取失效保护：命中 Encrypted(0x4000)、`UNKNOWN ... copyfile`、`ERROR_APPX_FILE_NOT_ENCRYPTED (409/0x199)` 或 `CreateVirtualDisk failed: 0x199` 时，不调用 `DecryptFileW`，不移动包私有 bundle，不转正 `.tmp/.partial`，不从外部写入 `.origin/.zst/VHDX`，也不创建硬链接。

`v1.1.0` 增加一条与包私有存储隔离的恢复路径：迁移非 VM 用户配置到 `%LOCALAPPDATA%\Claude-3p`，设置 `CLAUDE_USER_DATA_DIR`，由 Claude 在独立目录重新创建 VM。包私有旧目录仍保持只读。只有独立目录同时满足路径、配置来源、当前用户可读和 0x1772/工具状态证据时，才允许通过 Unicode `DecryptFileW` 解除普通用户 EFS。

`v1.1.1` 收紧上述恢复路径：工具创建状态不再替代当前 0x1772 证据；已被后续完整 VM/Daemon/Network/API 成功序列覆盖的 0x1772 只作为历史信息。自动解密仅限 VM 关键路径，非 VM 会话和用户文件保持原样。若旧 `vm-rebuild-active.json` 精确指向 Claude AppX 私有 bundle，而当前 `%LOCALAPPDATA%\Claude-3p` 的完整 VM 已有健康证据，工具会把原状态及 Superseded 记录移动到 `state-history`，但绝不删除、解密或硬链接旧 `claudevm.bundle.backup-*`。

`v1.1.2` 处理卸载重装后遗留的孤立状态：只有状态路径结构和当前 Claude 包私有路径精确一致、旧活动 bundle 与旧备份都确认不存在、当前独立 VM 五个运行文件完整、VM 关键路径无 EFS、当前 0x1772 已消失、完整健康序列成立，并且 Claude.exe 与 cowork-svc.exe 的 Anthropic 签名均有效时，才把状态归档为 Abandoned。该分支只移动状态 JSON 和清理旧 RunOnce，不卸载 Claude、不修改当前 VM，也不会声称不存在的旧备份仍被保留。

`v1.2.0` 缩小判定与执行之间的竞态窗口：Abandoned 分类通过后，归档函数会重新读取磁盘状态，并在移动状态 JSON 的最后一刻再次复核旧路径不存在、当前五个 VM 文件的长度与最后写入时间、VM 关键 EFS 数量、当前完整健康序列及 Claude.exe/cowork-svc.exe 双签名。回执保存该证据快照；任一项变化都保持活动状态并停止。该版本还增加零写入 `-Action Plan` 和只执行状态解析的 `-Action ResolveLegacyState`。

`v1.2.1` 修复卸载官方包后孤立状态阻断重新安装的问题。只有状态结构、状态阶段、Claude 官方包族默认私有路径以及“旧活动 bundle/引用备份均不存在”全部成立，Auto 才允许先安装签名有效的官方包；旧状态在此期间保持原样。安装后会启动官方 Claude 并等待最多 90 秒，每次都重新核验独立路径、五个 VM 文件、VM 关键 EFS、完整健康日志和双签名，超时后输出全部拒绝原因并停止。该版本还固定使用系统 Windows PowerShell 5.1，并按 `$PSHOME` 绝对路径加载安全模块，避免父级 PowerShell 7/Scoop `PSModulePath` 污染签名检查；用户环境变量不会被永久修改。

`v1.2.2` 不再允许 Auto 用安装前的历史成功序列归档 Abandoned 状态。Auto 在处理两条旧路径均消失的孤立状态时记录 UTC 健康锚点，启动官方 Claude 后最多等待 180 秒；`VM started`、`sdk-daemon ready`、`Network CONNECTED`、`API REACHABLE` 四项都必须不早于该锚点。归档回执明确记录 `EvidenceFreshness=CurrentExecution` 与锚点；独立的 `ResolveLegacyState` 不启动 Claude，其回执只能标记为 `HistoricalSnapshot`，不会声称属于本次运行。该版本还增加有限下载重试、同目录临时文件、Content-Length 与最终签名/身份校验、机器可读下载失败分类、日志当前/历史分段和显式分享报告脱敏。标签发布由 GitHub Actions 构建并生成 provenance attestation。

`v1.2.2` 存在独立的全新安装/重装阻断回归：下载目标为 `.msix` 时，临时文件被命名为 `*.msix.partial`。Windows Authenticode 根据最后扩展名选择格式，因而会把字节完整、官方签名有效的 MSIX 返回为 `UnknownError`。请勿使用 v1.2.2 做全新安装或重装。`v1.2.3` 将同目录暂存/回滚文件改为 `*.partial.msix` / `*.previous.msix`，签名和 manifest 验证仍发生在覆盖可信缓存之前；失败历史增加候选长度与 SHA-256，便于区分重复内容和网络变化。该修复由同一官方 MSIX 的等字节扩展名对照和真实 Windows Authenticode 夹具验证，但未以卸载当前健康 Claude 的方式冒充新的破坏性 E2E。

`v1.2.4` 增加只读备份 `Inventory`/`CleanupPlan` 及独立的显式 `CleanupBackup`。Auto、Install、Repair、Diagnose、Plan、Inventory 和 CleanupPlan 均不会删除备份。CleanupBackup 必须同时满足：路径位于工具认可的 Claude `vm_bundles` 根目录、名称属于已知备份/隔离件、不是重解析点、未被活动重建状态引用、候选结构完整可读且无 EFS、当前活动 VM 完整且无 EFS、删除后仍至少保留一份结构验证通过的健康备份，并提交绑定路径/大小/最后写入时间的当前确认令牌。外部显式路径只列为 `ExternalExplicit`，不允许工具删除。该版本还把实时 VM 与历史生命周期、服务运行与崩溃恢复、建议重启与必需重启分别报告；普通 Diagnose 不启动 VM，只有显式 ActiveProbe 才可启动 Claude/Cowork。

`v1.2.5` 将 CoworkVMService 崩溃恢复配置保持为独立的显式动作：Auto、Install、Repair、Diagnose 和 ActiveProbe 均不会调用它。`ConfigureServiceRecovery` 只有在管理员明确提交 `-ConfirmServiceRecovery`、Claude.exe/cowork-svc.exe 双签名有效、注册服务二进制精确等于当前官方 cowork-svc.exe 时才执行固定参数；随后必须从 `qfailure`/`qfailureflag` 复核 86400 秒重置期、三次 5000 ms 重启和 non-crash failure flag。任何原始退出码或复核失败都不会报告成功。该版还为 Cowork 等待增加明确用户指引/倒计时字段，并为安全清理计划生成路径和当前令牌绑定的推荐命令；两者都不降低既有证据或删除门槛。

## 已运行旧版本怎么办

1. 停止反复运行旧版安装器；不要删除任何 `claudevm.bundle.backup-*`、`foreignjunk` 或 `%ProgramData%\ClaudeSetup` 状态文件。
2. 不要运行来源不明的 `fix_commit.bat`。仅凭文件名或 12 位哈希前缀不能证明 `.tmp/.partial` 完整。
3. 不要把活动 VHDX 硬链接到唯一备份。NTFS 硬链接是同一文件的多个路径；通过活动路径发生的内容或属性变化也作用于“备份”，因此它不再是独立回滚副本。
4. 使用最新版 `diagnose.cmd` 收集只读报告，并同时保留 `C:\ProgramData\Claude\Logs\cowork-service.log`。
5. 若报告命中 `CreateVirtualDisk failed: 0x199` 且 `sessiondata.vhdx` 缺失，可使用最新版的独立数据目录恢复路径；若迁移或后续健康验证失败，请保留报告并向 Anthropic 反馈。

本项目不会自动恢复或删除旧版移动的 bundle。最新版只能在当前独立 VM 完整且健康已证实时归档阻断流程的旧状态文件：实际存在的旧 bundle 继续作为独立恢复证据保留；若旧活动目录与备份都已不存在，Abandoned 记录会如实写入两个 `Present=false`、证据新鲜度和最后一刻快照，不会伪造恢复证据。真正的内容恢复仍必须先证明候选目录、官方 MSIX manifest、全部必需文件和日志状态一致，再选择不会破坏独立备份的目录级回滚方案。

## 技术依据

- Windows SDK 将 `409 (0x199)` 定义为 `ERROR_APPX_FILE_NOT_ENCRYPTED`；系统文案可用 `FormatMessage` 获取。
- `0x1772` 与 409 不同；它用于识别独立目录中的 EFS/虚拟磁盘创建失败，不能反向证明 AppX 私有 0x4000 是普通 EFS。
- Microsoft 的 `CreateVirtualDisk` 文档明确指出：承载新虚拟磁盘映像的卷不能是 EFS 加密状态；`ERROR_INVALID_PARAMETER (87)` 也有多种参数原因，不能单凭 87 推断调用者缺少包身份。
- Microsoft 的硬链接文档明确说明：多个硬链接引用同一文件，文件内容和属性变化会反映到所有链接。

参考：

- [Microsoft Learn: System Error Codes](https://learn.microsoft.com/windows/win32/debug/system-error-codes--0-499-)
- [Microsoft Learn: CreateVirtualDisk](https://learn.microsoft.com/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk)
- [Microsoft Learn: Hard links and junctions](https://learn.microsoft.com/windows/win32/fileio/hard-links-and-junctions)
