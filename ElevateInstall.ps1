[CmdletBinding()]
param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'

try {
    # Derive both paths locally. Passing a quoted directory ending in a backslash
    # through cmd.exe -> powershell.exe can preserve the closing quote as part of
    # the value on some systems, making GetFullPath report illegal characters.
    $workingItem = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
    $batchItem = Get-Item -LiteralPath (Join-Path $workingItem.FullName 'install.bat') -ErrorAction Stop
    if (-not $workingItem.PSIsContainer) { throw "Working directory not found: $PSScriptRoot" }
    if ($batchItem.PSIsContainer) { throw "install.bat is not a file: $($batchItem.FullName)" }

    $working = $workingItem.FullName
    $batch = $batchItem.FullName
    if ($ValidateOnly) { exit 0 }

    $cmdArguments = '/d /c ""{0}""' -f $batch
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArguments -WorkingDirectory $working -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
} catch {
    Write-Host "[ERROR] Unable to start the elevated installer: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
