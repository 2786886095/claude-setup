# 安全公告：AppX 应用受保护 VM 数据

## 受影响版本

请勿使用 `v1.0.4` 至 `v1.0.13`。这些版本可能仅根据 `FILE_ATTRIBUTE_ENCRYPTED (0x4000)` 把 Claude AppX 私有 `LocalCache` 中的“应用程序受保护”文件误判为可自动解密的经典用户 EFS；解密失败后，还可能把活动 `claudevm.bundle` 重命名为时间戳备份并尝试外部重建。

`v1.0.14` 起采取失效保护：命中 Encrypted(0x4000)、`UNKNOWN ... copyfile`、`ERROR_APPX_FILE_NOT_ENCRYPTED (409/0x199)` 或 `CreateVirtualDisk failed: 0x199` 时，只生成诊断，不调用 `DecryptFileW`，不移动 bundle，不转正 `.tmp/.partial`，不从外部写入 `.origin/.zst/VHDX`，也不创建硬链接。

## 已运行旧版本怎么办

1. 停止反复运行旧版安装器；不要删除任何 `claudevm.bundle.backup-*`、`foreignjunk` 或 `%ProgramData%\ClaudeSetup` 状态文件。
2. 不要运行来源不明的 `fix_commit.bat`。仅凭文件名或 12 位哈希前缀不能证明 `.tmp/.partial` 完整。
3. 不要把活动 VHDX 硬链接到唯一备份。NTFS 硬链接是同一文件的多个路径；通过活动路径发生的内容或属性变化也作用于“备份”，因此它不再是独立回滚副本。
4. 使用最新版 `diagnose.cmd` 收集只读报告，并同时保留 `C:\ProgramData\Claude\Logs\cowork-service.log`。
5. 若报告命中 `CreateVirtualDisk failed: 0x199` 且 `sessiondata.vhdx` 缺失，请向 Anthropic 反馈；本工具不会声称能绕过这一上游/系统边界。

本项目目前不会自动恢复旧版移动的 bundle。安全恢复必须先证明候选目录、官方 MSIX manifest、全部必需文件和日志状态一致，再选择不会破坏独立备份的目录级回滚方案。

## 技术依据

- Windows SDK 将 `409 (0x199)` 定义为 `ERROR_APPX_FILE_NOT_ENCRYPTED`；系统文案可用 `FormatMessage` 获取。
- Microsoft 的 `CreateVirtualDisk` 文档明确指出：承载新虚拟磁盘映像的卷不能是 EFS 加密状态；`ERROR_INVALID_PARAMETER (87)` 也有多种参数原因，不能单凭 87 推断调用者缺少包身份。
- Microsoft 的硬链接文档明确说明：多个硬链接引用同一文件，文件内容和属性变化会反映到所有链接。

参考：

- [Microsoft Learn: System Error Codes](https://learn.microsoft.com/windows/win32/debug/system-error-codes--0-499-)
- [Microsoft Learn: CreateVirtualDisk](https://learn.microsoft.com/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk)
- [Microsoft Learn: Hard links and junctions](https://learn.microsoft.com/windows/win32/fileio/hard-links-and-junctions)
