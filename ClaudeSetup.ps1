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

$script:ToolVersion = '1.0.14'
$script:PackageName = 'Claude'
$script:PackageFamily = 'Claude_pzs8sxrjxfjjc'
$script:Aumid = 'Claude_pzs8sxrjxfjjc!Claude'
$script:OfficialDownloadBase = 'https://claude.ai/api/desktop/win32'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ReportsRoot = Join-Path $script:Root 'reports'
$script:DownloadsRoot = Join-Path $script:Root 'downloads'
$script:ProgramDataRoot = Join-Path $env:ProgramData 'ClaudeSetup'
$script:BackupRoot = Join-Path $script:ProgramDataRoot 'backups'
$script:VmRebuildStatePath = Join-Path $script:ProgramDataRoot 'vm-rebuild-active.json'
$script:LogPath = $null
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:NeedsRestart = $false
$script:InstallationCandidateCache = $null
$script:VmCommitAttempted = @{}
$script:VmManifestCache = $null
$script:OfficialMsixPath = $null
$script:AppxProtectionLogEmitted = $false

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

function Test-ClaudeDefaultInstallationReady {
    param($Package = (Get-ClaudePackage))
    if (-not $Package -or -not $Package.InstallLocation) { return $false }
    $systemVolume = Get-AppxSystemVolume
    if (-not $systemVolume) { return $false }
    $systemRoot = Get-VolumeRoot $systemVolume.PackageStorePath
    if (-not $Package.InstallLocation.StartsWith($systemRoot, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $exe = Join-Path $Package.InstallLocation 'app\Claude.exe'
    $asar = Join-Path $Package.InstallLocation 'app\resources\app.asar'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $asar -PathType Leaf)) { return $false }
    return (Test-AnthropicSignature $exe).Valid
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

function Get-AppxProtectedVmEvidence {
    param(
        [string]$BundlePath,
        [string[]]$NodeLogPaths,
        [string]$ServiceLogPath
    )
    if (-not $BundlePath) {
        $paths = Get-ClaudePaths
        if (-not $paths) {
            return [pscustomobject]@{ Suspected = $false; ExplicitAppxError = $false; SessionDiskError = $false; EncryptedCount = 0; CopyfileUnknown = $false; Reasons = @() }
        }
        $BundlePath = Join-Path $paths.LocalUserData 'vm_bundles\claudevm.bundle'
    }
    if (-not $NodeLogPaths) {
        $NodeLogPaths = @(
            (Join-Path $env:LOCALAPPDATA "Packages\$script:PackageFamily\LocalCache\Roaming\Claude\logs\cowork_vm_node.log"),
            (Join-Path $env:APPDATA 'Claude\logs\cowork_vm_node.log')
        )
    }
    if (-not $ServiceLogPath) { $ServiceLogPath = 'C:\ProgramData\Claude\Logs\cowork-service.log' }

    $encryptedCount = 0
    if (Test-Path -LiteralPath $BundlePath) {
        $encryptedCount = @(Get-ChildItem -LiteralPath $BundlePath -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted }).Count
        if (Test-EncryptedPath $BundlePath) { $encryptedCount++ }
        $parent = Split-Path -Parent $BundlePath
        if (Test-EncryptedPath $parent) { $encryptedCount++ }
    }

    $nodeText = @($NodeLogPaths | ForEach-Object {
        if (Test-Path -LiteralPath $_ -PathType Leaf) { (Get-Content -LiteralPath $_ -Tail 1200 -ErrorAction SilentlyContinue) -join "`n" }
    }) -join "`n"
    $serviceText = if (Test-Path -LiteralPath $ServiceLogPath -PathType Leaf) {
        (Get-Content -LiteralPath $ServiceLogPath -Tail 600 -ErrorAction SilentlyContinue) -join "`n"
    } else { '' }
    $combined = "$nodeText`n$serviceText"
    $explicitAppxError = [bool]($combined -match '(?i)(ERROR_APPX_FILE_NOT_ENCRYPTED|APPX file.+not encrypted|Win32\s+409|\b0x0*199\b)')
    $sessionDiskError = [bool]($serviceText -match '(?i)CreateVirtualDisk failed:\s*0x0*199')
    $copyfileUnknown = [bool]($nodeText -match "(?i)UNKNOWN: unknown error, copyfile '.+\\vm_bundles\\claudevm\.bundle\\")
    $isPackagePrivate = $BundlePath -match '(?i)\\AppData\\Local\\Packages\\Claude_[^\\]+\\LocalCache\\'
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($encryptedCount -gt 0 -and $isPackagePrivate) { $reasons.Add("包私有 VM 路径有 $encryptedCount 个 Encrypted(0x4000) 项") }
    if ($explicitAppxError) { $reasons.Add('日志命中 ERROR_APPX_FILE_NOT_ENCRYPTED (409/0x199)') }
    if ($sessionDiskError) { $reasons.Add('Cowork 服务创建 sessiondata.vhdx 时返回 0x199') }
    if ($copyfileUnknown) { $reasons.Add('包私有 VM 路径出现 UNKNOWN copyfile 提交失败') }
    return [pscustomobject]@{
        Suspected = [bool](($encryptedCount -gt 0 -and $isPackagePrivate) -or $explicitAppxError -or $copyfileUnknown)
        ExplicitAppxError = $explicitAppxError
        SessionDiskError = $sessionDiskError
        EncryptedCount = $encryptedCount
        CopyfileUnknown = $copyfileUnknown
        Reasons = $reasons.ToArray()
    }
}

function Get-VmRebuildProtectionEvidence {
    param([Parameter(Mandatory)]$State)
    $results = @()
    foreach ($path in @([string]$State.OriginalPath, [string]$State.BackupPath) | Select-Object -Unique) {
        if ($path) { $results += Get-AppxProtectedVmEvidence -BundlePath $path }
    }
    $reasons = @($results | ForEach-Object { $_.Reasons } | Select-Object -Unique)
    return [pscustomobject]@{
        Suspected = [bool]($results | Where-Object Suspected)
        ExplicitAppxError = [bool]($results | Where-Object ExplicitAppxError)
        SessionDiskError = [bool]($results | Where-Object SessionDiskError)
        EncryptedCount = [int](($results | Measure-Object -Property EncryptedCount -Sum).Sum)
        CopyfileUnknown = [bool]($results | Where-Object CopyfileUnknown)
        Reasons = $reasons
    }
}

function Invoke-EfsDecrypt {
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('ClaudeSetup.NativeEfs' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClaudeSetup {
    public static class NativeEfs {
        [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DecryptFile(string path, uint reserved);
    }
}
'@
    }
    if (-not [ClaudeSetup.NativeEfs]::DecryptFile($Path, 0)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $message = (New-Object ComponentModel.Win32Exception($errorCode)).Message
        throw "无法解密 EFS 路径：$Path（Win32 $errorCode：$message）"
    }
}

function Test-VmRuntimeEfsItem {
    param([Parameter(Mandatory)]$Item)
    if ($Item.PSIsContainer) { return $true }
    return $Item.Name -like '*.vhdx' -or $Item.Name -in @('initrd', 'vmlinuz')
}

function Get-CurrentBootStamp {
    return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-VmRebuildState {
    if (-not (Test-Path -LiteralPath $script:VmRebuildStatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $script:VmRebuildStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "VM 重建状态文件损坏，拒绝继续：$script:VmRebuildStatePath"
    }
}

function Save-VmRebuildState {
    param([Parameter(Mandatory)]$State)
    New-Item -ItemType Directory -Path $script:ProgramDataRoot -Force | Out-Null
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:VmRebuildStatePath -Encoding UTF8
}

function Assert-VmRebuildState {
    param([Parameter(Mandatory)]$State)
    if ([int]$State.SchemaVersion -ne 1) { throw '不支持的 VM 重建状态版本。' }
    $paths = Get-ClaudePaths
    if (-not $paths) { throw '无法验证 VM 重建状态：Claude 官方 AppX 不存在。' }
    $vmBundles = [IO.Path]::GetFullPath((Join-Path $paths.LocalUserData 'vm_bundles'))
    $expectedBundle = [IO.Path]::GetFullPath((Join-Path $vmBundles 'claudevm.bundle'))
    $stateBundle = [IO.Path]::GetFullPath([string]$State.OriginalPath)
    $stateBackup = [IO.Path]::GetFullPath([string]$State.BackupPath)
    if (-not $stateBundle.Equals($expectedBundle, [StringComparison]::OrdinalIgnoreCase)) {
        throw "VM 重建状态的活动路径不属于当前 Claude：$stateBundle"
    }
    if (-not ([IO.Path]::GetDirectoryName($stateBackup)).Equals($vmBundles, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $stateBackup) -notlike 'claudevm.bundle.backup-*') {
        throw "VM 重建状态的备份路径不安全：$stateBackup"
    }
    if (-not (Test-Path -LiteralPath $stateBackup)) { throw "VM 重建备份丢失：$stateBackup" }
    if (Test-ReparsePoint $stateBackup) { throw "VM 重建备份变成了重解析点：$stateBackup" }
}

function Get-VmBundleStatus {
    param([Parameter(Mandatory)][string]$BundlePath)
    $required = @('rootfs.vhdx', 'sessiondata.vhdx', 'smol-bin.vhdx', 'initrd', 'vmlinuz')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $BundlePath $_)) })
    $encrypted = @()
    if (Test-Path -LiteralPath $BundlePath) {
        $encrypted = @(Get-ChildItem -LiteralPath $BundlePath -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::Encrypted) -and (Test-VmRuntimeEfsItem $_) })
        if (Test-EncryptedPath $BundlePath) { $encrypted += Get-Item -LiteralPath $BundlePath -Force }
    }
    return [pscustomobject]@{
        Ready = (Test-Path -LiteralPath $BundlePath) -and $missing.Count -eq 0 -and -not (Test-ReparsePoint $BundlePath)
        Missing = $missing
        Encrypted = $encrypted
        ReparsePoint = Test-ReparsePoint $BundlePath
    }
}

function Get-OfficialVmManifest {
    param([string]$AsarPath)
    $useCache = -not [bool]$AsarPath
    if ($useCache -and $script:VmManifestCache) { return $script:VmManifestCache }
    $content = $null
    if ($useCache -and $script:OfficialMsixPath -and (Test-Path -LiteralPath $script:OfficialMsixPath -PathType Leaf)) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($script:OfficialMsixPath)
        try {
            $entry = $archive.GetEntry('app/resources/app.asar')
            if (-not $entry) { throw '官方 MSIX 缺少 app/resources/app.asar。' }
            $entryStream = $entry.Open()
            $memory = New-Object IO.MemoryStream
            try {
                $entryStream.CopyTo($memory)
                $content = [Text.Encoding]::UTF8.GetString($memory.ToArray())
            } finally {
                $entryStream.Dispose()
                $memory.Dispose()
            }
        } finally {
            $archive.Dispose()
        }
    } elseif (-not $AsarPath) {
        $paths = Get-ClaudePaths
        if (-not $paths) { throw '无法读取 VM manifest：Claude 官方 MSIX 不存在。' }
        $AsarPath = $paths.Asar
    }
    if (-not $content) {
        if (-not (Test-Path -LiteralPath $AsarPath -PathType Leaf)) { throw "app.asar 不存在：$AsarPath" }
        $content = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($AsarPath))
    }
    $anchor = $content.IndexOf('Cowork VM bundle manifest.', [StringComparison]::Ordinal)
    if ($anchor -lt 0) { throw '官方 app.asar 中没有 Cowork VM bundle manifest。' }
    $tail = $content.Substring($anchor)
    $versionMatch = [regex]::Match($tail, 'versions:\[\{sha:`(?<sha>[0-9a-f]{40})`', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $versionMatch.Success) { throw '无法从官方 app.asar 解析当前 VM bundle 版本。' }

    $currentStart = $anchor + $versionMatch.Index
    $nextVersion = $content.IndexOf('},{sha:`', $currentStart + $versionMatch.Length, [StringComparison]::Ordinal)
    $currentEnd = if ($nextVersion -gt $currentStart) { $nextVersion } else { [Math]::Min($content.Length, $currentStart + 30000) }
    $currentBlock = $content.Substring($currentStart, $currentEnd - $currentStart)
    $windowsIndex = $currentBlock.IndexOf('win32:{', [StringComparison]::Ordinal)
    if ($windowsIndex -lt 0) { throw '当前 VM manifest 没有 Windows 文件列表。' }
    $windowsBlock = $currentBlock.Substring($windowsIndex)
    $architecture = Get-NativeArchitecture
    $architectureMatch = [regex]::Match(
        $windowsBlock,
        ('{0}:\[(?<files>.*?)\]' -f [regex]::Escape($architecture)),
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $architectureMatch.Success) { throw "当前 VM manifest 不支持 $architecture。" }

    $files = New-Object System.Collections.Generic.List[object]
    $fileMatches = [regex]::Matches(
        $architectureMatch.Groups['files'].Value,
        '\{name:`(?<name>[^`]+)`,checksum:`(?<checksum>[0-9a-f]{64})`(?<rest>.*?)\}',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    foreach ($match in $fileMatches) {
        $rawMatch = [regex]::Match($match.Groups['rest'].Value, 'rawChecksum:`(?<checksum>[0-9a-f]{64})`')
        $runtimeChecksum = if ($rawMatch.Success) { $rawMatch.Groups['checksum'].Value.ToLowerInvariant() } else { $null }
        $files.Add([pscustomobject]@{
            Name = $match.Groups['name'].Value
            Checksum = $match.Groups['checksum'].Value.ToLowerInvariant()
            RuntimeChecksum = $runtimeChecksum
        })
    }
    if ($files.Count -eq 0) { throw '当前 VM manifest 的 Windows 文件列表为空。' }
    $result = [pscustomobject]@{
        Sha = $versionMatch.Groups['sha'].Value.ToLowerInvariant()
        Architecture = $architecture
        Files = $files.ToArray()
    }
    if ($useCache) { $script:VmManifestCache = $result }
    return $result
}

function Get-VmBundleCandidateDirectories {
    $paths = Get-ClaudePaths
    if (-not $paths) { return @() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($userData in @($paths.LocalUserData, $paths.RoamingUserData)) {
        $bundle = [IO.Path]::GetFullPath((Join-Path $userData 'vm_bundles\claudevm.bundle'))
        if ($seen.Add($bundle)) { $result.Add($bundle) }
    }
    return $result.ToArray()
}

function Test-FileExclusiveAccess {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        return $true
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Wait-FileExclusiveAccess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Seconds = 15
    )
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (Test-FileExclusiveAccess $Path) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return Test-FileExclusiveAccess $Path
}

function Get-VmCommitFailureNames {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $logs = @(
        (Join-Path $env:LOCALAPPDATA "Packages\$script:PackageFamily\LocalCache\Roaming\Claude\logs\cowork_vm_node.log"),
        (Join-Path $env:APPDATA 'Claude\logs\cowork_vm_node.log')
    )
    foreach ($log in $logs) {
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $log -Tail 800 -ErrorAction SilentlyContinue)) {
            $match = [regex]::Match($line, "copyfile '[^']*[\\/](?<name>rootfs\.vhdx|vmlinuz|initrd)\.tmp' -> '[^']*[\\/]\k<name>'", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) { [void]$names.Add($match.Groups['name'].Value) }
        }
    }
    return ,$names
}

function Get-VmCompressedCommitFailureNames {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $logs = @(
        (Join-Path $env:LOCALAPPDATA "Packages\$script:PackageFamily\LocalCache\Roaming\Claude\logs\cowork_vm_node.log"),
        (Join-Path $env:APPDATA 'Claude\logs\cowork_vm_node.log')
    )
    foreach ($log in $logs) {
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $log -Tail 800 -ErrorAction SilentlyContinue)) {
            $match = [regex]::Match(
                $line,
                "copyfile '[^']*[\\/](?<name>rootfs\.vhdx|vmlinuz|initrd)\.zst\.(?<prefix>[0-9a-f]{12})\.partial' -> '[^']*[\\/](?<destination>[^']+)'",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if ($match.Success -and $match.Groups['destination'].Value.Equals("$($match.Groups['name'].Value).zst", [StringComparison]::OrdinalIgnoreCase)) {
                [void]$names.Add($match.Groups['name'].Value)
            }
        }
    }
    return ,$names
}

function Sync-CompletedVmCompressedCache {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ManifestChecksum,
        [Parameter(Mandatory)][string]$BundleSha,
        [Parameter(Mandatory)][string[]]$BundleDirectories
    )
    if ($Name -notin @('rootfs.vhdx', 'vmlinuz', 'initrd')) { throw "拒绝接管非 manifest VM 缓存：$Name" }
    $source = [IO.Path]::GetFullPath($SourcePath)
    $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or $sourceItem.Length -le 0 -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::Encrypted)) {
        throw "VM 压缩缓存不是普通未加密文件：$source"
    }
    if (-not (Test-FileExclusiveAccess $source)) { return $false }

    $allowedDirectories = @($BundleDirectories | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
    $sourceDirectory = [IO.Path]::GetDirectoryName($source)
    if (-not ($allowedDirectories | Where-Object { $_.Equals($sourceDirectory, [StringComparison]::OrdinalIgnoreCase) })) {
        throw "VM 压缩缓存不属于 Claude 的候选 bundle：$source"
    }
    $prefix = $ManifestChecksum.Substring(0, 12).ToLowerInvariant()
    $allowedLeaves = @("$Name.zst.$prefix.partial", "$Name.zst")
    if ((Split-Path -Leaf $source) -notin $allowedLeaves) {
        throw "VM 压缩缓存名与当前官方 manifest 不匹配：$source"
    }

    $orderedDirectories = @($sourceDirectory) + @($allowedDirectories | Where-Object { -not $_.Equals($sourceDirectory, [StringComparison]::OrdinalIgnoreCase) })
    $materialized = $null
    foreach ($directory in $orderedDirectories) {
        $parent = Split-Path -Parent $directory
        if ((Test-ReparsePoint $parent) -or (Test-EncryptedPath $parent)) {
            throw "VM 缓存目标父目录不安全（重解析点或加密）：$parent"
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        if ((Test-ReparsePoint $directory) -or (Test-EncryptedPath $directory)) {
            throw "VM 缓存目标目录不安全（重解析点或加密）：$directory"
        }

        $final = Join-Path $directory "$Name.zst"
        if (Test-Path -LiteralPath $final) {
            $existing = Get-Item -LiteralPath $final -Force
            if ($existing.PSIsContainer -or $existing.Length -ne $sourceItem.Length) {
                throw "目标 VM 压缩缓存已存在但大小不同，拒绝覆盖：$final"
            }
        } elseif ($source.Equals((Join-Path $directory "$Name.zst.$prefix.partial"), [StringComparison]::OrdinalIgnoreCase)) {
            Move-Item -LiteralPath $source -Destination $final
            $materialized = $final
        } else {
            if (-not $materialized) { $materialized = $source }
            $targetRoot = [IO.Path]::GetPathRoot($final)
            $targetDrive = Get-PSDrive -Name $targetRoot.TrimEnd('\').TrimEnd(':') -ErrorAction SilentlyContinue
            $requiredFree = [int64]$sourceItem.Length + 512MB
            if ($targetDrive -and $targetDrive.Free -lt $requiredFree) {
                throw "同步 $Name 压缩缓存需要 $([math]::Round($requiredFree/1GB,1)) GB，但 $targetRoot 仅剩 $([math]::Round($targetDrive.Free/1GB,1)) GB。"
            }
            Copy-Item -LiteralPath $materialized -Destination $final
            if ((Get-Item -LiteralPath $final -Force).Length -ne $sourceItem.Length) {
                Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
                throw "同步后的 VM 压缩缓存大小不一致：$final"
            }
        }
        if (-not $materialized) { $materialized = $final }
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    foreach ($directory in $orderedDirectories) {
        [IO.File]::WriteAllText((Join-Path $directory ".$Name.zst.origin"), $BundleSha, $utf8NoBom)
    }
    Write-Log "已接管 $Name 的完整下载缓存；下一步将完整核对官方 SHA-256 后独立解压。" OK
    return $true
}

function Test-TrustedNodeZstdRuntime {
    param([Parameter(Mandatory)][string]$NodePath)
    if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $NodePath
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    if ($signature.Status -ne 'Valid' -or $subject -notmatch 'OpenJS Foundation') { return $false }
    try {
        $probe = (& $NodePath -p "typeof require('node:zlib').createZstdDecompress" 2>$null | Select-Object -Last 1).Trim()
        return $LASTEXITCODE -eq 0 -and $probe -eq 'function'
    } catch {
        return $false
    }
}

function Get-TrustedPortableNode {
    $existing = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($existing -and (Test-TrustedNodeZstdRuntime $existing.Source)) {
        Write-Log "使用已安装且 OpenJS 签名有效的 Node.js：$($existing.Source)" INFO
        return $existing.Source
    }

    $architecture = Get-NativeArchitecture
    $nodeArchitecture = if ($architecture -eq 'arm64') { 'arm64' } else { 'x64' }
    $baseUri = 'https://nodejs.org/download/release/latest-v24.x'
    Write-Log '正在从 nodejs.org 获取官方 Node.js 24 便携运行时，用于本次 Zstandard 解压。' INFO
    $sums = (Invoke-WebRequest -Uri "$baseUri/SHASUMS256.txt" -UseBasicParsing).Content
    $match = [regex]::Match(
        $sums,
        "(?m)^(?<hash>[0-9a-f]{64})\s+\*?(?<file>node-v[0-9.]+-win-$nodeArchitecture\.zip)\s*$",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) { throw "Node.js 官方 SHASUMS256.txt 没有 win-$nodeArchitecture 便携包。" }

    $fileName = $match.Groups['file'].Value
    $expectedHash = $match.Groups['hash'].Value.ToLowerInvariant()
    $zipPath = Join-Path $script:DownloadsRoot $fileName
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
        Invoke-WebRequest -Uri "$baseUri/$fileName" -OutFile $zipPath -UseBasicParsing
    }
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "Node.js 便携包 SHA-256 与官方 SHASUMS256.txt 不符：$fileName"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $runtimeRoot = Join-Path $script:DownloadsRoot ([IO.Path]::GetFileNameWithoutExtension($fileName))
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $nodePath = Join-Path $runtimeRoot 'node.exe'
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -match '^[^/]+/node\.exe$' })
        if ($entries.Count -ne 1) { throw 'Node.js 便携包中的 node.exe 数量异常。' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $nodePath, $true)
    } finally {
        $archive.Dispose()
    }
    if (-not (Test-TrustedNodeZstdRuntime $nodePath)) {
        throw 'Node.js node.exe 的 OpenJS Foundation 数字签名或 Zstandard API 验证失败。'
    }
    Write-Log "Node.js 官方便携运行时验证通过：$fileName；SHA-256=$actualHash" OK
    return $nodePath
}

function Expand-VerifiedVmCompressedCache {
    param(
        [Parameter(Mandatory)]$ManifestFile,
        [Parameter(Mandatory)][string]$BundleSha,
        [Parameter(Mandatory)][string[]]$BundleDirectories
    )
    $source = $null
    foreach ($directory in $BundleDirectories) {
        $cache = Join-Path $directory "$($ManifestFile.Name).zst"
        $origin = Join-Path $directory ".$($ManifestFile.Name).zst.origin"
        if ((Test-Path -LiteralPath $cache -PathType Leaf) -and (Test-Path -LiteralPath $origin -PathType Leaf) -and
            ((Get-Content -LiteralPath $origin -Raw -ErrorAction SilentlyContinue).Trim() -eq $BundleSha) -and
            (Test-FileExclusiveAccess $cache)) {
            $item = Get-Item -LiteralPath $cache -Force
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
                -not ($item.Attributes -band [IO.FileAttributes]::Encrypted)) {
                $source = $cache
                break
            }
        }
    }
    if (-not $source) { return $false }

    Write-Log "正在完整校验 $($ManifestFile.Name).zst 与官方 manifest；大文件可能需要数分钟。" INFO
    $archiveHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $ManifestFile.Checksum.ToLowerInvariant()) {
        Write-Log "压缩缓存 SHA-256 与官方 manifest 不一致，保留但拒绝解压：$source" WARN
        return $false
    }

    $destination = Join-Path ([IO.Path]::GetDirectoryName($source)) "$($ManifestFile.Name).claude-setup.tmp"
    if (Test-Path -LiteralPath $destination) {
        $rejected = "$destination.rejected-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $destination -Destination $rejected
        Write-Log "无法证明上次中断的解压文件完整，已保留到：$rejected" WARN
    }

    $nodePath = Get-TrustedPortableNode
    $helper = Join-Path $script:Root 'VmZstdDecompress.js'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "缺少 Zstandard 解压助手：$helper" }
    $stdout = Join-Path $script:ReportsRoot "vm-zstd-$($ManifestFile.Name)-$(Get-Date -Format 'yyyyMMdd-HHmmss').stdout.log"
    $stderr = Join-Path $script:ReportsRoot "vm-zstd-$($ManifestFile.Name)-$(Get-Date -Format 'yyyyMMdd-HHmmss').stderr.log"
    $oldSource = $env:CLAUDE_VM_ZST_SOURCE
    $oldDestination = $env:CLAUDE_VM_ZST_DESTINATION
    $oldHash = $env:CLAUDE_VM_RUNTIME_SHA256
    try {
        $env:CLAUDE_VM_ZST_SOURCE = $source
        $env:CLAUDE_VM_ZST_DESTINATION = $destination
        $env:CLAUDE_VM_RUNTIME_SHA256 = if ($ManifestFile.RuntimeChecksum) { $ManifestFile.RuntimeChecksum } else { '' }
        Write-Log "正在解压 $($ManifestFile.Name) 并计算输出 SHA-256；大文件可能需要数分钟。" INFO
        $process = Start-Process -FilePath $nodePath -ArgumentList ('"{0}"' -f $helper) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($process.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $stderr) { (Get-Content -LiteralPath $stderr -Tail 20) -join ' ' } else { '' }
            throw "Zstandard 解压或完整性校验失败（退出码 $($process.ExitCode)）：$detail"
        }
    } finally {
        $env:CLAUDE_VM_ZST_SOURCE = $oldSource
        $env:CLAUDE_VM_ZST_DESTINATION = $oldDestination
        $env:CLAUDE_VM_RUNTIME_SHA256 = $oldHash
    }
    $resultText = (Get-Content -LiteralPath $stdout -Raw -ErrorAction Stop).Trim()
    try { $result = $resultText | ConvertFrom-Json } catch { throw "Zstandard 解压助手没有返回有效结果：$resultText" }
    if (-not $result.ok -or [string]$result.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Zstandard 解压助手结果缺少有效输出 SHA-256。' }
    $outputHash = ([string]$result.sha256).ToLowerInvariant()
    if ($ManifestFile.RuntimeChecksum -and $outputHash -ne $ManifestFile.RuntimeChecksum.ToLowerInvariant()) {
        throw "解压输出 SHA-256 与官方 rawChecksum 不一致：$outputHash"
    }
    return Sync-VerifiedVmFile -SourcePath $destination -Name $ManifestFile.Name -ExpectedHash $outputHash -BundleSha $BundleSha -BundleDirectories $BundleDirectories
}

function Sync-VerifiedVmFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$BundleSha,
        [Parameter(Mandatory)][string[]]$BundleDirectories
    )
    if ($Name -notin @('rootfs.vhdx', 'vmlinuz', 'initrd')) { throw "拒绝接管非 manifest VM 文件：$Name" }
    $source = [IO.Path]::GetFullPath($SourcePath)
    $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($sourceItem.Attributes -band [IO.FileAttributes]::Encrypted)) {
        throw "VM 临时文件不是普通未加密文件：$source"
    }
    if (-not (Test-FileExclusiveAccess $source)) { return $false }

    $allowedDirectories = @($BundleDirectories | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)
    $sourceDirectory = [IO.Path]::GetDirectoryName($source)
    if (-not ($allowedDirectories | Where-Object { $_.Equals($sourceDirectory, [StringComparison]::OrdinalIgnoreCase) })) {
        throw "VM 临时文件不属于 Claude 的候选 bundle：$source"
    }
    $sourceLeaf = Split-Path -Leaf $source
    if ($sourceLeaf -notin @($Name, "$Name.tmp", "$Name.claude-setup.tmp")) { throw "VM 临时文件名不符合预期：$source" }

    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $ExpectedHash.ToLowerInvariant()) {
        Write-Log "保留但不接管校验值不匹配的 VM 临时文件：$source" WARN
        return $false
    }

    $orderedDirectories = @($sourceDirectory) + @($allowedDirectories | Where-Object { -not $_.Equals($sourceDirectory, [StringComparison]::OrdinalIgnoreCase) })
    $verifiedFinal = $null
    foreach ($directory in $orderedDirectories) {
        $parent = Split-Path -Parent $directory
        if ((Test-ReparsePoint $parent) -or (Test-EncryptedPath $parent)) {
            throw "VM 目标父目录不安全（重解析点或加密）：$parent"
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        if ((Test-ReparsePoint $directory) -or (Test-EncryptedPath $directory)) {
            throw "VM 目标目录不安全（重解析点或加密）：$directory"
        }

        $final = Join-Path $directory $Name
        if (Test-Path -LiteralPath $final) {
            $finalHash = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($finalHash -ne $ExpectedHash.ToLowerInvariant()) {
                throw "目标 VM 文件已存在但校验值不同，拒绝覆盖：$final"
            }
        } elseif ($sourceDirectory.Equals($directory, [StringComparison]::OrdinalIgnoreCase) -and
            $sourceLeaf -in @("$Name.tmp", "$Name.claude-setup.tmp")) {
            Move-Item -LiteralPath $source -Destination $final
            $verifiedFinal = $final
        } else {
            if (-not $verifiedFinal) { $verifiedFinal = $source }
            $targetRoot = [IO.Path]::GetPathRoot($final)
            $targetDrive = Get-PSDrive -Name $targetRoot.TrimEnd('\').TrimEnd(':') -ErrorAction SilentlyContinue
            $requiredFree = [int64]$sourceItem.Length + 512MB
            if ($targetDrive -and $targetDrive.Free -lt $requiredFree) {
                throw "同步 $Name 需要 $([math]::Round($requiredFree/1GB,1)) GB 临时空间，但 $targetRoot 仅剩 $([math]::Round($targetDrive.Free/1GB,1)) GB。"
            }
            Copy-Item -LiteralPath $verifiedFinal -Destination $final
            $copiedHash = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($copiedHash -ne $ExpectedHash.ToLowerInvariant()) {
                Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
                throw "同步后的 VM 文件校验失败：$final"
            }
        }
        if (-not $verifiedFinal) { $verifiedFinal = $final }
    }

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    foreach ($directory in $orderedDirectories) {
        $origin = Join-Path $directory ".$Name.origin"
        [IO.File]::WriteAllText($origin, $BundleSha, $utf8NoBom)
    }
    Write-Log "已接管并同步官方校验通过的 $Name；manifest=$BundleSha" OK
    return $true
}

function Repair-MsixVmCommitFailure {
    param([Parameter(Mandatory)]$State)
    $protection = Get-VmRebuildProtectionEvidence -State $State
    if ($protection.Suspected) {
        if (-not $script:AppxProtectionLogEmitted) {
            Write-Log "检测到 AppX 应用受保护存储证据：$($protection.Reasons -join '；')。为避免生成 409 拒读的明文文件，已禁用外部写入/解压接管。" ERROR
            $script:AppxProtectionLogEmitted = $true
        }
        return $false
    }
    $manifest = Get-OfficialVmManifest
    $bundleDirectories = @(Get-VmBundleCandidateDirectories)
    if ($bundleDirectories.Count -eq 0) { return $false }
    $failureNames = Get-VmCommitFailureNames
    $compressedFailureNames = Get-VmCompressedCommitFailureNames

    foreach ($file in $manifest.Files) {
        if ($file.Name -notin @('rootfs.vhdx', 'vmlinuz', 'initrd')) { continue }
        $activeFinal = Join-Path ([string]$State.OriginalPath) $file.Name
        $activeOrigin = Join-Path ([string]$State.OriginalPath) ".$($file.Name).origin"
        if ((Test-Path -LiteralPath $activeFinal) -and (Test-Path -LiteralPath $activeOrigin) -and
            ((Get-Content -LiteralPath $activeOrigin -Raw -ErrorAction SilentlyContinue).Trim() -eq $manifest.Sha)) { continue }

        $compressedSources = New-Object System.Collections.Generic.List[string]
        $prefix = $file.Checksum.Substring(0, 12).ToLowerInvariant()
        foreach ($directory in $bundleDirectories) {
            $partial = Join-Path $directory "$($file.Name).zst.$prefix.partial"
            if ($compressedFailureNames.Contains($file.Name) -and (Test-Path -LiteralPath $partial -PathType Leaf)) {
                $compressedSources.Add($partial)
            }
            $cache = Join-Path $directory "$($file.Name).zst"
            $cacheOrigin = Join-Path $directory ".$($file.Name).zst.origin"
            if ((Test-Path -LiteralPath $cache -PathType Leaf) -and (Test-Path -LiteralPath $cacheOrigin -PathType Leaf) -and
                ((Get-Content -LiteralPath $cacheOrigin -Raw -ErrorAction SilentlyContinue).Trim() -eq $manifest.Sha)) {
                $compressedSources.Add($cache)
            }
        }
        foreach ($source in @($compressedSources | Select-Object -Unique)) {
            $item = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            $attemptKey = "compressed|$source|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
            if ($script:VmCommitAttempted.ContainsKey($attemptKey)) { continue }
            $script:VmCommitAttempted[$attemptKey] = $true

            Write-Log "检测到 MSIX 无法提交 $($file.Name) 压缩缓存；将先停止 Claude 释放文件句柄，再按当前官方 manifest 完整校验并独立解压。" WARN
            Stop-ClaudeProcesses
            Stop-CoworkVmServiceAndWait
            $cachePromoted = $false
            $promoted = $false
            try {
                if (-not (Wait-FileExclusiveAccess -Path $source -Seconds 15)) {
                    Write-Log "停止 Claude/Cowork 后仍无法独占读取 VM 压缩缓存，暂不接管：$source" WARN
                    continue
                }
                Write-Log "正在验证候选 $($file.Name).zst 的完整 SHA-256；大文件可能需要数分钟。" INFO
                $candidateHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($candidateHash -ne $file.Checksum.ToLowerInvariant()) {
                    Write-Log "候选压缩缓存尚未完整或与当前官方 manifest 不符，保留原文件并让 Claude 继续：$source" WARN
                    continue
                }
                $cachePromoted = Sync-CompletedVmCompressedCache -SourcePath $source -Name $file.Name -ManifestChecksum $file.Checksum -BundleSha $manifest.Sha -BundleDirectories $bundleDirectories
                if ($cachePromoted) {
                    $promoted = Expand-VerifiedVmCompressedCache -ManifestFile $file -BundleSha $manifest.Sha -BundleDirectories $bundleDirectories
                }
            } finally {
                Start-CoworkServices
                if (-not $promoted) { Start-ClaudeAppx }
            }
            if ($promoted) { return $true }
        }

        $sources = New-Object System.Collections.Generic.List[string]
        foreach ($directory in $bundleDirectories) {
            $temp = Join-Path $directory "$($file.Name).tmp"
            if ($failureNames.Contains($file.Name) -and (Test-Path -LiteralPath $temp -PathType Leaf)) { $sources.Add($temp) }
        }
        foreach ($directory in $bundleDirectories) {
            $final = Join-Path $directory $file.Name
            if (Test-Path -LiteralPath $final -PathType Leaf) { $sources.Add($final) }
        }

        foreach ($source in @($sources | Select-Object -Unique)) {
            if (-not $file.RuntimeChecksum) { continue }
            $item = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            $attemptKey = "$source|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
            if ($script:VmCommitAttempted.ContainsKey($attemptKey)) { continue }
            $script:VmCommitAttempted[$attemptKey] = $true

            Write-Log "检测到 MSIX 已校验但未能落盘的 $($file.Name)，将按官方 manifest 复核后接管。" WARN
            Stop-ClaudeProcesses
            Stop-CoworkVmServiceAndWait
            $promoted = $false
            try {
                if (-not (Wait-FileExclusiveAccess -Path $source -Seconds 15)) {
                    Write-Log "停止 Claude/Cowork 后仍无法独占读取 VM 临时文件，暂不接管：$source" WARN
                    continue
                }
                $promoted = Sync-VerifiedVmFile -SourcePath $source -Name $file.Name -ExpectedHash $file.RuntimeChecksum -BundleSha $manifest.Sha -BundleDirectories $bundleDirectories
            } finally {
                Start-CoworkServices
                if (-not $promoted) { Start-ClaudeAppx }
            }
            if ($promoted) { return $true }
        }
    }
    return $false
}

function Start-SafeVmBundleRebuild {
    param([Parameter(Mandatory)][string]$Reason)
    $paths = Get-ClaudePaths
    if (-not $paths) { throw '无法为 VM 重建解析 Claude 路径。' }
    $vmBundles = Join-Path $paths.LocalUserData 'vm_bundles'
    $bundle = Join-Path $vmBundles 'claudevm.bundle'
    if (-not (Test-Path -LiteralPath $bundle)) { throw "需要重建，但未找到原 bundle：$bundle" }
    if ((Test-ReparsePoint $vmBundles) -or (Test-ReparsePoint $bundle)) {
        throw 'vm_bundles 或 claudevm.bundle 是重解析点；为避免移动错误目标，拒绝自动重建。'
    }
    $protection = Get-AppxProtectedVmEvidence -BundlePath $bundle
    if ($protection.Suspected) {
        throw "VM bundle 命中 AppX 应用受保护存储证据，禁止自动备份/重建：$($protection.Reasons -join '；')"
    }
    if (Test-EncryptedPath $vmBundles) {
        throw 'vm_bundles 父目录会让新文件继续继承加密；拒绝在该目录中自动重建。'
    }

    $bundleBytes = [int64](Get-ChildItem -LiteralPath $bundle -Force -File -Recurse -ErrorAction Stop |
        Measure-Object -Property Length -Sum).Sum
    $volumeRoot = [IO.Path]::GetPathRoot($bundle)
    $driveName = $volumeRoot.TrimEnd('\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $requiredFree = $bundleBytes + 2GB
    if ($drive.Free -lt $requiredFree) {
        throw "安全重建需要保留原 bundle 并下载新副本；可用空间 $([math]::Round($drive.Free/1GB,1)) GB，小于所需 $([math]::Round($requiredFree/1GB,1)) GB。"
    }

    Stop-ClaudeProcesses
    Stop-CoworkVmServiceAndWait

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $vmBundles "claudevm.bundle.backup-$stamp"
    if (Test-Path -LiteralPath $backup) { throw "备份目标已存在：$backup" }
    Move-Item -LiteralPath $bundle -Destination $backup
    if ((Test-Path -LiteralPath $bundle) -or -not (Test-Path -LiteralPath $backup)) {
        throw 'VM bundle 同卷重命名后的路径验证失败。'
    }

    $state = [pscustomobject]@{
        SchemaVersion = 1
        Status = 'AwaitingRestart'
        Reason = $Reason
        OriginalPath = $bundle
        BackupPath = $backup
        BackupBytes = $bundleBytes
        StagedAt = (Get-Date).ToUniversalTime().ToString('o')
        BootStamp = Get-CurrentBootStamp
    }
    try {
        Save-VmRebuildState $state
        Register-ResumeAfterRestart
    } catch {
        $registrationError = $_.Exception.Message
        $rolledBack = $false
        try {
            if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $bundle)) {
                Move-Item -LiteralPath $backup -Destination $bundle
            }
            if (Test-Path -LiteralPath $bundle) {
                Remove-ResumeAfterRestart
                Remove-Item -LiteralPath $script:VmRebuildStatePath -Force -ErrorAction SilentlyContinue
                $rolledBack = $true
            }
        } catch {}
        if ($rolledBack) { throw "无法登记重启续跑，VM bundle 已回滚到原路径：$registrationError" }
        throw "无法登记重启续跑且自动回滚未完成。请保留以下路径并人工核对：原路径=$bundle；备份=$backup；错误=$registrationError"
    }
    Write-Log "已将加密 VM bundle 同卷重命名备份到：$backup" OK
    Write-Log '备份不会自动删除；只有新 bundle 完整、未加密且 Cowork 验证通过后才会结束重建状态。' WARN
    return $state
}

function Test-RebuildRestartCompleted {
    param([Parameter(Mandatory)]$State)
    return (Get-CurrentBootStamp) -ne [string]$State.BootStamp
}

function Wait-ForRebuiltVmBundle {
    param(
        [Parameter(Mandatory)]$State,
        [int]$Seconds = 1200
    )
    Write-Log '请在已启动的 Claude 中进入 Cowork；脚本等待并修复 MSIX VM 落盘问题，最长 20 分钟。' WARN
    $initialProtection = Get-VmRebuildProtectionEvidence -State $State
    if ($initialProtection.Suspected) {
        Write-Log "检测到 AppX 应用受保护存储；本工具不会继续重建或向 bundle 写文件：$($initialProtection.Reasons -join '；')" ERROR
        return $false
    }
    $deadline = (Get-Date).AddSeconds($Seconds)
    $nextProgress = Get-Date
    while ((Get-Date) -lt $deadline) {
        $protection = Get-VmRebuildProtectionEvidence -State $State
        if ($protection.Suspected) {
            Write-Log "等待期间命中 AppX 应用受保护存储，立即停止外部修复：$($protection.Reasons -join '；')" ERROR
            return $false
        }
        $status = Get-VmBundleStatus -BundlePath $State.OriginalPath
        if ($status.Ready) { return $true }
        if (Repair-MsixVmCommitFailure -State $State) {
            Start-ClaudeAppx
            Write-Log '已重新启动 Claude 继续下载剩余 VM 文件；如未自动进入，请再次点击 Cowork。' WARN
            Start-Sleep -Seconds 5
            continue
        }
        if ((Get-Date) -ge $nextProgress) {
            $encryptedNames = @($status.Encrypted | Select-Object -ExpandProperty Name -Unique)
            Write-Log "等待重建：缺少=$($status.Missing -join ',')；加密运行项=$($encryptedNames -join ',')；重解析点=$($status.ReparsePoint)" INFO
            $nextProgress = (Get-Date).AddSeconds(30)
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Complete-VmBundleRebuild {
    param([Parameter(Mandatory)]$State)
    $State.Status = 'Completed'
    $State | Add-Member -NotePropertyName VerifiedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Save-VmRebuildState $State
    $receipt = Join-Path $script:ProgramDataRoot ("vm-rebuild-completed-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receipt -Encoding UTF8
    Remove-Item -LiteralPath $script:VmRebuildStatePath -Force
    Write-Log "新 VM bundle 已验证；原加密备份继续保留：$($State.BackupPath)" OK
    Write-Log "重建完成记录：$receipt" INFO
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
        'UNKNOWN: unknown error, copyfile',
        'CreateVirtualDisk failed: 0x199',
        'ERROR_APPX_FILE_NOT_ENCRYPTED',
        'rootfs.vhdx.tmp',
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
    $rebuildState = Get-VmRebuildState
    $vmp = $null
    try { $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop } catch {}

    Add-Finding 'os' 'Info' "$($os.Caption) $($os.Version), build $($os.BuildNumber)" "$($computer.Manufacturer) $($computer.Model)"
    if ($rebuildState) {
        Add-Finding 'vm-rebuild-state' 'Warning' "VM bundle 安全重建进行中：$($rebuildState.Status)" "备份：$($rebuildState.BackupPath)`r`n活动路径：$($rebuildState.OriginalPath)"
    }
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
    elseif ($vmp) { Add-Finding 'virtual-machine-platform' 'Fail' 'Virtual Machine Platform 未启用' }
    else { Add-Finding 'virtual-machine-platform' 'Warning' '当前权限下无法读取 Virtual Machine Platform 状态' '普通用户诊断不会把读取失败误判为未启用。' }

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
    if ($localRoot) {
        $driveName = $localRoot.TrimEnd(':')
        $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        if ($drive) { Add-Finding 'system-drive-free' 'Info' "系统卷剩余 $([math]::Round($drive.Free / 1GB, 1)) GB" }
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
        $appxProtection = Get-AppxProtectedVmEvidence -BundlePath $bundle
        $sessionDiskPresent = Test-Path -LiteralPath (Join-Path $bundle 'sessiondata.vhdx') -PathType Leaf
        if ($appxProtection.SessionDiskError -and -not $sessionDiskPresent) {
            Add-Finding 'appx-session-vhdx' 'Fail' 'Cowork 创建 sessiondata.vhdx 时返回 ERROR_APPX_FILE_NOT_ENCRYPTED (409/0x199)' '这是 AppX 应用受保护存储与当前 Cowork VHD 创建路径的不兼容证据；本工具不会解密、移动或外部写入 bundle。请向 Anthropic 提交 cowork-service.log。'
        } elseif ($appxProtection.SessionDiskError) {
            Add-Finding 'appx-session-vhdx-history' 'Info' '历史日志含 CreateVirtualDisk 0x199，但当前 sessiondata.vhdx 已存在' '保留历史证据；以本轮 Cowork 健康检查为准。'
        } elseif ($appxProtection.ExplicitAppxError) {
            Add-Finding 'appx-protected-storage' 'Fail' '日志命中 ERROR_APPX_FILE_NOT_ENCRYPTED (409/0x199)' ($appxProtection.Reasons -join "`r`n")
        } elseif ($appxProtection.Suspected) {
            Add-Finding 'appx-protected-storage' 'Warning' '检测到 AppX 应用受保护存储迹象；已禁用自动 EFS/重建/外部写入修复' ($appxProtection.Reasons -join "`r`n")
        }
        if (Test-ReparsePoint (Split-Path -Parent $bundle)) { Add-Finding 'vm-reparse' 'Fail' 'vm_bundles 是重解析点/联接' 'HCS 挂载 VHDX 时可能无法解析联接。' }
        elseif (Test-Path -LiteralPath $bundle) { Add-Finding 'vm-reparse' 'Pass' 'vm_bundles 不是重解析点' }

        $encryptedVmFiles = @()
        $nonRuntimeEncryptedFiles = @()
        if (Test-Path -LiteralPath $bundle) {
            $allEncryptedVmFiles = @(Get-ChildItem -LiteralPath $bundle -Force -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted })
            $encryptedVmFiles = @($allEncryptedVmFiles | Where-Object { Test-VmRuntimeEfsItem $_ })
            $nonRuntimeEncryptedFiles = @($allEncryptedVmFiles | Where-Object { -not (Test-VmRuntimeEfsItem $_) })
        }
        if ((Test-EncryptedPath $bundle) -or $encryptedVmFiles.Count -gt 0) {
            Add-Finding 'vm-encryption' 'Warning' "VM bundle 或其中 $($encryptedVmFiles.Count) 个运行文件带 Encrypted(0x4000) 属性" '在 AppX 包私有 LocalCache 中，这可能是应用受保护加密而非可自动解密的经典 EFS；脚本保持原样。'
        } elseif ($nonRuntimeEncryptedFiles.Count -gt 0) {
            Add-Finding 'vm-encryption' 'Info' "仅有 $($nonRuntimeEncryptedFiles.Count) 个 Claude 元数据或下载归档带加密属性" '这些 .origin/.zst/状态文件不是 HCS 直接使用的运行文件，不阻断 Cowork。'
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

        $bundleCandidates = @(Get-VmBundleCandidateDirectories)
        for ($index = 0; $index -lt $bundleCandidates.Count; $index++) {
            $candidate = $bundleCandidates[$index]
            $label = if ($index -eq 0) { 'package-localcache' } else { 'real-roaming' }
            if (Test-Path -LiteralPath $candidate) {
                $inventory = @(Get-ChildItem -LiteralPath $candidate -Force -File -ErrorAction SilentlyContinue |
                    Sort-Object Name |
                    ForEach-Object { '{0}={1} bytes [{2}]' -f $_.Name, $_.Length, $_.Attributes })
                Add-Finding "vm-path-$label" 'Info' "$label VM 路径存在：$candidate" ($inventory -join "`r`n")
            } else {
                Add-Finding "vm-path-$label" 'Info' "$label VM 路径不存在：$candidate"
            }
        }
        $commitFailures = Get-VmCommitFailureNames
        $compressedCommitFailures = Get-VmCompressedCommitFailureNames
        $allCommitFailures = @(@($commitFailures) + @($compressedCommitFailures) | Select-Object -Unique)
        if ($allCommitFailures.Count -gt 0) {
            Add-Finding 'msix-vm-commit' 'Warning' "检测到 MSIX VM 临时文件或压缩缓存落盘失败：$($allCommitFailures -join ', ')" 'Auto 模式会核对官方 manifest；完整验证压缩缓存后独立解压，并在发布前再次校验输出未变化。'
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

function Get-ResumeCommand {
    $installer = Join-Path $script:Root 'install.bat'
    if (-not (Test-Path -LiteralPath $installer)) { throw "重启续跑入口不存在：$installer" }
    return ('cmd.exe /d /c ""{0}""' -f $installer)
}

function Register-ResumeAfterRestart {
    $command = Get-ResumeCommand
    New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeSetupResume' -Value $command
    Write-Log '已注册重启后通过 install.bat 自动继续 Claude Setup；续跑窗口会保留结果与下一步提示。' OK
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
    $script:OfficialMsixPath = $destination
    $script:VmManifestCache = $null
    return [pscustomobject]@{ Path = $destination; Manifest = $manifest }
}

function Stop-ClaudeProcesses {
    Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Stop-CoworkVmServiceAndWait {
    $service = Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name CoworkVMService -Force -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
        $service.Refresh()
        if ($service.Status -ne 'Stopped') { throw 'CoworkVMService 未能在 20 秒内停止。' }
    }
    Get-Process -Name 'cowork-svc' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Install-OfficialClaude {
    param([Parameter(Mandatory)]$Download)
    $systemVolume = Get-AppxSystemVolume
    $installed = Get-ClaudePackage
    $registeredPackage = Get-AppxPackage -Name $script:PackageName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    Stop-ClaudeProcesses

    $versionReference = if ($installed) { $installed } else { $registeredPackage }
    if ($versionReference -and [version]$Download.Manifest.Version -lt [version]$versionReference.Version) {
        throw "官方 latest 包 ($($Download.Manifest.Version)) 低于已注册版本 ($($versionReference.Version))，拒绝降级。"
    }

    $registeredCorePresent = $false
    if ($registeredPackage -and $registeredPackage.InstallLocation) {
        $registeredCorePresent = (Test-Path -LiteralPath (Join-Path $registeredPackage.InstallLocation 'app\Claude.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $registeredPackage.InstallLocation 'app\resources\app.asar') -PathType Leaf)
    }
    if ($registeredPackage -and -not $registeredCorePresent) {
        Write-Log '发现 AppX 注册残留，但默认目录或核心文件缺失；保留应用数据后重新安装。' WARN
        Remove-AppxPackage -Package $registeredPackage.PackageFullName -PreserveApplicationData
        $script:InstallationCandidateCache = $null
        $registeredPackage = $null
    }

    if (-not (Test-ClaudeDefaultInstallationReady $registeredPackage)) {
        Write-Log '默认系统 AppX 路径中没有可用的官方 Claude，触发自动安装/修复。' WARN
    }
    Write-Log "正在安装/更新官方 Claude MSIX；目标为 Windows 系统 AppX 默认路径：$($systemVolume.PackageStorePath)" INFO
    $parameters = @{
        Path = $Download.Path
        ForceApplicationShutdown = $true
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
    Stop-CoworkVmServiceAndWait

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
    $readyBeforeRepair = Test-ClaudeDefaultInstallationReady
    if (-not $readyBeforeRepair) {
        Write-Log '未在官方默认系统 AppX 路径检测到健康 Claude，将自动下载安装。' WARN
    }
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
    $bundle = Join-Path $vmBundles 'claudevm.bundle'
    if (-not (Test-Path -LiteralPath $bundle)) { return }
    $allEncrypted = @(Get-ChildItem -LiteralPath $bundle -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::Encrypted })
    $nonRuntimeEncrypted = @($allEncrypted | Where-Object { -not (Test-VmRuntimeEfsItem $_) })
    $encrypted = @($allEncrypted | Where-Object { Test-VmRuntimeEfsItem $_ })
    if (Test-EncryptedPath $vmBundles) {
        $encrypted += Get-Item -LiteralPath $vmBundles -Force
    }
    if (Test-EncryptedPath $bundle) {
        $encrypted += Get-Item -LiteralPath $bundle -Force
    }
    if ($nonRuntimeEncrypted.Count -gt 0) {
        Write-Log "检测到 $($nonRuntimeEncrypted.Count) 个 .origin/.zst/状态文件带 Encrypted(0x4000) 属性。位于 AppX 包私有目录时可能是正常的应用受保护加密，保持原样。" INFO
    }
    if ($encrypted.Count -gt 0) {
        $protection = Get-AppxProtectedVmEvidence -BundlePath $bundle
        Write-Log "VM 运行文件带 Encrypted(0x4000) 属性；该属性无法仅凭 FileAttributes 区分经典 EFS 与 AppX 应用受保护加密。为防止破坏包原生文件，脚本不会调用 DecryptFileW、不会移动 bundle、不会自动重建。证据：$($protection.Reasons -join '；')" WARN
    }
    return $null
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
    $protection = Get-AppxProtectedVmEvidence -BundlePath $bundle
    if ($protection.Suspected) {
        Write-Log "workspace 不完整（缺少 $($missing -join ', ')），但命中 AppX 应用受保护存储；禁止归档/重建现有 vm_bundles：$($protection.Reasons -join '；')" ERROR
        return
    }
    if (Test-ReparsePoint $vmBundles) {
        throw 'workspace 不完整且 vm_bundles 是重解析点；为避免归档错误目标，拒绝自动重建。'
    }

    New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    $archive = Join-Path $script:BackupRoot ("incomplete-workspace-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Log "workspace 不完整（缺少 $($missing -join ', ')），将旧目录归档到 $archive。" WARN
    Stop-ClaudeProcesses
    Stop-CoworkVmServiceAndWait
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

function Convert-PngToIcon {
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$IconPath
    )
    Add-Type -AssemblyName System.Drawing
    $source = $null
    $bitmap = $null
    $graphics = $null
    $pngStream = $null
    $fileStream = $null
    $writer = $null
    try {
        $source = New-Object Drawing.Bitmap -ArgumentList $PngPath
        $minX = $source.Width
        $minY = $source.Height
        $maxX = -1
        $maxY = -1
        for ($y = 0; $y -lt $source.Height; $y++) {
            for ($x = 0; $x -lt $source.Width; $x++) {
                if ($source.GetPixel($x, $y).A -gt 0) {
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }
        if ($maxX -lt $minX -or $maxY -lt $minY) { throw '官方 Claude PNG 没有可见像素。' }
        $sourceBounds = New-Object Drawing.Rectangle -ArgumentList $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
        $destinationBounds = New-Object Drawing.Rectangle -ArgumentList 2, 2, 252, 252
        $bitmap = New-Object Drawing.Bitmap -ArgumentList 256, 256
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, $destinationBounds, $sourceBounds, [Drawing.GraphicsUnit]::Pixel)

        $pngStream = New-Object IO.MemoryStream
        $bitmap.Save($pngStream, [Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngStream.ToArray()
        $fileStream = [IO.File]::Open($IconPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.BinaryWriter($fileStream)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$pngBytes.Length)
        $writer.Write([uint32]22)
        $writer.Write($pngBytes)
    } finally {
        if ($writer) { $writer.Dispose() } elseif ($fileStream) { $fileStream.Dispose() }
        if ($pngStream) { $pngStream.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($source) { $source.Dispose() }
    }
}

function Install-ClaudeDesktopShortcut {
    $paths = Get-ClaudePaths
    if (-not $paths) { throw '创建桌面快捷方式前未找到 Claude 官方 AppX 包。' }
    try {
        $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        if (-not $desktop) { throw '无法解析当前用户桌面目录。' }

        $assetRoot = Join-Path $env:LOCALAPPDATA 'ClaudeSetup'
        $iconPath = Join-Path $assetRoot 'Claude-official-cropped.ico'
        New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
        try {
            $officialLogo = Join-Path $paths.Package.InstallLocation 'Assets\Square150x150Logo.png'
            if (-not (Test-Path -LiteralPath $officialLogo)) { throw "官方 AppX 图标不存在：$officialLogo" }
            Convert-PngToIcon -PngPath $officialLogo -IconPath $iconPath
            if (-not (Test-Path -LiteralPath $iconPath) -or (Get-Item -LiteralPath $iconPath).Length -le 22) {
                throw '生成的 Claude ICO 无效。'
            }
        } catch {
            Write-Log "无法生成持久化官方 Claude 图标，将使用程序图标：$($_.Exception.Message)" WARN
            $iconPath = $paths.Exe
        }

        $shortcutPath = Join-Path $desktop 'Claude.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = Join-Path $env:WINDIR 'explorer.exe'
        $shortcut.Arguments = "shell:AppsFolder\$script:Aumid"
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.Description = 'Claude Desktop（官方 AppX）'
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.Save()
        $iconRefresh = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
        if (Test-Path -LiteralPath $iconRefresh) { Start-Process -FilePath $iconRefresh -ArgumentList '-show' -WindowStyle Hidden -ErrorAction SilentlyContinue }
        Write-Log "已创建或更新桌面快捷方式：$shortcutPath" OK
        return $shortcutPath
    } catch {
        Write-Log "桌面快捷方式创建失败，但不影响 Claude/Cowork：$($_.Exception.Message)" WARN
        return $null
    }
}

function Start-ClaudeAppx {
    if (-not (Get-ClaudePackage)) { throw 'Claude 尚未安装。' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$script:Aumid"
    Write-Log '已通过官方 AppX 入口启动 Claude Desktop。' OK
}

function Invoke-HealthWait {
    param(
        [int]$HandshakeSeconds = 45,
        [int]$VmSeconds = 120
    )
    $serviceLog = 'C:\ProgramData\Claude\Logs\cowork-service.log'
    $mainProcess = Get-Process -Name Claude -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    $cutoff = if ($mainProcess) { $mainProcess.StartTime.AddSeconds(-3) } else { (Get-Date).AddSeconds(-5) }
    $handshakeDeadline = (Get-Date).AddSeconds($HandshakeSeconds)
    $vmDeadline = $null
    $handshakePassed = $false
    $vmRequested = $false
    while ((Get-Date) -lt $handshakeDeadline -or ($vmDeadline -and (Get-Date) -lt $vmDeadline)) {
        if (Test-Path -LiteralPath $serviceLog) {
            $tail = Get-Content -LiteralPath $serviceLog -Tail 160 -ErrorAction SilentlyContinue
            $currentRun = @($tail | Where-Object {
                if ($_ -notmatch '^(?<stamp>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)') { return $false }
                $stamp = [datetime]::MinValue
                return [datetime]::TryParse($Matches.stamp, [ref]$stamp) -and $stamp -ge $cutoff
            })
            if ($currentRun -match 'Client signature verified:' -and $currentRun -match 'Persistent RPC: entering loop') {
                if (-not $handshakePassed) {
                    $handshakePassed = $true
                    Write-Log 'Cowork 服务已验证当前 Claude 官方签名，RPC 连接正常。' OK
                }
            }
            if ($currentRun -match 'Configuring VM for user=|Creating HCS compute system|Starting compute system') {
                if (-not $vmRequested) {
                    $vmRequested = $true
                    $vmDeadline = (Get-Date).AddSeconds($VmSeconds)
                    Write-Log '检测到本轮已请求启动 Cowork VM，继续等待网络与 API。' INFO
                }
            }
            if ($vmRequested -and $currentRun -match 'API reachability: REACHABLE' -and $currentRun -match 'sdk-daemon is ready') {
                Write-Log 'Cowork VM 网络已连接，API 可达。' OK
                return $true
            }
            if ($currentRun -match 'signature verification failed') {
                Write-Log '当前 Claude 客户端被 Cowork 服务拒绝：签名验证失败。' ERROR
                return $false
            }
            if ($handshakePassed -and -not $vmRequested -and (Get-Date) -ge $handshakeDeadline) {
                Write-Log 'Claude 与 Cowork 服务握手通过；VM 尚未被用户请求，深度 VM 检测延期到首次进入 Cowork。' OK
                return $true
            }
        }
        Start-Sleep -Seconds 2
    }
    if ($handshakePassed -and -not $vmRequested) {
        Write-Log 'Claude 与 Cowork 服务握手通过；VM 尚未被用户请求，深度 VM 检测延期到首次进入 Cowork。' OK
        return $true
    }
    if (-not $handshakePassed) {
        Write-Log "未在 $HandshakeSeconds 秒内确认本轮 Claude/Cowork 签名握手；验证失败。" ERROR
    } elseif ($vmRequested) {
        Write-Log "本轮已请求 Cowork VM，但未在 $VmSeconds 秒内确认 API 可达；验证失败。" ERROR
    }
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

    $rebuildState = Get-VmRebuildState
    if ($rebuildState) { Assert-VmRebuildState $rebuildState }
    if ($rebuildState -and $rebuildState.Status -eq 'Completed') {
        $completedStatus = Get-VmBundleStatus -BundlePath $rebuildState.OriginalPath
        if (-not $completedStatus.Ready) { throw 'VM 重建状态标记为 Completed，但活动 bundle 未通过复核。' }
        Remove-Item -LiteralPath $script:VmRebuildStatePath -Force
        Write-Log "已清理上次完成但未移除的活动状态；备份仍保留：$($rebuildState.BackupPath)" INFO
        $rebuildState = $null
    }
    if ($rebuildState -and -not (Test-RebuildRestartCompleted $rebuildState)) {
        Register-ResumeAfterRestart
        Write-Log '加密 VM bundle 已安全备份；必须重启 Windows 后才能创建全新的 VM。' WARN
        if ($RestartIfNeeded) {
            Write-Log '将在 15 秒后重新启动。运行 shutdown /a 可取消。' WARN
            & shutdown.exe /r /t 15 /c 'Claude Setup 正在重建 Cowork VM bundle'
        }
        return 3010
    }
    if ($rebuildState) {
        $rebuildState.Status = 'Rebuilding'
        Save-VmRebuildState $rebuildState
        Write-Log "检测到重启已完成，开始验证新 VM bundle；旧备份：$($rebuildState.BackupPath)" INFO
    }

    Repair-ExistingPackageVolume
    $paths = Repair-ClaudePackageAndSignature
    if (-not $rebuildState) {
        $stagedRebuild = Repair-VmStorageAttributes
        if ($stagedRebuild) {
            Write-Log '已完成可回滚备份。请重启 Windows；登录后脚本会自动继续。' WARN
            if ($RestartIfNeeded) {
                Write-Log '将在 15 秒后重新启动。运行 shutdown /a 可取消。' WARN
                & shutdown.exe /r /t 15 /c 'Claude Setup 正在重建 Cowork VM bundle'
            }
            return 3010
        }
        Repair-IncompleteWorkspace
    }
    Start-CoworkServices
    Install-CompatibleChinese
    [void](Install-ClaudeDesktopShortcut)
    if (-not $SkipLaunch) {
        Start-ClaudeAppx
        if ($rebuildState) {
            if (-not (Wait-ForRebuiltVmBundle -State $rebuildState)) {
                Write-Log '新 VM bundle 尚未完成。请进入 Claude 的 Cowork，等待下载完成后再次运行 install.bat；旧备份仍保留。' ERROR
                return 4
            }
            if (-not (Invoke-HealthWait -VmSeconds 300)) { return 3 }
            Complete-VmBundleRebuild -State $rebuildState
        } elseif (-not (Invoke-HealthWait)) {
            return 3
        }
    } elseif ($rebuildState) {
        Write-Log 'VM 重建验证不能与 -SkipLaunch 同时使用；旧备份和重建状态均已保留。' ERROR
        return 4
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
            [void](Install-ClaudeDesktopShortcut)
            if (-not $SkipLaunch) { Start-ClaudeAppx }
        }
        'Repair' {
            Enable-CoworkPrerequisites
            if ($script:NeedsRestart) { Register-ResumeAfterRestart; $exitCode = 3010; break }
            Repair-ExistingPackageVolume
            [void](Repair-ClaudePackageAndSignature)
            $stagedRebuild = Repair-VmStorageAttributes
            if ($stagedRebuild) {
                Write-Log '已完成可回滚备份。请重启 Windows；登录后运行 install.bat 继续验证。' WARN
                $exitCode = 3010
                break
            }
            Repair-IncompleteWorkspace
            Start-CoworkServices
            [void](Install-ClaudeDesktopShortcut)
            if (-not $SkipLaunch) {
                Start-ClaudeAppx
                if (-not (Invoke-HealthWait)) { $exitCode = 3 }
            }
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
