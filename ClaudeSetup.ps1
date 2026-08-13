[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Diagnose', 'Install', 'Repair', 'Launch')]
    [string]$Action = 'Auto',

    [ValidateSet('None', 'Compatible')]
    [string]$ChineseMode = 'None',

    [string]$CompatibleChineseProjectPath,

    [switch]$RestartIfNeeded,
    [switch]$NonInteractive,
    [switch]$SkipLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ToolVersion = '1.0.0'
$script:PackageName = 'Claude'
$script:PackageFamily = 'Claude_pzs8sxrjxfjjc'
$script:Aumid = 'Claude_pzs8sxrjxfjjc!Claude'
$script:OfficialDownloadBase = 'https://claude.ai/api/desktop/win32'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ReportsRoot = Join-Path $script:Root 'reports'
$script:DownloadsRoot = Join-Path $script:Root 'downloads'
$script:ProgramDataRoot = Join-Path $env:ProgramData 'ClaudeSetup'
$script:BackupRoot = Join-Path $script:ProgramDataRoot 'backups'
$script:LogPath = $null
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:NeedsRestart = $false
$script:InstallationCandidateCache = $null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $colors = @{ INFO = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $colors[$Level]
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
}

function Add-Finding {
    param(
        [string]$Id,
        [ValidateSet('Pass', 'Info', 'Warning', 'Fail')]
        [string]$Status,
        [string]$Summary,
        [string]$Detail = ''
    )

    $script:Findings.Add([pscustomobject]@{
        Id = $Id
        Status = $Status
        Summary = $Summary
        Detail = $Detail
    })
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentArgumentList {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Action', $Action, '-ChineseMode', $ChineseMode)
    if ($CompatibleChineseProjectPath) { $arguments += @('-CompatibleChineseProjectPath', ('"{0}"' -f $CompatibleChineseProjectPath)) }
    if ($RestartIfNeeded) { $arguments += '-RestartIfNeeded' }
    if ($NonInteractive) { $arguments += '-NonInteractive' }
    if ($SkipLaunch) { $arguments += '-SkipLaunch' }
    return $arguments
}

function Ensure-Administrator {
    if (Test-IsAdministrator) { return }
    if ($Action -eq 'Diagnose') {
        Write-Log '诊断以普通用户权限运行；部分系统级检查将标记为未知。' WARN
        return
    }

    Write-Log '安装和修复 Cowork 需要管理员权限，正在请求 UAC。' INFO
    $arguments = Get-CurrentArgumentList
    Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Verb RunAs -WorkingDirectory $script:Root
    exit 0
}

function Get-NativeArchitecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        'ARM64' { return 'arm64' }
        'AMD64|x86_64' { return 'x64' }
        default { return $null }
    }
}

function Get-PendingRestart {
    $checks = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $checks) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sessionManager.PendingFileRenameOperations) { return $true }
    } catch {}
    return $false
}

function Get-AppxSystemVolume {
    return Get-AppxVolume | Where-Object { $_.IsSystemVolume } | Select-Object -First 1
}

function New-ClaudeInstallationCandidate {
    param(
        [ValidateSet('MSIX', 'EXE', 'Portable')]
        [string]$Type,
        [string]$Path,
        [string]$Source,
        $Package = $null,
        [bool]$CurrentUserRegistered = $false
    )

    if (-not $Path) { return $null }
    try { $Path = [IO.Path]::GetFullPath($Path.Trim('"')) } catch { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ([IO.Path]::GetFileName($Path) -notmatch '^Claude\.exe$') { return $null }

    $appDirectory = Split-Path -Parent $Path
    $resources = Join-Path $appDirectory 'resources'
    $asar = Join-Path $resources 'app.asar'
    # Exclude the Claude Code CLI and unrelated files with the same name.
    if (-not (Test-Path -LiteralPath $asar -PathType Leaf)) { return $null }

    $signature = Test-AnthropicSignature $Path
    $coworkServiceBinary = Join-Path $resources 'cowork-svc.exe'
    $coworkCapable = $Type -eq 'MSIX' -and (Test-Path -LiteralPath $coworkServiceBinary -PathType Leaf)
    $version = $null
    if ($Package -and $Package.Version) { $version = [version]$Package.Version }
    else {
        try { $version = [version](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion } catch {}
    }

    $score = 0
    if ($Type -eq 'MSIX') { $score += 1000 }
    if ($coworkCapable) { $score += 500 }
    if ($signature.Valid) { $score += 300 }
    elseif ($signature.Status -eq 'HashMismatch') { $score += 100 }
    if ($Package -and $Package.PackageFamilyName -eq $script:PackageFamily) { $score += 100 }
    if ($CurrentUserRegistered) { $score += 50 }

    return [pscustomobject]@{
        Type = $Type
        Path = $Path
        AppDirectory = $appDirectory
        Resources = $resources
        Asar = $asar
        Source = $Source
        Package = $Package
        Version = $version
        SignatureValid = [bool]$signature.Valid
        SignatureStatus = [string]$signature.Status
        CoworkCapable = [bool]$coworkCapable
        CurrentUserRegistered = $CurrentUserRegistered
        Score = $score
    }
}

function Select-ClaudeInstallation {
    param([object[]]$Candidates)
    return @($Candidates | Where-Object { $_ } | Sort-Object @(
        @{ Expression = 'Score'; Descending = $true },
        @{ Expression = 'Version'; Descending = $true },
        @{ Expression = 'Path'; Descending = $false }
    ) | Select-Object -First 1)[0]
}

function Get-ClaudeInstallationCandidates {
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:InstallationCandidateCache) {
        return $script:InstallationCandidateCache
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $currentPackages = @(Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue)
    $currentPackageNames = @{}
    foreach ($package in $currentPackages) { $currentPackageNames[$package.PackageFullName] = $true }
    $packages = @($currentPackages)
    if (Test-IsAdministrator) {
        try { $packages += @(Get-AppxPackage -AllUsers -Name $script:PackageName -ErrorAction Stop) } catch {}
    }
    foreach ($package in @($packages | Sort-Object PackageFullName -Unique)) {
        if (-not $package.InstallLocation) { continue }
        $exe = Join-Path $package.InstallLocation 'app\Claude.exe'
        $candidate = New-ClaudeInstallationCandidate -Type MSIX -Path $exe -Source "AppX:$($package.PackageFullName)" -Package $package -CurrentUserRegistered ([bool]$currentPackageNames[$package.PackageFullName])
        if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
            $seen[$candidate.Path.ToLowerInvariant()] = $true
            $candidates.Add($candidate)
        }
    }

    $registryRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $registryRoots) {
        foreach ($entry in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object {
            $_.PSObject.Properties['DisplayName'] -and [string]$_.DisplayName -match '(?i)\bClaude\b'
        })) {
            $paths = @()
            if ($entry.PSObject.Properties['DisplayIcon'] -and $entry.DisplayIcon) { $paths += ([string]$entry.DisplayIcon -replace ',\d+$', '').Trim('"') }
            if ($entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) {
                $paths += Join-Path ([string]$entry.InstallLocation) 'Claude.exe'
                $paths += Join-Path ([string]$entry.InstallLocation) 'app\Claude.exe'
            }
            foreach ($path in $paths) {
                $candidate = New-ClaudeInstallationCandidate -Type EXE -Path $path -Source "Registry:$($entry.PSPath)"
                if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
                    $seen[$candidate.Path.ToLowerInvariant()] = $true
                    $candidates.Add($candidate)
                }
            }
        }
    }

    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue)) {
        $candidate = New-ClaudeInstallationCandidate -Type Portable -Path $process.ExecutablePath -Source "Process:$($process.ProcessId)"
        if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
            $seen[$candidate.Path.ToLowerInvariant()] = $true
            $candidates.Add($candidate)
        }
    }

    $commonRoots = @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude'),
        (Join-Path $env:ProgramFiles 'Claude'),
        (Join-Path ${env:ProgramFiles(x86)} 'Claude')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $commonRoots) {
        foreach ($exe in @(Get-ChildItem -LiteralPath $root -Filter 'Claude.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
            $candidate = New-ClaudeInstallationCandidate -Type EXE -Path $exe.FullName -Source "CommonPath:$root"
            if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
                $seen[$candidate.Path.ToLowerInvariant()] = $true
                $candidates.Add($candidate)
            }
        }
    }

    $fixedDriveRelatives = @(
        'Claude\Claude.exe',
        'Claude\app\Claude.exe',
        'Apps\Claude\Claude.exe',
        'Apps\Claude\app\Claude.exe',
        'Programs\Claude\Claude.exe',
        'Programs\Claude\app\Claude.exe',
        'Software\Claude\Claude.exe',
        'Software\Claude\app\Claude.exe',
        'Tools\Claude\Claude.exe',
        'Tools\Claude\app\Claude.exe',
        'Program Files\Claude\Claude.exe',
        'Program Files\Claude\app\Claude.exe',
        'Program Files (x86)\Claude\Claude.exe',
        'Program Files (x86)\Claude\app\Claude.exe'
    )
    foreach ($drive in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        foreach ($relative in $fixedDriveRelatives) {
            $path = Join-Path ($drive.DeviceID + '\') $relative
            $candidate = New-ClaudeInstallationCandidate -Type Portable -Path $path -Source "FixedDriveCommonPath:$($drive.DeviceID)"
            if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
                $seen[$candidate.Path.ToLowerInvariant()] = $true
                $candidates.Add($candidate)
            }
        }
    }

    $shortcutRoots = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($root in $shortcutRoots) {
            foreach ($shortcutFile in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '(?i)Claude' })) {
                $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                $candidate = New-ClaudeInstallationCandidate -Type Portable -Path $shortcut.TargetPath -Source "Shortcut:$($shortcutFile.FullName)"
                if ($candidate -and -not $seen[$candidate.Path.ToLowerInvariant()]) {
                    $seen[$candidate.Path.ToLowerInvariant()] = $true
                    $candidates.Add($candidate)
                }
            }
        }
    } catch {}

    $script:InstallationCandidateCache = $candidates.ToArray()
    return $script:InstallationCandidateCache
}

function Get-ClaudePackage {
    $selected = Select-ClaudeInstallation @(Get-ClaudeInstallationCandidates | Where-Object { $_.Type -eq 'MSIX' -and $_.CurrentUserRegistered })
    if ($selected) { return $selected.Package }
    return $null
}

function Get-ClaudePaths {
    $package = Get-ClaudePackage
    if (-not $package) { return $null }
    $app = Join-Path $package.InstallLocation 'app'
    $resources = Join-Path $app 'resources'
    return [pscustomobject]@{
        Package = $package
        App = $app
        Resources = $resources
        Exe = Join-Path $app 'Claude.exe'
        Asar = Join-Path $resources 'app.asar'
        LocalUserData = Join-Path $env:LOCALAPPDATA "Packages\$script:PackageFamily\LocalCache\Roaming\Claude"
        RoamingUserData = Join-Path $env:APPDATA 'Claude'
    }
}

function Test-AnthropicSignature {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Valid = $false; Status = 'Missing'; Subject = $null }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
    $valid = $signature.Status -eq 'Valid' -and $subject -match 'Anthropic'
    return [pscustomobject]@{ Valid = $valid; Status = [string]$signature.Status; Subject = $subject }
}

function Test-FirmwareVirtualization {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        if ($computer.HypervisorPresent -eq $true) { return $true }
        $processors = @(Get-CimInstance Win32_Processor)
        if ($processors.Count -eq 0) { return $null }
        return -not ($processors | Where-Object { $_.VirtualizationFirmwareEnabled -eq $false })
    } catch { return $null }
}

function Test-VirtualMachineHost {
    try {
        $system = Get-CimInstance Win32_ComputerSystem
        return $system.Model -match 'Virtual|VMware|VirtualBox|KVM|Hyper-V' -or $system.Manufacturer -match 'VMware|QEMU|Xen|innotek'
    } catch { return $false }
}

function Get-HypervisorLaunchType {
    try {
        $output = & bcdedit.exe /enum '{current}' 2>&1
        $line = $output | Where-Object { $_ -match '^hypervisorlaunchtype\s+' } | Select-Object -First 1
        if ($line) { return (($line -split '\s+')[-1]).Trim() }
    } catch {}
    return $null
}

function Get-VolumeRoot {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { return [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return $null }
}

function Test-ReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Test-EncryptedPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::Encrypted)
}

function Test-CompressedPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::Compressed)
}

function Get-RecentCoworkErrors {
    $patterns = @(
        'RPC pipe closed',
        'signature verification failed',
        'HashMismatch',
        'sessiondata.vhdx',
        'rootfs.vhdx',
        'VHDX file not found',
        'FILE_ENCRYPTED',
        'EXDEV',
        'API reachability',
        'VM service not running',
        'Missing HCS'
    )
    $logs = @(
        'C:\ProgramData\Claude\Logs\cowork-service.log',
        (Join-Path $env:LOCALAPPDATA "Packages\$script:PackageFamily\LocalCache\Roaming\Claude\logs\cowork_vm_node.log"),
        (Join-Path $env:APPDATA 'Claude\logs\cowork_vm_node.log')
    )
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($log in $logs) {
        if (-not (Test-Path -LiteralPath $log)) { continue }
        $tail = Get-Content -LiteralPath $log -Tail 600 -ErrorAction SilentlyContinue
        foreach ($line in $tail) {
            if ($patterns | Where-Object { $line -match [regex]::Escape($_) }) {
                $results.Add("[$log] $line")
            }
        }
    }
    return @($results | Select-Object -Last 120)
}

function Invoke-Diagnostics {
    $script:Findings.Clear()
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $arch = Get-NativeArchitecture
    $isAdmin = Test-IsAdministrator
    $installations = @(Get-ClaudeInstallationCandidates)
    $selectedInstallation = Select-ClaudeInstallation $installations
    $package = if ($selectedInstallation -and $selectedInstallation.Type -eq 'MSIX') { $selectedInstallation.Package } else { $null }
    $paths = Get-ClaudePaths
    $vmp = $null
    try { $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop } catch {}

    Add-Finding 'os' 'Info' "$($os.Caption) $($os.Version), build $($os.BuildNumber)" "$($computer.Manufacturer) $($computer.Model)"
    if ([version]$os.Version -ge [version]'10.0') {
        Add-Finding 'os-support' 'Pass' 'Windows 10/11 版本范围受 Claude Desktop 支持'
    } else {
        Add-Finding 'os-support' 'Fail' 'Claude Desktop 需要 Windows 10 或更高版本'
    }
    if ($arch) { Add-Finding 'architecture' 'Pass' "支持的体系结构：$arch" } else { Add-Finding 'architecture' 'Fail' '仅支持 x64 或 ARM64 Windows' }
    if ($isAdmin) { Add-Finding 'administrator' 'Pass' '当前进程具有管理员权限' } else { Add-Finding 'administrator' 'Warning' '当前进程没有管理员权限，Cowork 安装/修复需要 UAC' }

    $firmware = Test-FirmwareVirtualization
    if ($firmware -eq $true) { Add-Finding 'firmware-virtualization' 'Pass' 'BIOS/UEFI 虚拟化已启用' }
    elseif ($firmware -eq $false) { Add-Finding 'firmware-virtualization' 'Fail' 'BIOS/UEFI 虚拟化未启用' '请在固件设置中启用 Intel VT-x/AMD-V。' }
    else { Add-Finding 'firmware-virtualization' 'Warning' '无法读取固件虚拟化状态' }

    if (Test-VirtualMachineHost) {
        Add-Finding 'nested-virtualization' 'Warning' '检测到当前 Windows 可能运行在虚拟机中' 'Cowork 需要宿主机开放嵌套虚拟化。'
    }

    if ($vmp -and $vmp.State -eq 'Enabled') { Add-Finding 'virtual-machine-platform' 'Pass' 'Virtual Machine Platform 已启用' }
    else { Add-Finding 'virtual-machine-platform' 'Fail' 'Virtual Machine Platform 未启用' }

    $launchType = Get-HypervisorLaunchType
    if ($launchType -and $launchType -ne 'Auto') { Add-Finding 'hypervisor-launch' 'Fail' "hypervisorlaunchtype=$launchType" '应设置为 Auto 并重新启动。' }
    elseif ($launchType) { Add-Finding 'hypervisor-launch' 'Pass' 'Windows Hypervisor 设置为自动启动' }
    else { Add-Finding 'hypervisor-launch' 'Warning' '无法读取 hypervisorlaunchtype' }

    foreach ($serviceName in @('vmcompute', 'hns', 'CoworkVMService')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $status = if ($service.Status -eq 'Running') { 'Pass' } else { 'Warning' }
            Add-Finding "service-$serviceName" $status "$serviceName：$($service.Status) / $($service.StartType)"
        } else {
            $severity = if ($serviceName -eq 'CoworkVMService' -and -not $package) { 'Info' } else { 'Fail' }
            Add-Finding "service-$serviceName" $severity "$serviceName 未注册"
        }
    }

    $systemVolume = Get-AppxSystemVolume
    $defaultVolume = Get-AppxDefaultVolume -ErrorAction SilentlyContinue
    if ($systemVolume) {
        Add-Finding 'appx-system-volume' 'Info' "系统 AppX 卷：$($systemVolume.PackageStorePath)"
        if ($defaultVolume -and $defaultVolume.PackageStorePath -ne $systemVolume.PackageStorePath) {
            Add-Finding 'appx-default-volume' 'Fail' "默认 AppX 卷不是系统卷：$($defaultVolume.PackageStorePath)" '新装 Claude 可能触发 WindowsApps/LocalCache 路径错位。'
        } else {
            Add-Finding 'appx-default-volume' 'Pass' '默认 AppX 卷是系统卷'
        }
    }

    $tempRoot = Get-VolumeRoot $env:TEMP
    $localRoot = Get-VolumeRoot $env:LOCALAPPDATA
    if ($tempRoot -and $localRoot -and $tempRoot -ne $localRoot) {
        Add-Finding 'temp-volume' 'Fail' "TEMP ($tempRoot) 与 LocalAppData ($localRoot) 跨盘" 'Claude 可能在移动 rootfs.vhdx 时遇到 EXDEV。'
    } else {
        Add-Finding 'temp-volume' 'Pass' 'TEMP 与 LocalAppData 位于同一卷'
    }

    if ($package) {
        Add-Finding 'installation-selection' 'Pass' "已自动选择官方 MSIX：$($selectedInstallation.Path)" "候选数量：$($installations.Count)，签名：$($selectedInstallation.SignatureStatus)，Cowork：$($selectedInstallation.CoworkCapable)"
        Add-Finding 'package' 'Pass' "Claude $($package.Version) 已安装" $package.InstallLocation
        if ($systemVolume -and -not $package.InstallLocation.StartsWith((Get-VolumeRoot $systemVolume.PackageStorePath), [StringComparison]::OrdinalIgnoreCase)) {
            Add-Finding 'package-volume' 'Fail' 'Claude 不在系统 AppX 卷' $package.InstallLocation
        } else {
            Add-Finding 'package-volume' 'Pass' 'Claude 位于系统 AppX 卷'
        }

        $signature = Test-AnthropicSignature $paths.Exe
        if ($signature.Valid) { Add-Finding 'signature' 'Pass' 'Claude.exe 的 Anthropic 数字签名有效' }
        else { Add-Finding 'signature' 'Fail' "Claude.exe 签名无效：$($signature.Status)" '完整汉化修改主程序后会导致 Cowork 主动关闭 RPC 管道。' }

        $bundle = Join-Path $paths.LocalUserData 'vm_bundles\claudevm.bundle'
        if (Test-ReparsePoint (Split-Path -Parent $bundle)) { Add-Finding 'vm-reparse' 'Fail' 'vm_bundles 是重解析点/联接' 'HCS 挂载 VHDX 时可能无法解析联接。' }
        elseif (Test-Path -LiteralPath $bundle) { Add-Finding 'vm-reparse' 'Pass' 'vm_bundles 不是重解析点' }

        $encryptedVmFiles = @()
        if (Test-Path -LiteralPath $bundle) {
            $encryptedVmFiles = @(Get-ChildItem -LiteralPath $bundle -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted })
        }
        if ((Test-EncryptedPath $bundle) -or $encryptedVmFiles.Count -gt 0) {
            Add-Finding 'vm-encryption' 'Fail' "VM bundle 或其中 $($encryptedVmFiles.Count) 个文件启用了 EFS 加密" 'HCS 无法挂载加密的 VHDX。'
        } elseif (Test-Path -LiteralPath $bundle) {
            Add-Finding 'vm-encryption' 'Pass' 'VM bundle 及其文件未启用 EFS 加密'
        }

        if (Test-CompressedPath $bundle) {
            Add-Finding 'vm-compression' 'Info' 'VM bundle 使用 NTFS 压缩' 'Claude 的 HCS 配置包含 SupportCompressedVolumes；这与 EFS 加密不同，通常可用。'
        } elseif (Test-Path -LiteralPath $bundle) {
            Add-Finding 'vm-compression' 'Pass' 'VM bundle 未使用 NTFS 压缩'
        }

        foreach ($name in @('rootfs.vhdx', 'sessiondata.vhdx')) {
            $file = Join-Path $bundle $name
            if (Test-Path -LiteralPath $file) { Add-Finding "vhdx-$name" 'Pass' "$name 存在" ((Get-Item -LiteralPath $file).Length.ToString()) }
            else { Add-Finding "vhdx-$name" 'Warning' "$name 不存在" '全新安装尚未启动 Cowork 时属于正常；已有错误时需要重建 workspace。' }
        }
    } else {
        if ($selectedInstallation) {
            Add-Finding 'installation-selection' 'Warning' "找到 $($selectedInstallation.Type) 安装，但它不支持可靠的 Cowork：$($selectedInstallation.Path)" '脚本将保留该目录并安装官方 MSIX。'
            Add-Finding 'package' 'Warning' '未找到支持 Cowork 的官方 Claude MSIX'
        } else {
            Add-Finding 'installation-selection' 'Info' '没有发现现有 Claude 安装路径'
            Add-Finding 'package' 'Warning' 'Claude Desktop 尚未安装'
        }
    }

    if (Get-PendingRestart) { Add-Finding 'pending-restart' 'Warning' 'Windows 有待完成的重启操作' }
    else { Add-Finding 'pending-restart' 'Pass' '没有检测到待完成重启' }

    $recentErrors = Get-RecentCoworkErrors
    if ($recentErrors.Count -gt 0) {
        Add-Finding 'recent-cowork-errors' 'Info' "找到 $($recentErrors.Count) 条近期 Cowork 关键日志" ($recentErrors -join "`r`n")
    }

    return [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        ToolVersion = $script:ToolVersion
        Computer = $env:COMPUTERNAME
        User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Findings = $script:Findings.ToArray()
    }
}

function Save-DiagnosticReport {
    param([Parameter(Mandatory)]$Report)
    New-Item -ItemType Directory -Path $script:ReportsRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $script:ReportsRoot "claude-diagnostic-$stamp.json"
    $textPath = Join-Path $script:ReportsRoot "claude-diagnostic-$stamp.txt"
    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $lines = @(
        "Claude Setup diagnostic $($Report.GeneratedAt)",
        "Computer: $($Report.Computer)",
        "User: $($Report.User)",
        ''
    )
    foreach ($finding in $Report.Findings) {
        $lines += "[$($finding.Status)] $($finding.Id): $($finding.Summary)"
        if ($finding.Detail) { $lines += "  $($finding.Detail -replace "`r?`n", "`r`n  ")" }
    }
    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8
    Write-Log "诊断报告：$textPath" OK
    return [pscustomobject]@{ Json = $jsonPath; Text = $textPath }
}

function Show-DiagnosticSummary {
    param([Parameter(Mandatory)]$Report)
    foreach ($finding in $Report.Findings) {
        $level = switch ($finding.Status) { 'Pass' { 'OK' } 'Fail' { 'ERROR' } 'Warning' { 'WARN' } default { 'INFO' } }
        Write-Log "$($finding.Id)：$($finding.Summary)" $level
    }
}

function Enable-CoworkPrerequisites {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($feature.State -ne 'Enabled') {
        Write-Log '正在启用 Virtual Machine Platform。' INFO
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
        $script:NeedsRestart = $true
    }

    $launchType = Get-HypervisorLaunchType
    if ($launchType -and $launchType -ne 'Auto') {
        Write-Log '正在设置 Windows Hypervisor 随系统启动。' INFO
        & bcdedit.exe /set hypervisorlaunchtype auto | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '无法设置 hypervisorlaunchtype=Auto。' }
        $script:NeedsRestart = $true
    }

    $systemVolume = Get-AppxSystemVolume
    $defaultVolume = Get-AppxDefaultVolume -ErrorAction SilentlyContinue
    if ($systemVolume -and $defaultVolume -and $defaultVolume.PackageStorePath -ne $systemVolume.PackageStorePath) {
        Write-Log "正在把默认 AppX 安装卷改为系统卷：$($systemVolume.PackageStorePath)" INFO
        Set-AppxDefaultVolume -Volume $systemVolume
    }

    $tempRoot = Get-VolumeRoot $env:TEMP
    $localRoot = Get-VolumeRoot $env:LOCALAPPDATA
    if ($tempRoot -and $localRoot -and $tempRoot -ne $localRoot) {
        $safeTemp = Join-Path $env:LOCALAPPDATA 'Temp'
        New-Item -ItemType Directory -Path $safeTemp -Force | Out-Null
        [Environment]::SetEnvironmentVariable('TEMP', $safeTemp, 'User')
        [Environment]::SetEnvironmentVariable('TMP', $safeTemp, 'User')
        $env:TEMP = $safeTemp
        $env:TMP = $safeTemp
        Write-Log "已把用户 TEMP/TMP 恢复到 LocalAppData 同卷：$safeTemp" OK
    }
}

function Register-ResumeAfterRestart {
    $arguments = Get-CurrentArgumentList | Where-Object { $_ -ne '-RestartIfNeeded' }
    $command = 'powershell.exe ' + ($arguments -join ' ')
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeSetupResume' -Value $command
    Write-Log '已注册重启后自动继续 Claude Setup。' OK
}

function Remove-ResumeAfterRestart {
    $runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (Test-Path -LiteralPath $runOnce) {
        Remove-ItemProperty -LiteralPath $runOnce -Name 'ClaudeSetupResume' -ErrorAction SilentlyContinue
    }
}

function Get-OfficialPackageUrl {
    param([Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    return "$script:OfficialDownloadBase/$Architecture/msix/latest/redirect"
}

function Get-MsixManifestInfo {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw 'MSIX 缺少 AppxManifest.xml。' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $xml.Package.Identity
        return [pscustomobject]@{
            Name = [string]$identity.Name
            Publisher = [string]$identity.Publisher
            Version = [version]$identity.Version
            Architecture = [string]$identity.ProcessorArchitecture
        }
    } finally { $zip.Dispose() }
}

function Download-OfficialClaude {
    $arch = Get-NativeArchitecture
    if (-not $arch) { throw '当前 CPU 架构不受支持。' }
    New-Item -ItemType Directory -Path $script:DownloadsRoot -Force | Out-Null
    $destination = Join-Path $script:DownloadsRoot "Claude-latest-$arch.msix"
    $url = Get-OfficialPackageUrl -Architecture $arch
    Write-Log "从 Anthropic 官方地址下载 Claude ($arch)。" INFO
    Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing

    $signature = Test-AnthropicSignature $destination
    if (-not $signature.Valid) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "官方安装包签名验证失败：$($signature.Status)。拒绝安装。"
    }
    $manifest = Get-MsixManifestInfo $destination
    if ($manifest.Name -ne 'Claude' -or $manifest.Publisher -notmatch 'Anthropic') {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw '下载文件的包身份不是 Anthropic Claude。'
    }
    if ($manifest.Architecture -ne $arch) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "下载架构不匹配：需要 $arch，得到 $($manifest.Architecture)。"
    }
    Write-Log "官方 MSIX 验证通过：Claude $($manifest.Version)，SHA-256 $((Get-FileHash $destination -Algorithm SHA256).Hash)" OK
    return [pscustomobject]@{ Path = $destination; Manifest = $manifest }
}

function Stop-ClaudeProcesses {
    Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Install-OfficialClaude {
    param([Parameter(Mandatory)]$Download)
    $systemVolume = Get-AppxSystemVolume
    $installed = Get-ClaudePackage
    Stop-ClaudeProcesses

    if ($installed -and [version]$Download.Manifest.Version -lt [version]$installed.Version) {
        throw "官方 latest 包 ($($Download.Manifest.Version)) 低于已安装版本 ($($installed.Version))，拒绝降级。"
    }

    Write-Log "正在安装/更新官方 Claude MSIX；目标为 Windows 系统 AppX 默认路径：$($systemVolume.PackageStorePath)" INFO
    $parameters = @{
        Path = $Download.Path
        ForceApplicationShutdown = $true
        ForceTargetApplicationShutdown = $true
        InstallAllResources = $true
    }
    if ($systemVolume) { $parameters.Volume = $systemVolume }
    try {
        Add-AppxPackage @parameters
    } catch {
        if ($_.Exception.Message -notmatch 'already installed|已安装|0x80073CFB|0x80073D06') { throw }
        Write-Log '相同或更高版本已注册，将检查签名并按需恢复官方文件。' WARN
    }

    # Provisioning registers the machine-wide Cowork service on configurations
    # where a per-user Add-AppxPackage install alone does not do so.
    if (-not (Get-Service CoworkVMService -ErrorAction SilentlyContinue)) {
        Write-Log 'CoworkVMService 未注册，尝试按官方部署方式预配 MSIX。' WARN
        try {
            Add-AppxProvisionedPackage -Online -PackagePath $Download.Path -SkipLicense -Regions 'all' | Out-Null
        } catch {
            Write-Log "机器范围预配失败：$($_.Exception.Message)" WARN
        }
        try { Add-AppxPackage @parameters } catch {}
    }
    $script:InstallationCandidateCache = $null
}

function Backup-ModifiedClaudeFiles {
    param([Parameter(Mandatory)]$Paths)
    $folder = Join-Path $script:BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    foreach ($file in @($Paths.Exe, $Paths.Asar)) {
        if (Test-Path -LiteralPath $file) {
            Copy-Item -LiteralPath $file -Destination (Join-Path $folder ([IO.Path]::GetFileName($file) + '.modified')) -Force
        }
    }
    return $folder
}

function Restore-OfficialCoreFilesFromMsix {
    param(
        [Parameter(Mandatory)]$Download,
        [Parameter(Mandatory)]$Paths
    )
    if ([version]$Download.Manifest.Version -ne [version]$Paths.Package.Version) {
        throw '只能从完全相同版本的 MSIX 原位恢复核心文件；请先安装更新。'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stage = Join-Path $env:TEMP ("ClaudeSetup-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Download.Path)
    try {
        $entries = @{
            'app/claude.exe' = (Join-Path $stage 'Claude.exe')
            'app/resources/app.asar' = (Join-Path $stage 'app.asar')
        }
        foreach ($name in $entries.Keys) {
            $entry = $zip.GetEntry($name)
            if (-not $entry) { throw "MSIX 缺少 $name。" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entries[$name], $true)
        }
    } finally { $zip.Dispose() }

    $stagedSignature = Test-AnthropicSignature (Join-Path $stage 'Claude.exe')
    if (-not $stagedSignature.Valid) { throw 'MSIX 中的 Claude.exe 签名无效。' }

    $backup = Backup-ModifiedClaudeFiles $Paths
    Write-Log "已备份被修改的核心文件：$backup" INFO
    Stop-ClaudeProcesses
    Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue

    $targets = @($Paths.App, $Paths.Resources, $Paths.Exe, $Paths.Asar)
    $snapshots = @{}
    foreach ($target in $targets) { $snapshots[$target] = Get-Acl -LiteralPath $target }
    try {
        foreach ($directory in @($Paths.App, $Paths.Resources)) {
            $acl = Get-Acl -LiteralPath $directory
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $directory -AclObject $acl
        }
        Copy-Item -LiteralPath (Join-Path $stage 'Claude.exe') -Destination $Paths.Exe -Force
        Copy-Item -LiteralPath (Join-Path $stage 'app.asar') -Destination $Paths.Asar -Force
    } finally {
        foreach ($target in @($Paths.Asar, $Paths.Exe, $Paths.Resources, $Paths.App)) {
            if ($snapshots.ContainsKey($target) -and (Test-Path -LiteralPath $target)) {
                Set-Acl -LiteralPath $target -AclObject $snapshots[$target] -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    $restoredSignature = Test-AnthropicSignature $Paths.Exe
    if (-not $restoredSignature.Valid) { throw "恢复后签名仍无效：$($restoredSignature.Status)" }
    Write-Log 'Claude.exe 与 app.asar 已恢复为官方签名版本。' OK
}

function Repair-ClaudePackageAndSignature {
    $download = Download-OfficialClaude
    Install-OfficialClaude -Download $download
    $paths = Get-ClaudePaths
    if (-not $paths) { throw '安装后仍未找到 Claude AppX 包。' }

    $signature = Test-AnthropicSignature $paths.Exe
    if (-not $signature.Valid) {
        if ([version]$download.Manifest.Version -eq [version]$paths.Package.Version) {
            Restore-OfficialCoreFilesFromMsix -Download $download -Paths $paths
        } else {
            throw "Claude.exe 签名仍无效 ($($signature.Status))，且下载版本与安装版本不同，拒绝原位覆盖。"
        }
    }
    return Get-ClaudePaths
}

function Repair-ExistingPackageVolume {
    $paths = Get-ClaudePaths
    if (-not $paths) { return }
    $systemVolume = Get-AppxSystemVolume
    if (-not $systemVolume) { return }
    $systemRoot = Get-VolumeRoot $systemVolume.PackageStorePath
    if ($paths.Package.InstallLocation.StartsWith($systemRoot, [StringComparison]::OrdinalIgnoreCase)) { return }

    Write-Log "Claude 位于非官方默认系统 AppX 路径：$($paths.Package.InstallLocation)" WARN
    if (-not (Get-Command Move-AppxPackage -ErrorAction SilentlyContinue)) {
        throw '当前 Windows 版本不提供 Move-AppxPackage。请先备份本地 Cowork 会话，卸载 Claude，把默认 AppX 卷设为系统卷后再运行本脚本。'
    }
    Write-Log '尝试使用 Windows Move-AppxPackage 移至系统卷。' INFO
    Stop-ClaudeProcesses
    try {
        Move-AppxPackage -Package $paths.Package.PackageFullName -Volume $systemVolume
        $script:InstallationCandidateCache = $null
    } catch {
        throw "无法安全移动 Claude AppX 包。请先备份本地 Cowork 会话，再卸载并用本脚本重装。错误：$($_.Exception.Message)"
    }
}

function Repair-VmStorageAttributes {
    $paths = Get-ClaudePaths
    if (-not $paths) { return }
    $vmBundles = Join-Path $paths.LocalUserData 'vm_bundles'
    if (-not (Test-Path -LiteralPath $vmBundles)) { return }
    if (Test-ReparsePoint $vmBundles) {
        throw "检测到 vm_bundles 是重解析点：$vmBundles。为避免误移动大量 VM 数据，脚本不会自动删除联接。"
    }
    $encrypted = @(Get-ChildItem -LiteralPath $vmBundles -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted })
    if ((Test-EncryptedPath $vmBundles) -or $encrypted.Count -gt 0) {
        Write-Log '正在移除 VM bundle 的 EFS 加密属性。' WARN
        & cipher.exe /d /s:$vmBundles | Out-Null
        $remaining = @(Get-ChildItem -LiteralPath $vmBundles -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted })
        if ((Test-EncryptedPath $vmBundles) -or $remaining.Count -gt 0) { throw '无法移除 vm_bundles 或其中文件的 EFS 加密属性。' }
    }
}

function Repair-IncompleteWorkspace {
    $paths = Get-ClaudePaths
    if (-not $paths) { return }
    $vmBundles = Join-Path $paths.LocalUserData 'vm_bundles'
    $bundle = Join-Path $vmBundles 'claudevm.bundle'
    if (-not (Test-Path -LiteralPath $bundle)) { return }

    $required = @('rootfs.vhdx', 'sessiondata.vhdx')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bundle $_)) })
    if ($missing.Count -eq 0) { return }
    if (Test-ReparsePoint $vmBundles) {
        throw 'workspace 不完整且 vm_bundles 是重解析点；为避免归档错误目标，拒绝自动重建。'
    }

    New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    $archive = Join-Path $script:BackupRoot ("incomplete-workspace-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Log "workspace 不完整（缺少 $($missing -join ', ')），将旧目录归档到 $archive。" WARN
    Stop-ClaudeProcesses
    Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $vmBundles -Destination $archive
    New-Item -ItemType Directory -Path $vmBundles -Force | Out-Null
    Write-Log '旧 workspace 已可恢复地归档；Claude 下次启动会重新下载 VM。' OK
}

function Start-CoworkServices {
    foreach ($name in @('hns', 'vmcompute', 'CoworkVMService')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            try { Start-Service -Name $name } catch { Write-Log "无法启动 $name：$($_.Exception.Message)" WARN }
        }
    }
}

function Install-CompatibleChinese {
    if ($ChineseMode -ne 'Compatible') { return }
    if (-not $CompatibleChineseProjectPath) {
        Write-Log '已选择兼容汉化，但未提供项目路径；跳过汉化。官方 Claude 当前没有简体中文桌面语言。' WARN
        return
    }
    $installer = Join-Path $CompatibleChineseProjectPath 'scripts\install_windows.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "未找到兼容汉化安装脚本：$installer" }
    $source = Get-Content -LiteralPath $installer -Raw
    if ($source -notmatch 'PatchMode' -or $source -notmatch 'safe') { throw '该汉化项目没有可验证的 safe/Cowork 兼容模式。' }
    Write-Log '正在调用第三方项目的 safe/Cowork 兼容模式。不会允许 official/full 模式。' WARN
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Action install -Language zh-CN -PatchMode safe
    if ($LASTEXITCODE -ne 0) { throw "兼容汉化安装失败，退出码 $LASTEXITCODE。" }
    $paths = Get-ClaudePaths
    $signature = Test-AnthropicSignature $paths.Exe
    if (-not $signature.Valid) {
        throw '兼容汉化意外破坏了 Claude.exe 签名。请立即运行 Repair。'
    }
}

function Start-ClaudeAppx {
    if (-not (Get-ClaudePackage)) { throw 'Claude 尚未安装。' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$script:Aumid"
    Write-Log '已通过官方 AppX 入口启动 Claude Desktop。' OK
}

function Invoke-HealthWait {
    param([int]$Seconds = 45)
    $serviceLog = 'C:\ProgramData\Claude\Logs\cowork-service.log'
    $mainProcess = Get-Process -Name Claude -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    $cutoff = if ($mainProcess) { $mainProcess.StartTime.AddSeconds(-3) } else { (Get-Date).AddSeconds(-5) }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $serviceLog) {
            $tail = Get-Content -LiteralPath $serviceLog -Tail 160 -ErrorAction SilentlyContinue
            $currentRun = @($tail | Where-Object {
                if ($_ -notmatch '^(?<stamp>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)') { return $false }
                $stamp = [datetime]::MinValue
                return [datetime]::TryParse($Matches.stamp, [ref]$stamp) -and $stamp -ge $cutoff
            })
            if ($currentRun -match 'API reachability: REACHABLE' -and $currentRun -match 'sdk-daemon is ready') {
                Write-Log 'Cowork VM 网络已连接，API 可达。' OK
                return $true
            }
            if ($currentRun -match 'signature verification failed') {
                Write-Log '当前 Claude 客户端被 Cowork 服务拒绝：签名验证失败。' ERROR
                return $false
            }
        }
        Start-Sleep -Seconds 2
    }
    Write-Log '未在等待时间内确认 Cowork API 可达；已生成诊断报告供进一步排查。' WARN
    return $false
}

function Invoke-AutoSetup {
    Enable-CoworkPrerequisites
    if ($script:NeedsRestart) {
        Register-ResumeAfterRestart
        Write-Log 'Windows 虚拟化组件需要重新启动后生效。' WARN
        if ($RestartIfNeeded) {
            Write-Log '将在 15 秒后重新启动。运行 shutdown /a 可取消。' WARN
            & shutdown.exe /r /t 15 /c 'Claude Setup 正在完成 Virtual Machine Platform 安装'
        }
        return 3010
    }

    Repair-ExistingPackageVolume
    $paths = Repair-ClaudePackageAndSignature
    Repair-VmStorageAttributes
    Repair-IncompleteWorkspace
    Start-CoworkServices
    Install-CompatibleChinese
    if (-not $SkipLaunch) {
        Start-ClaudeAppx
        [void](Invoke-HealthWait)
    }
    return 0
}

if ($env:CLAUDE_SETUP_IMPORT_ONLY -eq '1') {
    return
}

New-Item -ItemType Directory -Path $script:ReportsRoot, $script:DownloadsRoot -Force | Out-Null
if ($Action -ne 'Diagnose') {
    New-Item -ItemType Directory -Path $script:ProgramDataRoot, $script:BackupRoot -Force | Out-Null
}
$script:LogPath = Join-Path $script:ReportsRoot ("claude-setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Log "Claude Setup $script:ToolVersion，Action=$Action" INFO
Ensure-Administrator

$exitCode = 0
try {
    switch ($Action) {
        'Diagnose' {
            $report = Invoke-Diagnostics
            Show-DiagnosticSummary $report
        }
        'Install' {
            Enable-CoworkPrerequisites
            if ($script:NeedsRestart) { Register-ResumeAfterRestart; $exitCode = 3010; break }
            [void](Repair-ClaudePackageAndSignature)
            Start-CoworkServices
            if (-not $SkipLaunch) { Start-ClaudeAppx }
        }
        'Repair' {
            Enable-CoworkPrerequisites
            if ($script:NeedsRestart) { Register-ResumeAfterRestart; $exitCode = 3010; break }
            Repair-ExistingPackageVolume
            [void](Repair-ClaudePackageAndSignature)
            Repair-VmStorageAttributes
            Repair-IncompleteWorkspace
            Start-CoworkServices
            if (-not $SkipLaunch) { Start-ClaudeAppx; [void](Invoke-HealthWait) }
        }
        'Launch' { Start-ClaudeAppx }
        'Auto' { $exitCode = Invoke-AutoSetup }
    }

    $finalReport = Invoke-Diagnostics
    [void](Save-DiagnosticReport $finalReport)
    if ($finalReport.Findings | Where-Object { $_.Status -eq 'Fail' }) {
        Write-Log '仍有失败项，请查看诊断报告。' WARN
        if ($exitCode -eq 0) { $exitCode = 2 }
    } elseif ($exitCode -eq 0) {
        Remove-ResumeAfterRestart
        Write-Log 'Claude Desktop/Cowork 安装与检测完成。' OK
    }
} catch {
    Write-Log $_.Exception.Message ERROR
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace ERROR }
    try {
        $failureReport = Invoke-Diagnostics
        [void](Save-DiagnosticReport $failureReport)
    } catch {}
    $exitCode = 1
}

exit $exitCode
