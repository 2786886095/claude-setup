$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scripts = @(
    Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' -File -Recurse
)
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in $($script.FullName): $($errors -join '; ')"
    }
}

$main = Get-Content -LiteralPath (Join-Path $root 'ClaudeSetup.ps1') -Raw -Encoding UTF8
$batch = Get-Content -LiteralPath (Join-Path $root 'install.bat') -Raw -Encoding UTF8
$legacyBatch = Get-Content -LiteralPath (Join-Path $root 'setup.cmd') -Raw -Encoding UTF8
$elevator = Get-Content -LiteralPath (Join-Path $root 'ElevateInstall.ps1') -Raw -Encoding UTF8
$attributes = Get-Content -LiteralPath (Join-Path $root '.gitattributes') -Raw -Encoding UTF8
$batchFiles = Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in @('.bat', '.cmd') }
if ($attributes -notmatch '(?m)^\*\.bat text eol=crlf\r?$' -or $attributes -notmatch '(?m)^\*\.cmd text eol=crlf\r?$') {
    throw '.gitattributes must force CRLF for Windows batch and command files.'
}
foreach ($batchFile in $batchFiles) {
    $batchText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($batchFile.FullName))
    if ($batchText -match '(?<!\r)\n') {
        throw "$($batchFile.Name) contains bare LF line endings; cmd.exe compatibility requires CRLF."
    }
}
$requiredSafetyChecks = @(
    'Get-AuthenticodeSignature',
    'Anthropic',
    'VirtualMachinePlatform',
    'CoworkVMService',
    'HashMismatch',
    'Get-AppxVolume',
    'Get-AppxSystemVolume',
    'Set-AppxDefaultVolume',
    'Move-AppxPackage',
    'RPC pipe closed',
    'sessiondata.vhdx',
    'SupportCompressedVolumes'
    'Get-ClaudeInstallationCandidates'
    'Select-ClaudeInstallation'
    'Test-ClaudeDefaultInstallationReady'
    'PreserveApplicationData'
    '[int]$HandshakeSeconds = 45'
    '[int]$VmSeconds = 120'
    'Client signature verified:'
    'VM 尚未被用户请求'
    'DecryptFile(string path, uint reserved)'
    'Install-ClaudeDesktopShortcut'
    'Convert-PngToIcon'
    'shell:AppsFolder\$script:Aumid'
    'Assets\Square150x150Logo.png'
    'Claude-official.ico'
    'Test-VmRuntimeEfsItem'
    'Start-SafeVmBundleRebuild'
    'Wait-ForRebuiltVmBundle'
    'Complete-VmBundleRebuild'
    'Assert-VmRebuildState'
    'vm-rebuild-active.json'
    'claudevm.bundle.backup-'
    'BackupBytes'
    'Get-ResumeCommand'
)
foreach ($text in $requiredSafetyChecks) {
    if (-not $main.Contains($text)) {
        throw "Expected safety/diagnostic check is missing: $text"
    }
}

if ($main -match 'AllowUnsigned') {
    throw 'The installer must never install an unsigned AppX package.'
}
if ($main -match 'disableAutoUpdates|Register-ScheduledTask|New-ScheduledTask') {
    throw 'The one-shot installer must not take over Claude updates or create scheduled tasks.'
}
if ($main -notmatch 'Move-Item -LiteralPath \$bundle -Destination \$backup') {
    throw 'Encrypted VM rebuild must use an in-volume rename to a unique backup.'
}
if ($main -match 'Remove-Item[^\r\n]*(BackupPath|claudevm\.bundle\.backup)') {
    throw 'The installer must never automatically delete an encrypted VM backup.'
}
if ($main -notmatch '\$requiredFree = \$bundleBytes \+ 2GB') {
    throw 'Safe rebuild must reserve enough free space for the retained backup and new bundle.'
}
if ($main -match 'cipher\.exe\s+/d') {
    throw 'EFS repair must use the Unicode DecryptFile API so non-ASCII profile paths are safe.'
}
if ($main -match '(?s)ForceApplicationShutdown\s*=.*ForceTargetApplicationShutdown\s*=' -or
    $main -match '(?s)ForceTargetApplicationShutdown\s*=.*ForceApplicationShutdown\s*=') {
    throw 'Add-AppxPackage cannot receive ForceApplicationShutdown and ForceTargetApplicationShutdown together.'
}
if ($main -match '(?s)\$parameters\s*=\s*@\{[^}]*InstallAllResources\s*=') {
    throw 'A plain Claude .msix must not receive the bundle-only InstallAllResources option.'
}
if ($main -match 'Add-AppxPackage\s+-Path' -and $main -notmatch 'parameters\.Volume|parameters\.Volume =|\$parameters\.Volume') {
    throw 'Official MSIX installation must target the Windows system AppX volume.'
}
if ($main -notmatch 'Remove-ResumeAfterRestart') {
    throw 'The one-shot installer must clear its temporary RunOnce resume entry.'
}
if ($main -notmatch 'Invoke-HealthWait -VmSeconds 300\)\) \{ return 3 \}' -or
    $main -notmatch 'elseif \(-not \(Invoke-HealthWait\)\)') {
    throw 'Normal and rebuilt Auto paths must fail closed when the current-run Cowork health check does not pass.'
}
if ($main -notmatch 'if \(\$handshakePassed -and -not \$vmRequested\)') {
    throw 'A valid handshake with no requested VM must pass after the handshake deadline.'
}

$requiredBatchParts = @(
    '%~dp0ClaudeSetup.ps1',
    '%~f0',
    'fltmc.exe',
    'ElevateInstall.ps1',
    '-Action Auto'
)
foreach ($text in $requiredBatchParts) {
    if (-not $batch.Contains($text)) {
        throw "Expected one-click BAT behavior is missing: $text"
    }
}
if ($legacyBatch -notmatch '(?i)call\s+"%~dp0install\.bat"') {
    throw 'setup.cmd must delegate to the canonical install.bat entry point.'
}
if ($batch -notmatch '(?i)Recommended entry:\s*install\.bat') {
    throw 'install.bat must visibly identify itself as the recommended entry point.'
}
if ($legacyBatch -notmatch '旧版兼容入口' -or $legacyBatch -notmatch '唯一推荐入口 install\.bat') {
    throw 'setup.cmd must visibly identify itself as a legacy compatibility entry.'
}
if ($batch -notmatch 'CLAUDE_SETUP_EXIT%"=="4"' -or $batch -notmatch 'encrypted backup has NOT been deleted') {
    throw 'install.bat must explain the pending Cowork rebuild exit code without claiming deletion.'
}
if ($batch -notmatch 'NEXT STEPS / 下一步：重启后继续完成' -or
    $batch -notmatch 'Do NOT move or delete this extracted setup folder' -or
    $batch -notmatch 'enter Cowork and keep this window open' -or
    $batch -notmatch '再次运行 install\.bat，完成最终验证') {
    throw 'install.bat must show complete numbered next steps for restart and pending rebuild outcomes.'
}
if ($batch -notmatch 'install-bootstrap\.log' -or $batch -notmatch 'requesting UAC through cmd\.exe helper') {
    throw 'install.bat must leave a bootstrap log before UAC or ClaudeSetup.ps1 starts.'
}
if ($batch -notmatch 'CLAUDE_SETUP_ELEVATION_EXIT%"=="194" exit /b 194' -or
    $batch -notmatch 'CLAUDE_SETUP_ELEVATION_EXIT%"=="4" exit /b 4') {
    throw 'The non-elevated parent must pass through expected restart and pending-rebuild exit codes.'
}
foreach ($required in @('$env:ComSpec', '-Verb RunAs', '-Wait', '-PassThru', '/d /c')) {
    if (-not $elevator.Contains($required)) { throw "ElevateInstall.ps1 is missing: $required" }
}
if ($elevator -match 'Start-Process -FilePath \$BatchPath') {
    throw 'The elevation helper must invoke cmd.exe, not pass a batch file directly to Start-Process.'
}

$previousImportMode = $env:CLAUDE_SETUP_IMPORT_ONLY
try {
    $env:CLAUDE_SETUP_IMPORT_ONLY = '1'
    . (Join-Path $root 'ClaudeSetup.ps1') -Action Diagnose

    $x64Url = Get-OfficialPackageUrl -Architecture x64
    $arm64Url = Get-OfficialPackageUrl -Architecture arm64
    if ($x64Url -ne 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect') {
        throw "Unexpected x64 download URL: $x64Url"
    }
    if ($arm64Url -ne 'https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect') {
        throw "Unexpected ARM64 download URL: $arm64Url"
    }
    if ((Get-VolumeRoot 'C:\Users\Example\AppData') -ne 'C:') {
        throw 'Volume-root detection failed for C:.'
    }

    $mockCandidates = @(
        [pscustomobject]@{ Type = 'EXE'; Score = 300; Version = [version]'99.0'; Path = 'C:\Fake\Newer\Claude.exe' },
        [pscustomobject]@{ Type = 'MSIX'; Score = 1200; Version = [version]'2.0'; Path = 'C:\Fake\BrokenMsix\Claude.exe' },
        [pscustomobject]@{ Type = 'MSIX'; Score = 1900; Version = [version]'1.0'; Path = 'C:\Fake\ValidCoworkMsix\Claude.exe' }
    )
    $selectedMock = Select-ClaudeInstallation $mockCandidates
    if ($selectedMock.Path -ne 'C:\Fake\ValidCoworkMsix\Claude.exe') {
        throw "A signed Cowork MSIX must outrank newer/broken EXE installs: $($selectedMock.Path)"
    }

    if (Test-ClaudeDefaultInstallationReady $null) {
        throw 'No registered MSIX must be treated as requiring automatic installation.'
    }
    $missingPackage = [pscustomobject]@{
        InstallLocation = 'Z:\PathThatDoesNotExist\Claude'
        PackageFullName = 'Claude_missing_x64__pzs8sxrjxfjjc'
    }
    if (Test-ClaudeDefaultInstallationReady $missingPackage) {
        throw 'A missing default installation path must require automatic installation.'
    }

    $originMarker = [pscustomobject]@{ PSIsContainer = $false; Length = 64; Name = '.rootfs.vhdx.zst.origin' }
    $runtimeDisk = [pscustomobject]@{ PSIsContainer = $false; Length = 8447328256; Name = 'rootfs.vhdx' }
    $compressedArchive = [pscustomobject]@{ PSIsContainer = $false; Length = 1337; Name = 'rootfs.vhdx.zst' }
    $kernel = [pscustomobject]@{ PSIsContainer = $false; Length = 1337; Name = 'vmlinuz' }
    $directory = [pscustomobject]@{ PSIsContainer = $true; Length = $null; Name = 'claudevm.bundle' }
    if ((Test-VmRuntimeEfsItem $originMarker) -or (Test-VmRuntimeEfsItem $compressedArchive)) {
        throw 'Claude metadata and download archives must not block Cowork EFS repair.'
    }
    if (-not (Test-VmRuntimeEfsItem $runtimeDisk) -or -not (Test-VmRuntimeEfsItem $kernel) -or -not (Test-VmRuntimeEfsItem $directory)) {
        throw 'VM directories, VHDX files, initrd, and vmlinuz must remain strict EFS repair targets.'
    }

    $statusRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClaudeSetupStatic-{0}" -f [guid]::NewGuid().ToString('N'))
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    try {
        New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
        foreach ($name in @('rootfs.vhdx', 'sessiondata.vhdx', 'smol-bin.vhdx', 'initrd', 'vmlinuz')) {
            New-Item -ItemType File -Path (Join-Path $statusRoot $name) -Force | Out-Null
        }
        $readyStatus = Get-VmBundleStatus -BundlePath $statusRoot
        if (-not $readyStatus.Ready) { throw 'A complete unencrypted test bundle must be ready.' }
        Remove-Item -LiteralPath (Join-Path $statusRoot 'sessiondata.vhdx') -Force
        $missingStatus = Get-VmBundleStatus -BundlePath $statusRoot
        if ($missingStatus.Ready -or $missingStatus.Missing -notcontains 'sessiondata.vhdx') {
            throw 'Bundle readiness must require sessiondata.vhdx.'
        }
    } finally {
        $resolvedStatusRoot = [IO.Path]::GetFullPath($statusRoot)
        if ($resolvedStatusRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedStatusRoot) -like 'ClaudeSetupStatic-*') {
            Remove-Item -LiteralPath $resolvedStatusRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $currentCandidates = @(Get-ClaudeInstallationCandidates)
    if (Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue) {
        $currentSelection = Select-ClaudeInstallation $currentCandidates
        if (-not $currentSelection -or $currentSelection.Type -ne 'MSIX') {
            throw 'Installed Claude MSIX was not discovered and preferred.'
        }
    }
    $argumentItems = @(Get-CurrentArgumentList)
    $fileIndex = [Array]::IndexOf($argumentItems, '-File')
    if ($fileIndex -lt 0 -or $fileIndex + 1 -ge $argumentItems.Count -or
        $argumentItems[$fileIndex + 1] -notmatch '^".+ClaudeSetup\.ps1"$') {
        throw "Resume/elevation command does not quote the script path: $($argumentItems -join ' ')"
    }
    $resumeCommand = Get-ResumeCommand
    if ($resumeCommand -notmatch '^cmd\.exe /d /c "".+install\.bat""$' -or $resumeCommand -match 'ClaudeSetup\.ps1') {
        throw "RunOnce must call the canonical pausing install.bat instead of a transient PowerShell window: $resumeCommand"
    }
} finally {
    $env:CLAUDE_SETUP_IMPORT_ONLY = $previousImportMode
}

Write-Host "Validated $($scripts.Count) PowerShell script(s)."
