<#
.SYNOPSIS
    Builds the deployable detection and remediation scripts with the real
    configuration.

.DESCRIPTION
    The committed scripts contain placeholders (<FileServer>, <ORG>, ...).
    This script takes the Configuration region from Local\Configuration.txt
    (git-ignored, contains the real server and file names) and writes
    Local\DesktopSyncDetection.ps1 and Local\DesktopSyncRemediation.ps1.
    Upload those two files to Intune.

    Run it again after changing either the committed scripts or
    Local\Configuration.txt.

.NOTES
    Version : 1.0
    1.0 - First version.
#>

$LocalFolder = Join-Path $PSScriptRoot 'Local'
$ConfigFile = Join-Path $LocalFolder 'Configuration.txt'

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "Missing $ConfigFile. Copy the Configuration region from DesktopSyncDetection.ps1 into it and fill in the real values."
}

$Pattern = '(?s)#region Configuration.*?#endregion Configuration'
$Config = [regex]::Match((Get-Content -LiteralPath $ConfigFile -Raw), $Pattern).Value
if (-not $Config) {
    throw "$ConfigFile has no '#region Configuration' ... '#endregion Configuration' block."
}

foreach ($Name in @('DesktopSyncDetection.ps1', 'DesktopSyncRemediation.ps1')) {
    $Text = Get-Content -LiteralPath (Join-Path $PSScriptRoot $Name) -Raw
    if (-not [regex]::IsMatch($Text, $Pattern)) {
        throw "$Name has no Configuration region."
    }
    # MatchEvaluator so that $ characters in the configuration are kept as text.
    $Result = [regex]::Replace($Text, $Pattern, { param($Match) $Config })
    $OutFile = Join-Path $LocalFolder $Name
    # UTF-8 with BOM, so Windows PowerShell 5.1 reads non-ASCII names correctly.
    Set-Content -LiteralPath $OutFile -Value $Result -Encoding UTF8 -NoNewline
    Write-Output "Written: $OutFile"
}
