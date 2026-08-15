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
$diagnoseBatch = Get-Content -LiteralPath (Join-Path $root 'diagnose.cmd') -Raw -Encoding UTF8
$shareDiagnoseBatch = Get-Content -LiteralPath (Join-Path $root 'share-diagnose.cmd') -Raw -Encoding UTF8
$elevator = Get-Content -LiteralPath (Join-Path $root 'ElevateInstall.ps1') -Raw -Encoding UTF8
$zstdHelperPath = Join-Path $root 'VmZstdDecompress.js'
$zstdHelper = Get-Content -LiteralPath $zstdHelperPath -Raw -Encoding UTF8
$security = Get-Content -LiteralPath (Join-Path $root 'SECURITY.md') -Raw -Encoding UTF8
$releaseWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Raw -Encoding UTF8
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
    'Get-AppxPackageLocationInfo'
    'GetFinalPathNameByHandleW'
    'Set-SystemAppxDefaultVolume'
    'Initialize-ClaudeIndependentUserData'
    'CLAUDE_USER_DATA_DIR'
    '--user-data-dir'
    'CreateVirtualDisk failed: 0x1772'
    'Get-ClaudeUserDataProtectionKind'
    'Get-ClaudeVmLifecycleEvidence'
    'Get-ClaudeVmCriticalEfsItems'
    'Get-ClaudeNonVmEncryptedItems'
    'Repair-ConfirmedIndependentUserDataEfs'
    '[int]$HandshakeSeconds = 45'
    '[int]$VmSeconds = 120'
    'Client signature verified:'
    'VM started successfully'
    'Network status:'
    'API reachability:'
    'sdk-daemon is ready'
    'VM 尚未被用户请求'
    'DecryptFile(string path, uint reserved)'
    'Install-ClaudeDesktopShortcut'
    'Convert-PngToIcon'
    'shell:AppsFolder\$script:Aumid'
    'Assets\Square150x150Logo.png'
    'Claude-official-cropped.ico'
    '$source.GetPixel($x, $y).A'
    '$destinationBounds'
    'Test-VmRuntimeEfsItem'
    'Get-OfficialVmManifest'
    'Get-VmCommitFailureNames'
    'Get-VmCompressedCommitFailureNames'
    'Get-AppxProtectedVmEvidence'
    'Get-VmRebuildProtectionEvidence'
    'ERROR_APPX_FILE_NOT_ENCRYPTED'
    'CreateVirtualDisk failed: 0x199'
    'Stop-CoworkVmServiceAndWait'
    'Sync-VerifiedVmFile'
    'Sync-CompletedVmCompressedCache'
    'Wait-FileExclusiveAccess'
    'Get-TrustedPortableNode'
    'Test-TrustedNodeZstdRuntime'
    'Expand-VerifiedVmCompressedCache'
    'SHASUMS256.txt'
    'OpenJS Foundation'
    'VmZstdDecompress.js'
    'Repair-MsixVmCommitFailure'
    'Cowork VM bundle manifest.'
    'RuntimeChecksum'
    'OfficialMsixPath'
    'app/resources/app.asar'
    'UNKNOWN: unknown error, copyfile'
    '最长 20 分钟'
    'Start-SafeVmBundleRebuild'
    'Wait-ForRebuiltVmBundle'
    'Complete-VmBundleRebuild'
    'Assert-VmRebuildState'
    'Resolve-VmRebuildState'
    'Invoke-ResolveLegacyState'
    'Get-SetupPlan'
    'Get-SetupPlanExecutionAdvice'
    "'Plan'"
    "'ResolveLegacyState'"
    'Get-AbandonedLegacyVmRebuildEvidence'
    'Get-LegacyStateBootstrapEvidence'
    'Wait-AbandonedLegacyVmRebuildEvidence'
    'Initialize-TrustedSecurityModule'
    'Get-TrustedAuthenticodeSignature'
    'Archive-SupersededVmRebuildState'
    'Test-AbandonedLegacyVmRebuildState'
    'Archive-AbandonedVmRebuildState'
    'MinimumLifecycleTime'
    'LifecycleFreshAfterAnchor'
    'Get-RecentCoworkErrorEvidence'
    'Invoke-HttpFileDownload'
    'DOWNLOAD_LENGTH_MISMATCH'
    'ConvertTo-ShareSafeDiagnosticValue'
    'vm-rebuild-state-abandoned'
    'state-history'
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
foreach ($required in @('actions/attest@v4', 'id-token: write', 'attestations: write', 'artifact-metadata: write', 'gh release create', 'git ls-files')) {
    if (-not $releaseWorkflow.Contains($required)) { throw "Release workflow is missing provenance/release control: $required" }
}
if ($main -match '(?s)Remove-AppxPackage[^\r\n]*PreserveApplicationData') {
    throw 'PreserveApplicationData is not valid protection for a normal signed MSIX; profile migration must complete before removal.'
}
if ($main -match 'disableAutoUpdates|Register-ScheduledTask|New-ScheduledTask') {
    throw 'The one-shot installer must not take over Claude updates or create scheduled tasks.'
}
foreach ($required in @('v1.0.4', 'v1.0.13', 'v1.1.0', 'v1.1.1', 'v1.1.2', 'v1.2.0', 'v1.2.1', 'v1.2.2', 'ERROR_APPX_FILE_NOT_ENCRYPTED', '0x1772', 'Claude-3p', '不要把活动 VHDX 硬链接到唯一备份')) {
    if (-not $security.Contains($required)) { throw "SECURITY.md is missing required incident guidance: $required" }
}
$storageStart = $main.IndexOf('function Repair-VmStorageAttributes')
$storageEnd = $main.IndexOf('function Repair-IncompleteWorkspace', $storageStart)
if ($storageStart -lt 0 -or $storageEnd -le $storageStart) { throw 'Unable to isolate Repair-VmStorageAttributes.' }
$storageBlock = $main.Substring($storageStart, $storageEnd - $storageStart)
if ($storageBlock -match 'Invoke-EfsDecrypt|Start-SafeVmBundleRebuild|Move-Item') {
    throw 'AppX VM storage repair must not decrypt, move, or rebuild encrypted bundle data automatically.'
}
$volumeStart = $main.IndexOf('function Repair-ExistingPackageVolume')
$volumeEnd = $main.IndexOf('function Repair-ClaudeUserDataLayout', $volumeStart)
if ($volumeStart -lt 0 -or $volumeEnd -le $volumeStart) { throw 'Unable to isolate Repair-ExistingPackageVolume.' }
$volumeBlock = $main.Substring($volumeStart, $volumeEnd - $volumeStart)
if ($volumeBlock.IndexOf('Initialize-ClaudeIndependentUserData') -gt $volumeBlock.IndexOf('Remove-AppxPackage') -or
    $volumeBlock -notmatch '(?s)Test-AnthropicSignature.*?Remove-AppxPackage') {
    throw 'AppX uninstall fallback must migrate profile data and revalidate the downloaded signature before package removal.'
}
$efsStart = $main.IndexOf('function Repair-ConfirmedIndependentUserDataEfs')
$efsEnd = $main.IndexOf('function Test-VmRuntimeEfsItem', $efsStart)
if ($efsStart -lt 0 -or $efsEnd -le $efsStart) { throw 'Unable to isolate safe independent EFS repair.' }
$efsBlock = $main.Substring($efsStart, $efsEnd - $efsStart)
if ($efsBlock -notmatch "Kind -ne 'ConfirmedUserEfs'" -or $efsBlock -notmatch 'Invoke-EfsDecrypt' -or
    $efsBlock -notmatch 'Get-ClaudeVmCriticalEfsItems' -or $efsBlock -match 'foreach.+NonVmItems') {
    throw 'EFS repair must require confirmed current evidence, decrypt only VM-critical items, and verify only that scope.'
}
$archiveStart = $main.IndexOf('function Archive-SupersededVmRebuildState')
$archiveEnd = $main.IndexOf('function Resolve-VmRebuildState', $archiveStart)
if ($archiveStart -lt 0 -or $archiveEnd -le $archiveStart) { throw 'Unable to isolate superseded-state archival.' }
$archiveBlock = $main.Substring($archiveStart, $archiveEnd - $archiveStart)
if ($archiveBlock -notmatch '(?s)Move-Item.+VmRebuildStatePath.+originalArchive' -or
    $archiveBlock -match 'Remove-Item.+BackupPath') {
    throw 'Superseded rebuild state must be archived while every legacy VM backup remains untouched.'
}
$abandonedArchiveStart = $main.IndexOf('function Archive-AbandonedVmRebuildState')
$abandonedArchiveEnd = $main.IndexOf('function Resolve-VmRebuildState', $abandonedArchiveStart)
if ($abandonedArchiveStart -lt 0 -or $abandonedArchiveEnd -le $abandonedArchiveStart) { throw 'Unable to isolate abandoned-state archival.' }
$abandonedArchiveBlock = $main.Substring($abandonedArchiveStart, $abandonedArchiveEnd - $abandonedArchiveStart)
if ($abandonedArchiveBlock -notmatch '(?s)Get-VmRebuildStatePathShape.*?Test-Path.+Bundle.*?Test-Path.+Backup' -or
    $abandonedArchiveBlock -notmatch '(?s)Get-VmRebuildState.*?OriginalPath.*?BackupPath.*?Status' -or
    $abandonedArchiveBlock -notmatch '(?s)Get-AbandonedLegacyVmRebuildEvidence.*?VmFiles.*?VmCriticalEfsCount.*?Lifecycle.*?CoreSignaturesValid' -or
    $abandonedArchiveBlock -notmatch '(?s)Move-Item.+VmRebuildStatePath.+originalArchive' -or
    $abandonedArchiveBlock -match 'Remove-Item.+(BackupPath|PreviousBackupPath)') {
    throw 'Abandoned-state handling may archive only the state record and must never delete or fabricate a legacy backup.'
}
if ($main -notmatch '(?s)function Get-AbandonedLegacyVmRebuildEvidence.*?Test-ClaudeCoreSignatures' -or
    $main -notmatch '(?s)function Get-AbandonedLegacyVmRebuildEvidence.*?CurrentRunHealthy.*?CurrentVirtualDisk1772') {
    throw 'Abandoned-state classification must require valid core signatures and current independent VM health.'
}
if ($main -notmatch '(?s)function Resolve-VmRebuildState.*?Abandoned 归档条件不足.*?abandonedReasons') {
    throw 'Legacy-state failures must include the complete Abandoned evidence reasons.'
}
$autoStart = $main.IndexOf('function Invoke-AutoSetup')
$autoEnd = $main.IndexOf("if (`$env:CLAUDE_SETUP_IMPORT_ONLY", $autoStart)
if ($autoStart -lt 0 -or $autoEnd -le $autoStart) { throw 'Unable to isolate Invoke-AutoSetup.' }
$autoBlock = $main.Substring($autoStart, $autoEnd - $autoStart)
$autoBootstrapIndex = $autoBlock.IndexOf('Get-LegacyStateBootstrapEvidence')
$autoPackageIndex = $autoBlock.IndexOf('Repair-ClaudePackageAndSignature')
$autoWaitIndex = $autoBlock.IndexOf('Wait-AbandonedLegacyVmRebuildEvidence')
$autoResolveIndex = $autoBlock.IndexOf('Resolve-VmRebuildState')
if ($autoBootstrapIndex -lt 0 -or $autoPackageIndex -lt $autoBootstrapIndex -or
    $autoWaitIndex -lt $autoPackageIndex -or $autoResolveIndex -lt $autoWaitIndex) {
    throw 'Auto must bootstrap and verify the official package, wait for full evidence, and only then resolve an orphaned legacy state.'
}
if ($autoBlock -notmatch '(?s)abandonedLifecycleAnchor.*?Wait-AbandonedLegacyVmRebuildEvidence.+MinimumLifecycleTime.*?Resolve-VmRebuildState.+MinimumLifecycleTime' -or
    $autoBlock -notmatch 'evidenceWaitSeconds = if \(\$SkipLaunch\) \{ 0 \} else \{ 180 \}') {
    throw 'Auto must bind Abandoned archival to current-execution lifecycle evidence and allow time for the user to enter Cowork.'
}
if ($main -notmatch '(?s)function Get-SetupPlanExecutionAdvice.*?RecommendedCommand.*?blockedSteps\.Count -eq 0' -or $main -notmatch 'BlockerResolution =') {
    throw 'Plan must suppress the Auto recommendation and provide machine-readable resolution data when blockers exist.'
}

$mainTokens = $null
$mainErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'ClaudeSetup.ps1'),
    [ref]$mainTokens,
    [ref]$mainErrors
)
$planFunction = $mainAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SetupPlan'
}, $true) | Select-Object -First 1
if (-not $planFunction) { throw 'Get-SetupPlan AST is missing.' }
$forbiddenPlanCommands = @(
    'New-Item', 'Set-Item', 'Set-ItemProperty', 'Remove-Item', 'Remove-ItemProperty', 'Move-Item', 'Copy-Item',
    'Add-Content', 'Set-Content', 'Out-File', 'Invoke-WebRequest', 'Enable-WindowsOptionalFeature',
    'Set-AppxDefaultVolume', 'Move-AppxPackage', 'Remove-AppxPackage', 'Add-AppxPackage', 'Add-AppxProvisionedPackage',
    'Start-Service', 'Stop-Service', 'Start-Process', 'Stop-Process', 'Set-Acl'
)
$planCommandNames = @($planFunction.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
$badPlanCommands = @($planCommandNames | Where-Object { $_ -in $forbiddenPlanCommands } | Select-Object -Unique)
if ($badPlanCommands.Count -gt 0) {
    throw "Plan directly invokes mutating commands: $($badPlanCommands -join ', ')"
}
$planEntryIndex = $main.IndexOf("if (`$Action -eq 'Plan')")
$importGuardIndex = $main.LastIndexOf("if (`$env:CLAUDE_SETUP_IMPORT_ONLY -eq '1')")
$entryWriteIndex = $main.IndexOf('New-Item -ItemType Directory -Path $script:ReportsRoot', $importGuardIndex)
if ($planEntryIndex -lt 0 -or $entryWriteIndex -lt 0 -or $planEntryIndex -gt $entryWriteIndex) {
    throw 'Plan must exit before the main entry point creates reports, downloads, logs, or ProgramData directories.'
}
$resolveStart = $main.IndexOf('function Invoke-ResolveLegacyState')
$resolveEnd = $main.IndexOf('function Enable-CoworkPrerequisites', $resolveStart)
if ($resolveStart -lt 0 -or $resolveEnd -le $resolveStart) { throw 'Unable to isolate ResolveLegacyState.' }
$resolveBlock = $main.Substring($resolveStart, $resolveEnd - $resolveStart)
if ($resolveBlock -notmatch 'Resolve-VmRebuildState' -or
    $resolveBlock -match 'Invoke-AutoSetup|Repair-ClaudePackageAndSignature|Enable-CoworkPrerequisites|Start-CoworkServices') {
    throw 'ResolveLegacyState must only classify/archive legacy state and must never enter the install/repair pipeline.'
}
if ($main -notmatch '(?s)function Repair-MsixVmCommitFailure.*?Get-VmRebuildProtectionEvidence.*?if \(\$protection\.Suspected\).*?return \$false.*?Get-OfficialVmManifest') {
    throw 'MSIX VM commit repair must fail closed before any manifest-based external write when AppX protection is suspected.'
}
if ($main -notmatch '(?s)function Repair-MsixVmCommitFailure.*?Test-IsAppxPrivatePath.*?return \$false.*?Get-VmRebuildProtectionEvidence') {
    throw 'MSIX VM commit repair must reject every AppX-private state path before inspecting files or writing manifest data.'
}
if ($main -notmatch '(?s)function Stop-CoworkVmServiceAndWait.*?WaitForStatus.*?cowork-svc') {
    throw 'Cowork service shutdown must wait for Stopped and terminate a lingering cowork-svc process.'
}
if ($main -notmatch '(?s)检测到 MSIX 无法提交.*?Stop-ClaudeProcesses.*?Wait-FileExclusiveAccess.*?Get-FileHash.*?file\.Checksum.*?Sync-CompletedVmCompressedCache') {
    throw 'MSIX compressed-cache repair must stop Claude, obtain exclusive access, and verify the complete hash before promotion.'
}
foreach ($required in @('createZstdDecompress', 'CLAUDE_VM_ZST_SOURCE', 'CLAUDE_VM_RUNTIME_SHA256', "flags: 'wx'")) {
    if (-not $zstdHelper.Contains($required)) { throw "VmZstdDecompress.js is missing: $required" }
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
    'fltmc.exe',
    'ElevateInstall.ps1',
    '-Action Auto',
    '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe',
    'PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules',
    'CLAUDE_SETUP_VALIDATE_POWERSHELL'
)
foreach ($text in $requiredBatchParts) {
    if (-not $batch.Contains($text)) {
        throw "Expected one-click BAT behavior is missing: $text"
    }
}
if ($legacyBatch -notmatch '(?i)call\s+"%~dp0install\.bat"') {
    throw 'setup.cmd must delegate to the canonical install.bat entry point.'
}
if ($diagnoseBatch -notmatch '%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe' -or
    $diagnoseBatch -notmatch 'PSModulePath=%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\Modules') {
    throw 'diagnose.cmd must use the same isolated system Windows PowerShell chain as install.bat.'
}
if ($shareDiagnoseBatch -notmatch '%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe' -or
    $shareDiagnoseBatch -notmatch '-Action Diagnose -Redact' -or
    $shareDiagnoseBatch -notmatch 'claude-diagnostic-share-') {
    throw 'share-diagnose.cmd must use isolated Windows PowerShell and create explicitly redacted reports.'
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
if ($batch -match '(?i)-(BatchPath|WorkingDirectory)') {
    throw 'install.bat must not pass filesystem paths through the UAC helper command line.'
}
if ($batch -match '(?i)\bsetx(?:\.exe)?\b') {
    throw 'install.bat must isolate PSModulePath only for its child process, never persist it with setx.'
}
foreach ($required in @('$PSScriptRoot', '$env:ComSpec', '-Verb RunAs', '-Wait', '-PassThru', '/d /c', 'ValidateOnly')) {
    if (-not $elevator.Contains($required)) { throw "ElevateInstall.ps1 is missing: $required" }
}
if ($elevator -match '\[IO\.Path\]::GetFullPath\(\$(BatchPath|WorkingDirectory)\)') {
    throw 'The elevation helper must not canonicalize path arguments received through cmd.exe.'
}
if ($elevator -match 'Start-Process -FilePath \$BatchPath') {
    throw 'The elevation helper must invoke cmd.exe, not pass a batch file directly to Start-Process.'
}

$elevationTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("Claude Setup 中文 & [path] {0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $elevationTestRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'ElevateInstall.ps1') -Destination $elevationTestRoot
    Copy-Item -LiteralPath (Join-Path $root 'install.bat') -Destination $elevationTestRoot
    Copy-Item -LiteralPath (Join-Path $root 'ClaudeSetup.ps1') -Destination $elevationTestRoot
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $elevationTestRoot 'ElevateInstall.ps1') -ValidateOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Elevation helper path validation failed with exit code $LASTEXITCODE."
    }
    $previousModulePath = $env:PSModulePath
    $previousValidationMode = $env:CLAUDE_SETUP_VALIDATE_POWERSHELL
    try {
        $env:PSModulePath = 'C:\ClaudeSetupPollutedModulePath;D:\environment\scoop\apps\pwsh\current\Modules'
        $env:CLAUDE_SETUP_VALIDATE_POWERSHELL = '1'
        $validationCommand = '""{0}""' -f (Join-Path $root 'install.bat')
        & $env:ComSpec /d /c $validationCommand
        if ($LASTEXITCODE -ne 0) {
            throw "PowerShell 7 -> cmd.exe -> Windows PowerShell security-module isolation failed with exit code $LASTEXITCODE."
        }
        if ($env:PSModulePath -notlike 'C:\ClaudeSetupPollutedModulePath*') {
            throw 'install.bat must not permanently overwrite the parent/user PSModulePath.'
        }
    } finally {
        $env:PSModulePath = $previousModulePath
        $env:CLAUDE_SETUP_VALIDATE_POWERSHELL = $previousValidationMode
    }
} finally {
    Remove-Item -LiteralPath $elevationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$planTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClaudeSetupPlan-{0}" -f [guid]::NewGuid().ToString('N'))
$planImportMode = $env:CLAUDE_SETUP_IMPORT_ONLY
try {
    New-Item -ItemType Directory -Path $planTestRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'ClaudeSetup.ps1') -Destination $planTestRoot
    $planScript = Join-Path $planTestRoot 'ClaudeSetup.ps1'
    $statePath = Join-Path $env:ProgramData 'ClaudeSetup\vm-rebuild-active.json'
    $stateHashBefore = if (Test-Path -LiteralPath $statePath -PathType Leaf) { (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash } else { $null }
    $runOnceBefore = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name ClaudeSetupResume -ErrorAction SilentlyContinue).ClaudeSetupResume
    $environmentBefore = @([Environment]::GetEnvironmentVariable('TEMP', 'User'), [Environment]::GetEnvironmentVariable('TMP', 'User')) -join '|'
    $servicesBefore = @('CoworkVMService', 'vmcompute', 'hns' | ForEach-Object {
        $service = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($service) { "$_=$($service.Status)" } else { "$_=Missing" }
    }) -join '|'
    $rootFilesBefore = @(Get-ChildItem -LiteralPath $planTestRoot -Force | Select-Object -ExpandProperty Name | Sort-Object) -join '|'
    $env:CLAUDE_SETUP_IMPORT_ONLY = $null
    $planOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $planScript -Action Plan
    $planExitCode = $LASTEXITCODE
    $env:CLAUDE_SETUP_IMPORT_ONLY = $planImportMode
    $plan = ($planOutput -join "`n") | ConvertFrom-Json
    $stateHashAfter = if (Test-Path -LiteralPath $statePath -PathType Leaf) { (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash } else { $null }
    $runOnceAfter = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name ClaudeSetupResume -ErrorAction SilentlyContinue).ClaudeSetupResume
    $environmentAfter = @([Environment]::GetEnvironmentVariable('TEMP', 'User'), [Environment]::GetEnvironmentVariable('TMP', 'User')) -join '|'
    $servicesAfter = @('CoworkVMService', 'vmcompute', 'hns' | ForEach-Object {
        $service = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($service) { "$_=$($service.Status)" } else { "$_=Missing" }
    }) -join '|'
    $rootFilesAfter = @(Get-ChildItem -LiteralPath $planTestRoot -Force | Select-Object -ExpandProperty Name | Sort-Object) -join '|'
    if ($planExitCode -ne 0 -or $plan.Action -ne 'Plan' -or -not $plan.ReadOnly -or
        -not $plan.Summary -or @($plan.Steps).Count -lt 8) {
        throw 'Plan must return a successful machine-readable read-only action graph.'
    }
    if ($rootFilesBefore -ne $rootFilesAfter -or $stateHashBefore -ne $stateHashAfter -or
        $runOnceBefore -ne $runOnceAfter -or $environmentBefore -ne $environmentAfter -or
        $servicesBefore -ne $servicesAfter) {
        throw 'Plan changed files, legacy state, RunOnce, user TEMP/TMP, or Cowork-related service state.'
    }
} finally {
    $env:CLAUDE_SETUP_IMPORT_ONLY = $planImportMode
    Remove-Item -LiteralPath $planTestRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    $blockedAdvice = Get-SetupPlanExecutionAdvice -Steps @(
        [pscustomobject]@{ Id = 'legacy-state'; Disposition = 'Blocked'; Reason = 'fixture blocker' }
    )
    if ($blockedAdvice.RecommendedCommand -or @($blockedAdvice.BlockerResolution).Count -ne 1 -or
        $blockedAdvice.BlockerResolution[0].Id -ne 'legacy-state') {
        throw 'A blocked Plan must not recommend Auto and must return machine-readable blocker resolution.'
    }
    $clearAdvice = Get-SetupPlanExecutionAdvice -Steps @(
        [pscustomobject]@{ Id = 'package'; Disposition = 'WouldChange'; Reason = 'fixture change' }
    )
    if ($clearAdvice.RecommendedCommand -ne '.\ClaudeSetup.ps1 -Action Auto' -or @($clearAdvice.BlockerResolution).Count -ne 0) {
        throw 'A Plan without blockers must retain the canonical Auto recommendation.'
    }
    if ((Get-VolumeRoot 'C:\Users\Example\AppData') -ne 'C:') {
        throw 'Volume-root detection failed for C:.'
    }
    $resolvedRoot = Get-FinalPath $root
    if (-not $resolvedRoot -or -not ([IO.Path]::GetFullPath($resolvedRoot)).Equals([IO.Path]::GetFullPath($root), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Final physical-path resolution failed for the repository: $resolvedRoot"
    }
    if ((Convert-FinalPathToDosPath '\\?\C:\Users\Example') -ne 'C:\Users\Example' -or
        (Convert-FinalPathToDosPath '\\?\UNC\server\share\folder') -ne '\\server\share\folder') {
        throw 'Final Win32 path normalization failed.'
    }
    $quotedUserData = Get-ClaudeUserDataPathFromCommandLine '"C:\Program Files\WindowsApps\Claude.exe" --user-data-dir="C:\Users\Example Name\Claude-3p"'
    if ($quotedUserData -ne 'C:\Users\Example Name\Claude-3p') {
        throw "Quoted --user-data-dir parsing failed: $quotedUserData"
    }
    if (Get-ClaudeUserDataPathFromCommandLine 'Claude.exe --user-data-dir=relative\Claude') {
        throw 'Relative --user-data-dir values must not be adopted by an elevated repair process.'
    }
    if (-not (Test-SafeIndependentClaudeUserDataPath (Join-Path $env:LOCALAPPDATA 'Claude-3p')) -or
        (Test-SafeIndependentClaudeUserDataPath (Join-Path $env:LOCALAPPDATA 'Packages\Claude_test\LocalCache\Claude'))) {
        throw 'Independent user-data path safety classification failed.'
    }
    if ((Get-ClaudeUserDataProtectionKind -EncryptedCount 2 -IsAppxPrivate $true -AppxError $false -SafeIndependentPath $false -IsConfigured $false -CurrentUserReadable $true -VirtualDisk1772 $false) -ne 'AppxProtected' -or
        (Get-ClaudeUserDataProtectionKind -EncryptedCount 2 -IsAppxPrivate $false -AppxError $false -SafeIndependentPath $true -IsConfigured $true -CurrentUserReadable $true -VirtualDisk1772 $true) -ne 'ConfirmedUserEfs' -or
        (Get-ClaudeUserDataProtectionKind -EncryptedCount 2 -IsAppxPrivate $false -AppxError $true -SafeIndependentPath $true -IsConfigured $true -CurrentUserReadable $true -VirtualDisk1772 $true) -ne 'ConfirmedUserEfs' -or
        (Get-ClaudeUserDataProtectionKind -EncryptedCount 2 -IsAppxPrivate $false -AppxError $false -SafeIndependentPath $true -IsConfigured $true -CurrentUserReadable $true -VirtualDisk1772 $false) -ne 'EncryptedUnknown' -or
        (Get-ClaudeUserDataProtectionKind -EncryptedCount 2 -IsAppxPrivate $false -AppxError $false -SafeIndependentPath $true -IsConfigured $false -CurrentUserReadable $true -VirtualDisk1772 $true) -ne 'EncryptedUnknown') {
        throw 'AppX-protected versus confirmed user-EFS classification failed.'
    }

    $scopeFixture = Join-Path $env:LOCALAPPDATA 'Claude-3p-scope-fixture'
    if (-not (Test-ClaudeVmCriticalEfsPath -UserDataPath $scopeFixture -CandidatePath $scopeFixture) -or
        -not (Test-ClaudeVmCriticalEfsPath -UserDataPath $scopeFixture -CandidatePath (Join-Path $scopeFixture 'vm_bundles\claudevm.bundle\sessiondata.vhdx')) -or
        (Test-ClaudeVmCriticalEfsPath -UserDataPath $scopeFixture -CandidatePath (Join-Path $scopeFixture 'local-agent-mode-sessions\session.jsonl')) -or
        (Test-ClaudeVmCriticalEfsPath -UserDataPath $scopeFixture -CandidatePath (Join-Path $scopeFixture 'vm_bundles\claudevm.bundle\rootfs.vhdx.zst'))) {
        throw 'VM-critical EFS scope must exclude sessions, caches, archives, and other user files.'
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
        $physicalPackage = Join-Path $statusRoot 'physical-package'
        $registeredPackage = Join-Path $statusRoot 'registered-package'
        New-Item -ItemType Directory -Path $physicalPackage -Force | Out-Null
        New-Item -ItemType Junction -Path $registeredPackage -Target $physicalPackage | Out-Null
        $locationFixture = Get-AppxPackageLocationInfo ([pscustomobject]@{ InstallLocation = $registeredPackage })
        if (-not $locationFixture.ResolutionSucceeded -or -not $locationFixture.IsRedirected -or
            -not $locationFixture.PhysicalPath.Equals($physicalPackage, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AppX final physical-path and reparse redirection detection failed.'
        }
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

        $nodeLog = Join-Path $statusRoot 'cowork_vm_node.log'
        $serviceLog = Join-Path $statusRoot 'cowork-service.log'
        [IO.File]::WriteAllText($nodeLog, "UNKNOWN: unknown error, copyfile 'C:\Users\Test\AppData\Local\Packages\Claude_test\LocalCache\Roaming\Claude\vm_bundles\claudevm.bundle\rootfs.vhdx.tmp'", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($serviceLog, 'Warning: failed to create session disk: CreateVirtualDisk failed: 0x199', (New-Object Text.UTF8Encoding($false)))
        $protectedEvidence = Get-AppxProtectedVmEvidence -BundlePath $statusRoot -NodeLogPaths @($nodeLog) -ServiceLogPath $serviceLog
        if (-not $protectedEvidence.Suspected -or -not $protectedEvidence.ExplicitAppxError -or
            -not $protectedEvidence.SessionDiskError -or -not $protectedEvidence.CopyfileUnknown) {
            throw 'AppX protected-storage evidence detection failed.'
        }

        $current1772Log = Join-Path $statusRoot 'current-1772.log'
        [IO.File]::WriteAllLines($current1772Log, @(
            '2026-08-15T01:00:00Z CreateVirtualDisk failed: 0x1772',
            '2026-08-15T01:00:01Z retry scheduled'
        ))
        $current1772 = Get-ClaudeVmLifecycleEvidence -LogPaths @($current1772Log)
        if (-not $current1772.CurrentVirtualDisk1772 -or -not $current1772.HistoricalVirtualDisk1772 -or $current1772.CurrentRunHealthy) {
            throw 'An unresolved latest 0x1772 must remain current repair evidence.'
        }

        $resolved1772Log = Join-Path $statusRoot 'resolved-1772.log'
        [IO.File]::WriteAllLines($resolved1772Log, @(
            '2026/08/15 01:00:00 CreateVirtualDisk failed: 0x1772',
            '2026/08/15 01:01:00 VM started successfully',
            '2026/08/15 01:01:01 sdk-daemon is ready',
            '2026/08/15 01:01:02 Network status: CONNECTED',
            '2026/08/15 01:01:03 API reachability: REACHABLE'
        ))
        $resolved1772 = Get-ClaudeVmLifecycleEvidence -LogPaths @($resolved1772Log)
        if ($resolved1772.CurrentVirtualDisk1772 -or -not $resolved1772.FailureResolvedByLaterSuccess -or -not $resolved1772.CurrentRunHealthy) {
            throw 'A complete success sequence after 0x1772 must classify the failure as resolved history.'
        }

        $ambiguousFailureLog = Join-Path $statusRoot 'ambiguous-failure.log'
        $ambiguousSuccessLog = Join-Path $statusRoot 'ambiguous-success.log'
        [IO.File]::WriteAllText($ambiguousFailureLog, 'CreateVirtualDisk failed: 0x1772')
        [IO.File]::WriteAllLines($ambiguousSuccessLog, @('VM started successfully', 'sdk-daemon is ready', 'Network status: CONNECTED', 'API reachability: REACHABLE'))
        $ambiguous1772 = Get-ClaudeVmLifecycleEvidence -LogPaths @($ambiguousFailureLog, $ambiguousSuccessLog)
        if (-not $ambiguous1772.CurrentVirtualDisk1772) {
            throw 'Cross-log events without timestamps are ambiguous and must fail closed.'
        }

        [IO.File]::WriteAllText($ambiguousFailureLog, '2026/08/15 01:00:00 CreateVirtualDisk failed: 0x1772')
        [IO.File]::WriteAllLines($ambiguousSuccessLog, @(
            '2026/08/15 01:01:00 VM started successfully',
            '2026/08/15 01:01:01 sdk-daemon is ready',
            '2026/08/15 01:01:02 Network status: CONNECTED',
            '2026/08/15 01:01:03 API reachability: REACHABLE'
        ))
        $timestampedCrossLog = Get-ClaudeVmLifecycleEvidence -LogPaths @($ambiguousFailureLog, $ambiguousSuccessLog)
        if ($timestampedCrossLog.CurrentVirtualDisk1772 -or -not $timestampedCrossLog.FailureResolvedByLaterSuccess) {
            throw 'Timestamped cross-log success evidence must resolve an older 0x1772.'
        }
        $crossLogSegmentation = Get-RecentCoworkErrorEvidence -LogPaths @($ambiguousFailureLog, $ambiguousSuccessLog)
        if ($crossLogSegmentation.CurrentErrors.Count -ne 0 -or $crossLogSegmentation.HistoricalErrors.Count -ne 1 -or
            -not $crossLogSegmentation.GlobalSuccessCutoff) {
            throw 'A timestamped complete success sequence may resolve older errors across service/node log boundaries.'
        }

        $emptyLifecycleLog = Join-Path $statusRoot 'no-lifecycle-events.log'
        [IO.File]::WriteAllText($emptyLifecycleLog, 'ordinary service message without a VM lifecycle event')
        $emptyLifecycle = Get-ClaudeVmLifecycleEvidence -LogPaths @($emptyLifecycleLog)
        if ($emptyLifecycle.CurrentRunHealthy -or $emptyLifecycle.CurrentVirtualDisk1772 -or $emptyLifecycle.LatestVmStartedAt) {
            throw 'A log without lifecycle events must return an empty unhealthy snapshot without throwing under StrictMode.'
        }

        $segmentedLog = Join-Path $statusRoot 'segmented-errors.log'
        [IO.File]::WriteAllLines($segmentedLog, @(
            '2026/08/15 01:00:00 structured error follows',
            "  [message]: 'RPC pipe closed',",
            '2026/08/15 01:01:00 VM started successfully',
            '2026/08/15 01:01:01 sdk-daemon is ready',
            '2026/08/15 01:01:02 Network status: CONNECTED',
            '2026/08/15 01:01:03 API reachability: REACHABLE',
            '2026/08/15 01:02:00 VHDX file not found',
            '2026/08/15 01:02:01 failed to configure recovery actions: Access is denied'
        ))
        $segmented = Get-RecentCoworkErrorEvidence -LogPaths @($segmentedLog)
        if ($segmented.HistoricalErrors.Count -ne 1 -or $segmented.CurrentErrors.Count -ne 1 -or
            $segmented.Information.Count -ne 4 -or $segmented.RecoveryWarnings.Count -ne 1) {
            throw 'Cowork diagnostics must separate unresolved current errors, superseded history, success events, and nonfatal recovery-action warnings.'
        }

        $downloadDestination = Join-Path $statusRoot 'download.bin'
        $downloadCounter = [pscustomobject]@{ Value = 0 }
        $downloadResult = Invoke-HttpFileDownload -Uri 'https://example.invalid/fixture' -Destination $downloadDestination `
            -MaxAttempts 3 -InitialDelaySeconds 0 -SleepProvider { param($ignoredDelay) } -DownloadProvider {
                param($ignoredUri, $partialPath, $attempt)
                $downloadCounter.Value++
                if ($attempt -lt 3) { throw [TimeoutException]::new('fixture timeout') }
                [IO.File]::WriteAllBytes($partialPath, [byte[]](1, 2, 3, 4))
                return [pscustomobject]@{ ContentLength = 4 }
            }
        if ($downloadResult.Attempts -ne 3 -or $downloadCounter.Value -ne 3 -or
            (Get-Item -LiteralPath $downloadDestination).Length -ne 4 -or (Test-Path -LiteralPath "$downloadDestination.partial")) {
            throw 'Official file download must retry with a same-directory partial file and publish only the complete result.'
        }
        $lengthMismatch = $false
        try {
            [void](Invoke-HttpFileDownload -Uri 'https://example.invalid/mismatch' -Destination (Join-Path $statusRoot 'mismatch.bin') `
                -MaxAttempts 1 -InitialDelaySeconds 0 -DownloadProvider {
                    param($ignoredUri, $partialPath, $attempt)
                    [IO.File]::WriteAllBytes($partialPath, [byte[]](1, 2, 3))
                    return [pscustomobject]@{ ContentLength = 4 }
                })
        } catch {
            $lengthMismatch = $_.Exception.Message -match 'DOWNLOAD_LENGTH_MISMATCH'
        }
        if (-not $lengthMismatch -or -not $script:LastDownloadFailure -or
            $script:LastDownloadFailure.Code -ne 'DOWNLOAD_LENGTH_MISMATCH') {
            throw 'Download length mismatch must fail closed with a machine-readable reason.'
        }
        $trustedDestination = Join-Path $statusRoot 'trusted-existing.bin'
        [IO.File]::WriteAllBytes($trustedDestination, [byte[]](9, 9, 9))
        $trustedHash = (Get-FileHash -LiteralPath $trustedDestination -Algorithm SHA256).Hash
        $signatureRejected = $false
        try {
            [void](Invoke-HttpFileDownload -Uri 'https://example.invalid/untrusted' -Destination $trustedDestination `
                -MaxAttempts 1 -InitialDelaySeconds 0 -DownloadProvider {
                    param($ignoredUri, $partialPath, $attempt)
                    [IO.File]::WriteAllBytes($partialPath, [byte[]](1, 2, 3))
                    return [pscustomobject]@{ ContentLength = 3 }
                } -ValidateDownloadedFile {
                    param($candidatePath)
                    throw [IO.InvalidDataException]::new('[DOWNLOAD_SIGNATURE_INVALID] fixture signature rejection')
                })
        } catch {
            $signatureRejected = $_.Exception.Message -match 'DOWNLOAD_SIGNATURE_INVALID'
        }
        if (-not $signatureRejected -or (Get-FileHash -LiteralPath $trustedDestination -Algorithm SHA256).Hash -ne $trustedHash -or
            (Test-Path -LiteralPath "$trustedDestination.partial") -or (Test-Path -LiteralPath "$trustedDestination.previous")) {
            throw 'Signature/identity validation must occur before publication and preserve an existing trusted download on rejection.'
        }

        $privateReport = [pscustomobject]@{
            GeneratedAt = (Get-Date).ToString('o')
            Computer = $env:COMPUTERNAME
            User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            Findings = @([pscustomobject]@{
                Id = 'fixture'
                Status = 'Info'
                Summary = 'fixture'
                Detail = "$env:USERPROFILE $root S-1-5-21-111-222-333-1001 person@example.com"
            })
        }
        $sharedReport = ConvertTo-ShareSafeDiagnosticValue $privateReport
        $sharedJson = $sharedReport | ConvertTo-Json -Depth 6
        $sharedDetail = [string]$sharedReport.Findings.Detail
        if ($sharedJson -match [regex]::Escape($env:USERPROFILE) -or $sharedJson -match [regex]::Escape($root) -or
            $sharedJson -match 'S-1-5-21-111' -or $sharedJson -match 'person@example\.com' -or
            $sharedDetail -notmatch '%USERPROFILE%' -or $sharedDetail -notmatch '<SID>' -or $sharedDetail -notmatch '<EMAIL>') {
            throw 'Share-report redaction must remove user paths, tool paths, SID, email, computer, and account identifiers.'
        }

        $profileSource = Join-Path $statusRoot 'profile-source'
        $profileTarget = Join-Path $statusRoot 'profile-target'
        New-Item -ItemType Directory -Path (Join-Path $profileSource 'vm_bundles'), (Join-Path $profileSource 'Cache'), (Join-Path $profileSource 'Local Storage') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $profileSource 'config.json'), '{"fixture":true}')
        [IO.File]::WriteAllText((Join-Path $profileSource 'Local Storage\session.fixture'), 'session')
        [IO.File]::WriteAllText((Join-Path $profileSource 'vm_bundles\rootfs.vhdx'), 'must-not-copy')
        [IO.File]::WriteAllText((Join-Path $profileSource 'Cache\cache.bin'), 'must-not-copy')
        if (-not (Copy-ClaudeProfileData -Source $profileSource -Destination $profileTarget) -or
            -not (Test-Path -LiteralPath (Join-Path $profileTarget 'config.json')) -or
            -not (Test-Path -LiteralPath (Join-Path $profileTarget 'Local Storage\session.fixture')) -or
            (Test-Path -LiteralPath (Join-Path $profileTarget 'vm_bundles')) -or
            (Test-Path -LiteralPath (Join-Path $profileTarget 'Cache'))) {
            throw 'Independent profile migration must retain configuration while excluding VM and cache data.'
        }

        $legacyVmBundles = Join-Path $statusRoot 'AppData\Local\Packages\Claude_test\LocalCache\Roaming\Claude\vm_bundles'
        $legacyBundle = Join-Path $legacyVmBundles 'claudevm.bundle'
        $legacyBackup = Join-Path $legacyVmBundles 'claudevm.bundle.backup-20260814-095944'
        New-Item -ItemType Directory -Path $legacyBackup -Force | Out-Null
        $independentData = Join-Path $statusRoot 'Claude-3p'
        $independentBundle = Join-Path $independentData 'vm_bundles\claudevm.bundle'
        New-Item -ItemType Directory -Path $independentBundle -Force | Out-Null
        foreach ($name in @('rootfs.vhdx', 'sessiondata.vhdx', 'smol-bin.vhdx', 'initrd', 'vmlinuz')) {
            New-Item -ItemType File -Path (Join-Path $independentBundle $name) -Force | Out-Null
        }
        $legacyState = [pscustomobject]@{
            SchemaVersion = 1
            Status = 'Rebuilding'
            OriginalPath = $legacyBundle
            BackupPath = $legacyBackup
        }
        $independentPaths = [pscustomobject]@{
            ActiveUserData = $independentData
            ActiveUserDataSource = 'Environment:User'
            PackageLocalUserData = Split-Path -Parent (Split-Path -Parent $legacyBundle)
        }
        $healthyLifecycle = [pscustomobject]@{ CurrentRunHealthy = $true; CurrentVirtualDisk1772 = $false }
        if (-not (Test-SupersedableLegacyVmRebuildState -State $legacyState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle)) {
            throw 'A structurally healthy independent VM must safely supersede a valid legacy AppX rebuild state.'
        }
        $unhealthyLifecycle = [pscustomobject]@{ CurrentRunHealthy = $false; CurrentVirtualDisk1772 = $true }
        if (Test-SupersedableLegacyVmRebuildState -State $legacyState -Paths $independentPaths -LifecycleEvidence $unhealthyLifecycle) {
            throw 'A legacy rebuild state must remain active when current independent VM health is not proven.'
        }
        $unsafeLegacyState = [pscustomobject]@{
            SchemaVersion = 1
            Status = 'Rebuilding'
            OriginalPath = (Join-Path $statusRoot 'unrelated\vm_bundles\claudevm.bundle')
            BackupPath = (Join-Path $statusRoot 'unrelated\vm_bundles\claudevm.bundle.backup-1')
        }
        if (Test-SupersedableLegacyVmRebuildState -State $unsafeLegacyState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle) {
            throw 'A rebuild state outside Claude AppX private data must never be auto-superseded.'
        }
        $savedStatePath = $script:VmRebuildStatePath
        $savedHistoryRoot = $script:VmRebuildStateHistoryRoot
        try {
            $script:VmRebuildStatePath = Join-Path $statusRoot 'vm-rebuild-active.json'
            $script:VmRebuildStateHistoryRoot = Join-Path $statusRoot 'state-history'
            $legacyState | ConvertTo-Json | Set-Content -LiteralPath $script:VmRebuildStatePath -Encoding UTF8
            [void](Archive-SupersededVmRebuildState -State $legacyState -SkipResumeCleanup)
            $historyFiles = @(Get-ChildItem -LiteralPath $script:VmRebuildStateHistoryRoot -Filter '*.json' -File)
            if ((Test-Path -LiteralPath $script:VmRebuildStatePath) -or $historyFiles.Count -ne 2 -or
                -not (Test-Path -LiteralPath $legacyBackup) -or
                -not ($historyFiles.Name -match '\.original\.json$') -or
                -not ($historyFiles.Name -match '\.superseded\.json$')) {
                throw 'Superseded-state archival must preserve both the original state and legacy VM backup.'
            }
        } finally {
            $script:VmRebuildStatePath = $savedStatePath
            $script:VmRebuildStateHistoryRoot = $savedHistoryRoot
        }

        $missingBackup = Join-Path $legacyVmBundles 'claudevm.bundle.backup-missing'
        $abandonedState = [pscustomobject]@{
            SchemaVersion = 1
            Status = 'Rebuilding'
            OriginalPath = $legacyBundle
            BackupPath = $missingBackup
        }
        $validSignatures = [pscustomobject]@{ Valid = $true }
        $invalidSignatures = [pscustomobject]@{ Valid = $false }
        $freshnessAnchor = '2026-08-16T01:00:00+00:00'
        $staleLifecycle = [pscustomobject]@{
            CurrentRunHealthy = $true
            CurrentVirtualDisk1772 = $false
            LatestVmStartedAt = '2026-08-16T00:59:00+00:00'
            LatestDaemonReadyAt = '2026-08-16T00:59:01+00:00'
            LatestNetworkConnectedAt = '2026-08-16T00:59:02+00:00'
            LatestApiReachableAt = '2026-08-16T00:59:03+00:00'
        }
        $freshLifecycle = [pscustomobject]@{
            CurrentRunHealthy = $true
            CurrentVirtualDisk1772 = $false
            LatestVmStartedAt = '2026-08-16T01:00:01+00:00'
            LatestDaemonReadyAt = '2026-08-16T01:00:02+00:00'
            LatestNetworkConnectedAt = '2026-08-16T01:00:03+00:00'
            LatestApiReachableAt = '2026-08-16T01:00:04+00:00'
        }
        $staleEvidence = Get-AbandonedLegacyVmRebuildEvidence -State $abandonedState -Paths $independentPaths `
            -LifecycleEvidence $staleLifecycle -CoreSignatures $validSignatures -MinimumLifecycleTime $freshnessAnchor
        $freshEvidence = Get-AbandonedLegacyVmRebuildEvidence -State $abandonedState -Paths $independentPaths `
            -LifecycleEvidence $freshLifecycle -CoreSignatures $validSignatures -MinimumLifecycleTime $freshnessAnchor
        if ($staleEvidence.Eligible -or $staleEvidence.LifecycleFreshAfterAnchor -or
            -not ($staleEvidence.Reasons -match '早于本次启动锚点') -or
            -not $freshEvidence.Eligible -or -not $freshEvidence.LifecycleFreshAfterAnchor) {
            throw 'Abandoned-state archival must require every lifecycle success event to be newer than the current Auto execution anchor.'
        }
        $bootstrapEvidence = Get-LegacyStateBootstrapEvidence -State $abandonedState -ExpectedBundlePath $legacyBundle
        if (-not $bootstrapEvidence.Eligible) {
            throw "An orphaned official-package state with both referenced paths absent must permit package bootstrap: $($bootstrapEvidence.Reasons -join '; ')"
        }
        if ((Get-LegacyStateBootstrapEvidence -State $unsafeLegacyState -ExpectedBundlePath $legacyBundle).Eligible) {
            throw 'Package bootstrap must reject a legacy state outside the exact Claude package-family path.'
        }
        $evidenceCounter = [pscustomobject]@{ Value = 0 }
        $waitingEvidence = [pscustomobject]@{ Eligible = $false; Reasons = @('process and lifecycle evidence not ready') }
        $readyEvidence = [pscustomobject]@{ Eligible = $true; Reasons = @() }
        $waitResult = Wait-AbandonedLegacyVmRebuildEvidence -State $abandonedState -Seconds 1 -PollMilliseconds 10 -EvidenceProvider {
            param($ignoredState)
            $evidenceCounter.Value++
            if ($evidenceCounter.Value -lt 3) { return $waitingEvidence }
            return $readyEvidence
        }
        if (-not $waitResult.Eligible -or $evidenceCounter.Value -lt 3) {
            throw 'Fresh-install evidence waiting must retry without weakening the final predicate.'
        }
        $detailedFailure = $null
        try {
            [void](Resolve-VmRebuildState -State $abandonedState -Paths $independentPaths `
                -LifecycleEvidence $healthyLifecycle -CoreSignatures $invalidSignatures -SkipResumeCleanup)
        } catch {
            $detailedFailure = $_.Exception.Message
        }
        if ($detailedFailure -notmatch 'Abandoned 归档条件不足' -or $detailedFailure -notmatch '签名无效') {
            throw "Resolve-VmRebuildState must report all failed Abandoned evidence: $detailedFailure"
        }
        if (Test-AbandonedLegacyVmRebuildState -State $legacyState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle -CoreSignatures $validSignatures) {
            throw 'A still-present legacy backup must use the Superseded branch, never the Abandoned branch.'
        }
        $abandonedFixtureEvidence = Get-AbandonedLegacyVmRebuildEvidence -State $abandonedState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle -CoreSignatures $validSignatures
        if (-not $abandonedFixtureEvidence.Eligible) {
            Write-Host ($abandonedFixtureEvidence | ConvertTo-Json -Depth 6)
            throw 'A missing legacy AppX bundle and backup must be archivable only when the current independent VM is verified healthy.'
        }
        if (Test-AbandonedLegacyVmRebuildState -State $abandonedState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle -CoreSignatures $invalidSignatures) {
            throw 'An abandoned legacy state must remain fail-closed when current Claude signatures are invalid.'
        }
        if (Test-AbandonedLegacyVmRebuildState -State $abandonedState -Paths $independentPaths -LifecycleEvidence $unhealthyLifecycle -CoreSignatures $validSignatures) {
            throw 'An abandoned legacy state must remain fail-closed when the current VM is unhealthy.'
        }
        New-Item -ItemType Directory -Path $legacyBundle -Force | Out-Null
        if (Test-AbandonedLegacyVmRebuildState -State $abandonedState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle -CoreSignatures $validSignatures) {
            throw 'The abandoned-state branch requires both the legacy active bundle and backup to be absent.'
        }
        Remove-Item -LiteralPath $legacyBundle -Force

        $savedStatePath = $script:VmRebuildStatePath
        $savedHistoryRoot = $script:VmRebuildStateHistoryRoot
        try {
            $script:VmRebuildStatePath = Join-Path $statusRoot 'vm-rebuild-abandoned-active.json'
            $script:VmRebuildStateHistoryRoot = Join-Path $statusRoot 'abandoned-state-history'
            $abandonedState | ConvertTo-Json | Set-Content -LiteralPath $script:VmRebuildStatePath -Encoding UTF8
            $revalidationStopped = $false
            try {
                [void](Archive-AbandonedVmRebuildState -State $abandonedState -Paths $independentPaths `
                    -LifecycleEvidence $healthyLifecycle -CoreSignatures $invalidSignatures -SkipResumeCleanup)
            } catch {
                $revalidationStopped = $true
            }
            if (-not $revalidationStopped -or -not (Test-Path -LiteralPath $script:VmRebuildStatePath) -or
                (Test-Path -LiteralPath $script:VmRebuildStateHistoryRoot)) {
                throw 'Abandoned-state archival must revalidate current signatures immediately before moving the state file.'
            }
            [void](Archive-AbandonedVmRebuildState -State $abandonedState -Paths $independentPaths `
                -LifecycleEvidence $healthyLifecycle -CoreSignatures $validSignatures -SkipResumeCleanup)
            $abandonedHistory = @(Get-ChildItem -LiteralPath $script:VmRebuildStateHistoryRoot -Filter '*.json' -File)
            $abandonedRecord = @($abandonedHistory | Where-Object Name -match '\.abandoned\.json$')
            if ((Test-Path -LiteralPath $script:VmRebuildStatePath) -or $abandonedHistory.Count -ne 2 -or
                $abandonedRecord.Count -ne 1 -or (Test-Path -LiteralPath $missingBackup) -or
                @('rootfs.vhdx', 'sessiondata.vhdx', 'smol-bin.vhdx', 'initrd', 'vmlinuz' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $independentBundle $_)) }).Count -gt 0) {
                throw 'Abandoned-state archival must preserve the current VM and must never fabricate a missing legacy backup.'
            }
            $abandonedReceipt = Get-Content -LiteralPath $abandonedRecord[0].FullName -Raw | ConvertFrom-Json
            if ($abandonedReceipt.Status -ne 'Abandoned' -or $abandonedReceipt.OriginalPathPresent -or
                $abandonedReceipt.BackupPathPresent -or -not $abandonedReceipt.CurrentVmHealthy -or
                $abandonedReceipt.CurrentActiveUserData -ne $independentData -or
                -not $abandonedReceipt.Verification.CoreSignaturesValid -or
                $abandonedReceipt.Verification.VmCriticalEfsCount -ne 0 -or
                $abandonedReceipt.Verification.EvidenceFreshness -ne 'HistoricalSnapshot' -or
                @($abandonedReceipt.Verification.VmFiles).Count -ne 5) {
                throw 'Abandoned-state receipt does not accurately describe the verified missing-backup disposition.'
            }
        } finally {
            $script:VmRebuildStatePath = $savedStatePath
            $script:VmRebuildStateHistoryRoot = $savedHistoryRoot
        }

        $savedStatePath = $script:VmRebuildStatePath
        $savedHistoryRoot = $script:VmRebuildStateHistoryRoot
        try {
            $script:VmRebuildStatePath = Join-Path $statusRoot 'vm-rebuild-resolve-active.json'
            $script:VmRebuildStateHistoryRoot = Join-Path $statusRoot 'resolve-state-history'
            $abandonedState | ConvertTo-Json | Set-Content -LiteralPath $script:VmRebuildStatePath -Encoding UTF8
            $resolvedState = Resolve-VmRebuildState -State $abandonedState -Paths $independentPaths -LifecycleEvidence $healthyLifecycle -CoreSignatures $validSignatures -SkipResumeCleanup
            if ($null -ne $resolvedState -or (Test-Path -LiteralPath $script:VmRebuildStatePath) -or
                @(Get-ChildItem -LiteralPath $script:VmRebuildStateHistoryRoot -Filter '*.abandoned.json' -File).Count -ne 1) {
                throw 'Resolve-VmRebuildState must archive a verified abandoned state and allow Auto to continue.'
            }
        } finally {
            $script:VmRebuildStatePath = $savedStatePath
            $script:VmRebuildStateHistoryRoot = $savedHistoryRoot
        }
    } finally {
        $resolvedStatusRoot = [IO.Path]::GetFullPath($statusRoot)
        if ($resolvedStatusRoot.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedStatusRoot) -like 'ClaudeSetupStatic-*') {
            Remove-Item -LiteralPath $resolvedStatusRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $manifestRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClaudeSetupManifest-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
        $fixtureAsar = Join-Path $manifestRoot 'app.asar'
        $sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $rootHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $rootRuntimeHash = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        $kernelHash = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        $initrdHash = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        $nextSha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
        $fixture = 'binary-prefix Cowork VM bundle manifest. fixture,versions:[{sha:`' + $sha + '`,publishedAt:`2026-08-14`,files:{unix:{x64:[]},win32:{arm64:[],x64:[{name:`rootfs.vhdx`,checksum:`' + $rootHash + '`,rawChecksum:`' + $rootRuntimeHash + '`,progressStart:0,progressEnd:80},{name:`vmlinuz`,checksum:`' + $kernelHash + '`,progressStart:80,progressEnd:90},{name:`initrd`,checksum:`' + $initrdHash + '`,progressStart:90,progressEnd:100}]}}},{sha:`' + $nextSha + '`,files:{}}] binary-suffix'
        [IO.File]::WriteAllText($fixtureAsar, $fixture, (New-Object Text.UTF8Encoding($false)))
        $fixtureManifest = Get-OfficialVmManifest -AsarPath $fixtureAsar
        if ($fixtureManifest.Sha -ne $sha -or $fixtureManifest.Architecture -ne 'x64' -or $fixtureManifest.Files.Count -ne 3) {
            throw 'Official VM manifest fixture parsing failed.'
        }
        if (($fixtureManifest.Files | Where-Object Name -eq 'rootfs.vhdx').RuntimeChecksum -ne $rootRuntimeHash -or
            ($fixtureManifest.Files | Where-Object Name -eq 'vmlinuz').RuntimeChecksum) {
            throw 'Official VM runtime checksum parsing failed.'
        }

        $bundleOne = Join-Path $manifestRoot 'package-localcache\claudevm.bundle'
        $bundleTwo = Join-Path $manifestRoot 'real-roaming\claudevm.bundle'
        New-Item -ItemType Directory -Path $bundleOne, $bundleTwo -Force | Out-Null
        $tempKernel = Join-Path $bundleOne 'vmlinuz.tmp'
        [IO.File]::WriteAllBytes($tempKernel, [Text.Encoding]::UTF8.GetBytes('verified-kernel-fixture'))
        $tempKernelHash = (Get-FileHash -LiteralPath $tempKernel -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not (Sync-VerifiedVmFile -SourcePath $tempKernel -Name 'vmlinuz' -ExpectedHash $tempKernelHash -BundleSha $sha -BundleDirectories @($bundleOne, $bundleTwo))) {
            throw 'Verified VM temp synchronization did not run.'
        }
        foreach ($directory in @($bundleOne, $bundleTwo)) {
            $published = Join-Path $directory 'vmlinuz'
            $origin = Join-Path $directory '.vmlinuz.origin'
            if (-not (Test-Path -LiteralPath $published) -or
                (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tempKernelHash -or
                (Get-Content -LiteralPath $origin -Raw).Trim() -ne $sha) {
                throw "Verified VM file publication failed in $directory."
            }
        }
        if (Test-Path -LiteralPath $tempKernel) { throw 'A verified same-directory temp file must be atomically promoted.' }

        $badTemp = Join-Path $bundleOne 'initrd.tmp'
        [IO.File]::WriteAllBytes($badTemp, [Text.Encoding]::UTF8.GetBytes('unverified-initrd-fixture'))
        if (Sync-VerifiedVmFile -SourcePath $badTemp -Name 'initrd' -ExpectedHash $initrdHash -BundleSha $sha -BundleDirectories @($bundleOne, $bundleTwo)) {
            throw 'A VM temp file with the wrong SHA-256 must never be published.'
        }
        if (-not (Test-Path -LiteralPath $badTemp) -or
            (Test-Path -LiteralPath (Join-Path $bundleOne 'initrd')) -or
            (Test-Path -LiteralPath (Join-Path $bundleOne '.initrd.origin'))) {
            throw 'A rejected VM temp file must remain untouched and unpublished.'
        }

        $compressedPartial = Join-Path $bundleOne ("rootfs.vhdx.zst.{0}.partial" -f $rootHash.Substring(0, 12))
        [IO.File]::WriteAllBytes($compressedPartial, [Text.Encoding]::UTF8.GetBytes('completed-compressed-cache-fixture'))
        $compressedLength = (Get-Item -LiteralPath $compressedPartial).Length
        if (-not (Sync-CompletedVmCompressedCache -SourcePath $compressedPartial -Name 'rootfs.vhdx' -ManifestChecksum $rootHash -BundleSha $sha -BundleDirectories @($bundleOne, $bundleTwo))) {
            throw 'Completed VM compressed cache synchronization did not run.'
        }
        foreach ($directory in @($bundleOne, $bundleTwo)) {
            $cache = Join-Path $directory 'rootfs.vhdx.zst'
            $cacheOrigin = Join-Path $directory '.rootfs.vhdx.zst.origin'
            if (-not (Test-Path -LiteralPath $cache) -or (Get-Item -LiteralPath $cache).Length -ne $compressedLength -or
                (Get-Content -LiteralPath $cacheOrigin -Raw).Trim() -ne $sha) {
                throw "Completed VM compressed cache publication failed in $directory."
            }
        }
        if (Test-Path -LiteralPath $compressedPartial) { throw 'A completed same-directory compressed cache must be atomically promoted.' }

        $wrongPrefix = Join-Path $bundleOne 'initrd.zst.000000000000.partial'
        [IO.File]::WriteAllBytes($wrongPrefix, [Text.Encoding]::UTF8.GetBytes('wrong-prefix-cache-fixture'))
        $wrongPrefixRejected = $false
        try {
            [void](Sync-CompletedVmCompressedCache -SourcePath $wrongPrefix -Name 'initrd' -ManifestChecksum $initrdHash -BundleSha $sha -BundleDirectories @($bundleOne, $bundleTwo))
        } catch {
            $wrongPrefixRejected = $true
        }
        if (-not $wrongPrefixRejected -or -not (Test-Path -LiteralPath $wrongPrefix)) {
            throw 'A compressed cache whose checksum prefix does not match the manifest must remain untouched.'
        }

        $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($nodeCommand) {
            & $nodeCommand.Source --check $zstdHelperPath
            if ($LASTEXITCODE -ne 0) { throw 'VmZstdDecompress.js failed node --check.' }
            $zstdFixture = Join-Path $manifestRoot 'fixture.zst'
            $zstdOutput = Join-Path $manifestRoot 'fixture.out'
            $fixtureBytes = [Text.Encoding]::UTF8.GetBytes('official-zstd-runtime-fixture')
            $fixtureHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fixtureBytes)).Replace('-', '').ToLowerInvariant()
            & $nodeCommand.Source -e "const fs=require('node:fs'),z=require('node:zlib');fs.writeFileSync(process.argv[1],z.zstdCompressSync(Buffer.from(process.argv[2])))" $zstdFixture 'official-zstd-runtime-fixture'
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create the Node Zstd test fixture.' }
            $oldZstdSource = $env:CLAUDE_VM_ZST_SOURCE
            $oldZstdDestination = $env:CLAUDE_VM_ZST_DESTINATION
            $oldZstdHash = $env:CLAUDE_VM_RUNTIME_SHA256
            try {
                $env:CLAUDE_VM_ZST_SOURCE = $zstdFixture
                $env:CLAUDE_VM_ZST_DESTINATION = $zstdOutput
                $env:CLAUDE_VM_RUNTIME_SHA256 = $fixtureHash
                & $nodeCommand.Source $zstdHelperPath
                if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $zstdOutput -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fixtureHash) {
                    throw 'VmZstdDecompress.js did not produce the expected verified output.'
                }
            } finally {
                $env:CLAUDE_VM_ZST_SOURCE = $oldZstdSource
                $env:CLAUDE_VM_ZST_DESTINATION = $oldZstdDestination
                $env:CLAUDE_VM_RUNTIME_SHA256 = $oldZstdHash
            }
        }
    } finally {
        Remove-Item -LiteralPath $manifestRoot -Recurse -Force -ErrorAction SilentlyContinue
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
