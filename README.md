# Claude Setup for Windows

一个面向 Claude Desktop 与 Cowork 的 Windows 一键安装、修复和诊断工具。

> **应该运行哪个文件？** 解压后只需双击 **`install.bat`**。
>
> `setup.cmd` 只是旧版兼容入口，会自动转交给 `install.bat`；不要把两个文件各运行一次。

## 下载

不使用 Git：

- [下载稳定版一键安装包 ZIP（解压后双击 `install.bat`）](https://github.com/2786886095/claude-setup/releases/latest/download/claude-setup-windows.zip)
- [下载 main 分支源码 ZIP](https://github.com/2786886095/claude-setup/archive/refs/heads/main.zip)

使用 Git（代码块右上角可直接复制）：

```powershell
git clone https://github.com/2786886095/claude-setup.git
cd claude-setup
.\install.bat
```

稳定版本源码归档也会出现在 [GitHub Releases](https://github.com/2786886095/claude-setup/releases) 的 `Source code (zip)` 与 `Source code (tar.gz)` 中。

它不是 Claude 或 Anthropic 的官方项目。脚本只从 Anthropic 官方地址下载 MSIX，并在安装前验证数字签名和包身份。

本工具按“一次性安装与修复”设计：成功运行一遍后即可删除，不常驻、不创建计划任务、不关闭或接管 Claude 官方自动更新。Claude 后续继续通过官方机制更新。

Claude 始终使用官方 MSIX 默认安装位置：Windows 系统 AppX 卷（一般为 `C:\Program Files\WindowsApps\Claude_版本...`）。脚本不自定义安装目录；在其他磁盘发现的 EXE/移动版只作为现有安装线索，不会被选作 Cowork 主程序。

## 解决什么问题

- 全新 Windows 10/11 安装 Claude Desktop；
- 自动寻找已安装 Claude：AppX/MSIX、卸载注册表、运行中进程、快捷方式、用户安装目录，以及所有固定磁盘上的 `Claude`/`Apps`/`Programs`/`Software`/`Tools` 常见移动目录；
- 多个安装并存时，优先选择 Anthropic 签名有效且具备 Cowork 服务组件的官方 MSIX；
- 自动适配 x64 与 ARM64；
- 检查并启用 Virtual Machine Platform；
- 检查 BIOS/UEFI 虚拟化、HCS/HNS、Hypervisor 启动设置；
- 检测 Claude 位于非系统 AppX 卷的情况；
- 修复 TEMP 与 LocalAppData 跨盘造成的 `EXDEV`；
- 修复 Windows 11 build 26200 等环境中官方 MSIX 虚拟化导致的 `UNKNOWN ... copyfile rootfs.vhdx.tmp -> rootfs.vhdx`：只接管与刚下载、签名有效的官方 MSIX manifest SHA-256 完全一致的 `rootfs.vhdx`、`vmlinuz` 和 `initrd` 临时文件，并同步 package LocalCache 与真实 Roaming 两条路径；
- 检测 EFS 加密、目录联接与 `rootfs.vhdx/sessiondata.vhdx`；
- EFS 修复只阻断实际 VM 目录、`*.vhdx`、`initrd` 和 `vmlinuz`；Claude 自带的 `.origin` 完整性元数据、`.zst` 下载归档和状态标记会保留并记为信息，避免 Win32 87 误报。
- 若真实 VM 文件无法用当前账户标准解密，脚本不会删除或覆盖它们：仅在父目录不继承加密且磁盘空间充足时，把整个 `claudevm.bundle` 同卷重命名为时间戳备份，注册一次性重启续跑，再由官方 Claude 重建。
- 修复汉化或其他修改造成的 `Claude.exe` 签名损坏；
- 诊断 `RPC pipe closed`、VHDX 缺失和 Cowork 服务故障；
- 生成可分享的 JSON 与文本报告。
- 安装或修复成功后，在当前用户桌面创建或更新 `Claude.lnk`；快捷方式使用稳定的官方 AppX 启动标识，Claude 自动更新后仍然有效。
- 桌面快捷方式优先使用官方 MSIX `Assets\Square150x150Logo.png` 生成持久化 256×256 ICO；生成时自动裁掉 PNG 外圈透明留白并保留 2 像素安全边距，不再使用偏小的灰色通用 Electron 图标。
- 启动后必须验证本轮 Claude/Cowork 官方签名握手与 RPC；若用户已请求 Cowork VM，再等待最多 120 秒验证 VM、网络和 API。尚未进入 Cowork 时明确标记为“深度检测延期”，不把未启动的 VM 误判为故障。

## 一键使用

1. 下载并解压本仓库。
2. 双击 `install.bat`（唯一推荐入口）。
3. 接受 Windows UAC 管理员确认。
4. 如果脚本提示需要重启，请重启；脚本会在登录后继续。

重启续跑使用 Windows `RunOnce` 调用同一解压目录中的 `install.bat`，只执行一次；这样 UAC 后的安装窗口会保留结果与下一步提示，不会因直接运行 PowerShell 而闪退。安装成功后脚本会主动清除该项。

`install.bat` 会根据退出码显示编号式下一步：需要重启时提示保留解压目录、重启、接受 UAC 和进入 Cowork；下载未完成时提示等待后再次运行；验证成功时确认桌面快捷方式和加密备份状态。

UAC 自提权由 `ElevateInstall.ps1` 通过系统 `cmd.exe` 启动并等待结果，不再直接把 `.bat` 传给 `Start-Process`。提权脚本从自身所在目录定位 `install.bat`，不会把末尾带反斜杠的目录作为命令行参数传递，因此兼容中文、空格及常见特殊字符路径。`install.bat` 在运行 PowerShell 主脚本前就会写入 `reports\install-bootstrap.log`，即使 UAC 或启动器失败也能诊断。

仓库通过 `.gitattributes` 强制所有 `.bat/.cmd` 使用 Windows CRLF 换行；发布测试会拒绝仅含 LF 的批处理文件，避免 `cmd.exe` 拼接行、变量截断和退出码 9009。

`setup.cmd` 仅为兼容旧下载保留，它会转交给 `install.bat`；两者不要重复运行。

只诊断、不修改系统：双击 `diagnose.cmd`。

### 加密 VM 的可回滚重建

当 `*.vhdx` 等真实运行文件带加密属性且 Windows 返回 Win32 87、无法标准解密时：

1. 脚本停止 Claude 与 `CoworkVMService`；
2. 验证 `vm_bundles` 不是重解析点、父目录不继承加密，并预留“旧 bundle 大小 + 2 GB”的可用空间；
3. 将 `claudevm.bundle` 同卷重命名为 `claudevm.bundle.backup-时间戳`，不覆盖、不跨卷复制；
4. 注册一次性重启续跑并要求重启 Windows；
5. 重启后启动官方 Claude。请进入 Cowork，让官方客户端下载并创建新的 `rootfs.vhdx` 与 `sessiondata.vhdx`；
6. 只有新 bundle 文件齐全、运行文件未加密且 Cowork 健康检查通过，脚本才结束重建状态。

若官方 Claude 在临时文件已经完成校验后仍因 MSIX 文件系统虚拟化无法将 `.tmp` 提交为正式文件，脚本会停止 Claude 冻结该临时文件，从刚下载且 Anthropic 签名有效的 MSIX 中读取当前 VM manifest，重新计算 SHA-256。只有完全匹配时才原子转正、写入对应 `.origin` 并同步两条官方数据路径；不匹配文件原样保留且不会发布。随后脚本重新启动 Claude，继续处理下一个官方 VM 文件。该流程不会修改 `Claude.exe` 或 `app.asar`。

加密备份永远不会由脚本自动删除。确认 Cowork 长期正常后，用户可以自行处理备份。

也可以在管理员 PowerShell 中运行：

```powershell
.\ClaudeSetup.ps1 -Action Auto
.\ClaudeSetup.ps1 -Action Diagnose
.\ClaudeSetup.ps1 -Action Repair
```

如需自动重启：

```powershell
.\ClaudeSetup.ps1 -Action Auto -RestartIfNeeded
```

## 支持的环境分支

| 情况 | 行为 |
|---|---|
| 未安装 Claude | 下载并验证官方 MSIX，然后安装 |
| 默认 AppX 路径不存在/核心文件缺失 | 自动下载官方 MSIX；必要时保留应用数据后重新注册并安装 |
| 已有多个 Claude | 自动优先选择签名有效、支持 Cowork 的官方 MSIX |
| 只有官网 EXE/移动版 | 识别并报告其路径，保留原目录，另行安装官方 MSIX 供 Cowork 使用 |
| Claude MSIX 位于非系统卷 | 移回 Windows 系统 AppX 默认位置 |
| 已安装且健康 | 只补齐依赖并验证 |
| `Claude.exe` 为 `HashMismatch` | 下载同版本/更新版本官方 MSIX，恢复官方核心文件 |
| Virtual Machine Platform 未启用 | 自动启用，注册重启后继续 |
| Claude 在非系统 AppX 卷 | 优先使用 `Move-AppxPackage` 移动；失败则停止并报告，不删除用户数据 |
| TEMP 与 LocalAppData 跨盘 | 恢复用户 TEMP/TMP 到 `%LOCALAPPDATA%\Temp` |
| `UNKNOWN ... copyfile rootfs.vhdx.tmp` | 按签名有效的官方 MSIX manifest 复核临时文件，校验一致后转正并同步 LocalCache/Roaming |
| VM 目录使用 EFS | 尝试解密 |
| VM 目录是 junction/reparse point | 停止并报告，避免误删大体积 VM 数据 |
| VDI/虚拟机 | 警告需要嵌套虚拟化 |
| 企业 AppLocker/策略阻止 | 停止并输出报告，不绕过安全策略 |

## 关于中文界面

截至当前版本，Claude Desktop 官方语言列表没有简体中文。

“完整汉化”通常会修改 `app.asar`，并改写 `Claude.exe` 内部完整性值。这会使 Anthropic 数字签名变为 `HashMismatch`。CoworkVMService 会验证客户端签名，随后以 `RPC pipe closed` 拒绝连接。

因此本项目遵循以下规则：

- 永远不安装或信任未签名的 Claude 主程序；
- 永远不修改 `Claude.exe` 或 `app.asar` 来实现汉化；
- 默认保留官方界面和完整 Cowork；
- 可通过 `-ChineseMode Compatible -CompatibleChineseProjectPath <目录>` 调用第三方项目明确提供的 `safe` 模式；
- safe 模式只能翻译本地资源，在线 `claude.ai` 区域仍可能是英文，不能称为“完美汉化”。

示例：

```powershell
.\ClaudeSetup.ps1 -Action Auto `
  -ChineseMode Compatible `
  -CompatibleChineseProjectPath 'D:\Downloads\claude-desktop-zh-cn-1.4.5'
```

脚本会强制传入 `-PatchMode safe`，并在安装后重新验证 Anthropic 签名。

## 数据与安全

- 默认不删除 `%APPDATA%\Claude` 或 AppX LocalCache；
- 不自动删除 VM bundle；
- 原位恢复签名文件前，会把修改版备份到 `%ProgramData%\ClaudeSetup\backups`；
- 下载地址固定为 Anthropic 官方 endpoint；
- 安装前验证签名状态为 `Valid`，签名者包含 `Anthropic`，包名为 `Claude`；
- 不提供 `AllowUnsigned` 或签名绕过功能；
- 不修改 `disableAutoUpdates` 或其他 Claude 自动更新策略；
- 不创建常驻进程或计划任务；
- 不绕过 AppLocker、企业策略或固件限制。

## 输出

日志与诊断报告位于仓库的 `reports` 目录：

- `claude-setup-*.log`
- `claude-diagnostic-*.txt`
- `claude-diagnostic-*.json`

## 官方资料

- [下载 Claude](https://claude.com/download)
- [Windows 部署和 Cowork 要求](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)
- [Microsoft Add-AppxPackage](https://learn.microsoft.com/powershell/module/appx/add-appxpackage)

## 免责声明

运行安装或修复前请备份重要的本地 Cowork 会话。本工具尽量采用可恢复操作，但 Windows AppX、虚拟化组件和企业策略组合复杂，无法保证每台电脑都可自动修复。
