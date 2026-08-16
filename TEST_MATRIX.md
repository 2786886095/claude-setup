# 验证矩阵

本表区分已经实际验证的事实与尚未覆盖的环境，不把单机结果扩大成全平台保证。

| 场景 | 版本/环境 | 状态 | 证据边界 |
|---|---|---|---|
| Windows PowerShell 5.1 静态与隔离夹具 | Windows GitHub-hosted runner、本地 Windows 11 x64 | 已验证 | 每次主分支和标签 CI 执行 |
| PowerShell 7 静态与隔离夹具 | Windows GitHub-hosted runner、本地 Windows 11 x64 | 已验证 | 每次主分支和标签 CI 执行 |
| 官方 MSIX 下载、Anthropic 签名、manifest 与原子转正 | Windows 11 x64 | 已验证 | v1.2.3、v1.2.4 非破坏性真实下载 |
| 真实卸载、官方重装、孤立状态归档 | Windows 11 build 26200 x64 | 已验证 | v1.2.3 完整 E2E；不能冒充 v1.2.4 新 E2E |
| 从零 VM 三项资产下载、官方压缩哈希、Network/API | Windows 11 build 26200 x64 | 已验证 | v1.2.3 完整 E2E |
| 实时/历史语义、重启分类、服务恢复证据 | Windows 11 x64 与隔离日志夹具 | 已验证 | v1.2.4 非破坏性诊断与双 PowerShell 测试 |
| Inventory/CleanupPlan 零写入与双确认清理保护 | 隔离临时 VM bundle 夹具 | 已验证 | v1.2.4；验证令牌错误拒绝及最后健康备份保护 |
| ARM64 Windows | 未覆盖 | 未验证 | 仅有代码路径与 URL 测试 |
| 企业代理、TLS 检查、透明代理 | 未覆盖 | 未验证 | 失败分类存在，不等于兼容性实测 |
| 第三方杀毒/EDR 拦截 | 未覆盖 | 未验证 | 不承诺所有产品策略兼容 |
| 非系统默认 AppX 卷、多用户并发 | 未覆盖 | 未验证 | 有检测/保护逻辑，无完整 E2E |
| 严重低速、频繁断流或超过 180 秒网络 | 部分覆盖 | 未完整验证 | 下载重试有夹具；孤立状态等待可配置到 1800 秒 |
| 全新 Windows 用户档案 | 未覆盖 | 未验证 | 需要独立实机矩阵 |

发布 ZIP 由标签工作流从 Git 跟踪文件构建，附带 SHA-256 和 GitHub/Sigstore provenance。供应链验证证明产物来源和完整性，不证明未覆盖环境一定运行成功。
