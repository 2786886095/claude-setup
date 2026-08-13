$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scripts = Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse
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

$main = Get-Content -LiteralPath (Join-Path $root 'ClaudeSetup.ps1') -Raw
$batch = Get-Content -LiteralPath (Join-Path $root 'install.bat') -Raw
$requiredSafetyChecks = @(
    'Get-AuthenticodeSignature',
    'Anthropic',
    'VirtualMachinePlatform',
    'CoworkVMService',
    'HashMismatch',
    'Get-AppxVolume',
    'Move-AppxPackage',
    'RPC pipe closed',
    'sessiondata.vhdx',
    'SupportCompressedVolumes'
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
if ($main -notmatch 'Remove-ResumeAfterRestart') {
    throw 'The one-shot installer must clear its temporary RunOnce resume entry.'
}

$requiredBatchParts = @(
    '%~dp0ClaudeSetup.ps1',
    '%~f0',
    'fltmc.exe',
    '-Verb RunAs',
    '-Action Auto'
)
foreach ($text in $requiredBatchParts) {
    if (-not $batch.Contains($text)) {
        throw "Expected one-click BAT behavior is missing: $text"
    }
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
    $argumentItems = @(Get-CurrentArgumentList)
    $fileIndex = [Array]::IndexOf($argumentItems, '-File')
    if ($fileIndex -lt 0 -or $fileIndex + 1 -ge $argumentItems.Count -or
        $argumentItems[$fileIndex + 1] -notmatch '^".+ClaudeSetup\.ps1"$') {
        throw "Resume/elevation command does not quote the script path: $($argumentItems -join ' ')"
    }
} finally {
    $env:CLAUDE_SETUP_IMPORT_ONLY = $previousImportMode
}

Write-Host "Validated $($scripts.Count) PowerShell script(s)."
