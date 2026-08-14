[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BatchPath,
    [Parameter(Mandatory)][string]$WorkingDirectory
)

$ErrorActionPreference = 'Stop'

try {
    $batch = [IO.Path]::GetFullPath($BatchPath)
    $working = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $batch -PathType Leaf)) { throw "install.bat not found: $batch" }
    if (-not (Test-Path -LiteralPath $working -PathType Container)) { throw "Working directory not found: $working" }
    if (-not ([IO.Path]::GetDirectoryName($batch)).Equals($working.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'install.bat and its working directory do not match.'
    }

    $cmdArguments = '/d /c ""{0}""' -f $batch
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArguments -WorkingDirectory $working -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
} catch {
    Write-Host "[ERROR] Unable to start the elevated installer: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
