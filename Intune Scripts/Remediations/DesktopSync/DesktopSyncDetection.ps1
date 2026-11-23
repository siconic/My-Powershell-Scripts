<#
.SYNOPSIS
    Intune remediation - detection script for desktop shortcut and file sync.

.DESCRIPTION
    Checks every file in $ManagedFiles:
      - the file exists at its destination,
      - it has the same SHA256 hash as the source file on the file server,
      - it inherits permissions from its folder.
    With $RemoveProfileCopies = $true it also reports copies of the Public
    desktop files that are still in user profile desktops (including OneDrive
    desktops), because users would see those icons twice.

    Exit 0 = compliant, or the file server share is not reachable (the output
    says which). Exit 1 = remediation needed; the output lists each problem.

    Intune settings:
      Run this script using the logged-on credentials : No (runs as SYSTEM)
      Run script in 64-bit PowerShell                 : Yes
    The script also restarts itself in 64-bit PowerShell if it is started in
    32-bit PowerShell, so System32 is never redirected to SysWOW64.

    Keep the Configuration region identical in DesktopSyncDetection.ps1 and
    DesktopSyncRemediation.ps1.

.NOTES
    Version : 1.0
    1.0 - First version in the repository. Shortcuts go to the Public desktop
          instead of every profile desktop. One file list (Source/Destination)
          shared by detection and remediation. SHA256 hash comparison instead
          of size and date. Files under the Chrome folder are only managed when
          chrome.exe exists. Unreachable share is reported in the output.
          Restarts in 64-bit PowerShell when needed.
#>

# Restart in 64-bit PowerShell when started in 32-bit PowerShell on a 64-bit OS.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $PowerShell64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $PowerShell64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

#region Configuration
# ---------------------------------------------------------------------------
# Keep this region identical in the detection and remediation scripts.
# ---------------------------------------------------------------------------

# Source folder on the file server. The computer account (SYSTEM) needs Read
# access on the share and on the NTFS folders.
$ShareRoot = '\\<FileServer>\<Share>$\Scripts'

# Shortcuts go to the Public desktop. Every user on the device sees them.
$PublicRoot = $env:PUBLIC
if (-not $PublicRoot) { $PublicRoot = Join-Path $env:SystemDrive 'Users\Public' }
$PublicDesktop = Join-Path $PublicRoot 'Desktop'

# $true: delete per-profile copies of the Public desktop files (for example
# copies made by an earlier per-profile sync), so users do not see each icon
# twice. Only files with the managed names and relative paths are deleted.
$RemoveProfileCopies = $true

$System32   = Join-Path $env:SystemRoot 'System32'
$Wallpapers = Join-Path $env:SystemRoot 'Web\Wallpaper'
$ChromeApp  = Join-Path $env:ProgramFiles 'Google\Chrome\Application'
$ChromeExe  = Join-Path $ChromeApp 'chrome.exe'

# Source      : path relative to $ShareRoot.
# Destination : full path of the file on the device.
# RequirePath : optional. The entry is only managed when this path exists.
$ManagedFiles = @(
    # Desktop shortcuts (Public desktop)
    @{ Source = 'Desktop\Icons\IPconfig.lnk';         Destination = "$PublicDesktop\IPconfig.lnk" },
    @{ Source = 'Desktop\Icons\<ORG> Intranet.url';   Destination = "$PublicDesktop\<ORG> Intranet.url" },
    @{ Source = 'Desktop\Icons\<App1>.lnk';           Destination = "$PublicDesktop\<App1>.lnk" },
    @{ Source = 'Desktop\Icons\<App2>.lnk';           Destination = "$PublicDesktop\<App2>.lnk" },
    @{ Source = 'Desktop\Icons\<VPN>.lnk';            Destination = "$PublicDesktop\<VPN>.lnk" },
    @{ Source = 'Desktop\Icons\speedtest.url';        Destination = "$PublicDesktop\speedtest.url" },

    # Bat folder on the Public desktop
    @{ Source = 'Desktop\Bat\<Tool1>.bat';            Destination = "$PublicDesktop\Bat\<Tool1>.bat" },
    @{ Source = 'Desktop\Bat\<Tool2>.bat';            Destination = "$PublicDesktop\Bat\<Tool2>.bat" },

    # Icon files used by the shortcuts
    @{ Source = 'Desktop\Icons\<App1>.ico';           Destination = "$System32\<App1>.ico" },
    @{ Source = 'Desktop\Icons\<App2>.ico';           Destination = "$System32\<App2>.ico" },
    @{ Source = 'Desktop\Icons\<ORG>icons.dll';       Destination = "$System32\<ORG>icons.dll" },

    # Other system files
    @{ Source = 'Desktop\Apps\<Config>.ini';          Destination = "$env:SystemRoot\<Config>.ini" },
    @{ Source = 'Desktop\Apps\<Wallpaper>.jpg';       Destination = "$Wallpapers\<Wallpaper>.jpg" },

    # Chrome folder: only when Chrome is installed
    @{ Source = 'Desktop\Icons\<App1>.ico';           Destination = "$ChromeApp\<App1>.ico"; RequirePath = $ChromeExe },
    @{ Source = 'Desktop\Icons\<App2>.ico';           Destination = "$ChromeApp\<App2>.ico"; RequirePath = $ChromeExe }
)
#endregion Configuration

#region Shared functions
# ---------------------------------------------------------------------------
# Keep this region identical in the detection and remediation scripts.
# ---------------------------------------------------------------------------

function Test-InheritanceEnabled {
    param([string]$Path)
    try {
        $Acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        return (-not $Acl.AreAccessRulesProtected)
    }
    catch {
        return $false
    }
}

# Returns one of: OK, NotApplicable, SourceMissing, Missing, Outdated,
# Permissions, or "Error: <message>".
function Get-FileState {
    param([hashtable]$Item)
    try {
        if ($Item.RequirePath -and -not (Test-Path -LiteralPath $Item.RequirePath)) {
            return 'NotApplicable'
        }
        $SourcePath = Join-Path $ShareRoot $Item.Source
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            return 'SourceMissing'
        }
        if (-not (Test-Path -LiteralPath $Item.Destination -PathType Leaf)) {
            return 'Missing'
        }
        $SourceHash      = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $DestinationHash = (Get-FileHash -LiteralPath $Item.Destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($SourceHash -ne $DestinationHash) {
            return 'Outdated'
        }
        if (-not (Test-InheritanceEnabled $Item.Destination)) {
            return 'Permissions'
        }
        return 'OK'
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}

# Relative paths (below the Public desktop) of the managed Public desktop files.
function Get-PublicDesktopRelativePaths {
    $Prefix = $PublicDesktop.TrimEnd('\') + '\'
    $Result = @()
    foreach ($Item in $ManagedFiles) {
        if ($Item.Destination.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $Result += $Item.Destination.Substring($Prefix.Length)
        }
    }
    return $Result
}

# Desktop folders of all user profiles, the Default profile, and OneDrive
# desktops (OneDrive Known Folder Move) inside each profile.
function Get-ProfileDesktops {
    $ProfilePaths = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath } |
        ForEach-Object { $_.LocalPath })
    $ProfilePaths += Join-Path $env:SystemDrive 'Users\Default'

    $Desktops = @()
    foreach ($ProfilePath in $ProfilePaths) {
        if (-not (Test-Path -LiteralPath $ProfilePath)) { continue }
        $Desktops += Join-Path $ProfilePath 'Desktop'
        $OneDriveFolders = @(Get-ChildItem -LiteralPath $ProfilePath -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)
        foreach ($Folder in $OneDriveFolders) {
            $Desktops += Join-Path $Folder.FullName 'Desktop'
        }
    }

    $PublicFull = $PublicDesktop.TrimEnd('\')
    return @($Desktops |
        Where-Object { ($_.TrimEnd('\') -ne $PublicFull) -and (Test-Path -LiteralPath $_ -PathType Container) } |
        Sort-Object -Unique)
}

# Per-profile copies of the managed Public desktop files.
function Get-ProfileCopies {
    $RelativePaths = @(Get-PublicDesktopRelativePaths)
    $Copies = @()
    foreach ($Desktop in @(Get-ProfileDesktops)) {
        foreach ($Relative in $RelativePaths) {
            $Path = Join-Path $Desktop $Relative
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $Copies += $Path
            }
        }
    }
    return $Copies
}
#endregion Shared functions

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ShareRoot)) {
    Write-Output "Not checked: file server share is not reachable ($ShareRoot)."
    exit 0
}

$Issues = @()
$SourceMissing = @()

foreach ($Item in $ManagedFiles) {
    $State = Get-FileState $Item
    if ($State -eq 'OK' -or $State -eq 'NotApplicable') {
        continue
    }
    if ($State -eq 'SourceMissing') {
        $SourceMissing += $Item.Source
        continue
    }
    $Issues += "$($State): $($Item.Destination)"
}

if ($RemoveProfileCopies) {
    foreach ($Path in @(Get-ProfileCopies)) {
        $Issues += "Profile copy: $Path"
    }
}

$SourceNote = ''
$SourceMissing = @($SourceMissing | Sort-Object -Unique)
if ($SourceMissing.Count -gt 0) {
    $SourceNote = " Source missing on share (skipped): $($SourceMissing -join '; ')"
}

if ($Issues.Count -gt 0) {
    $Text = "Non-compliant, $($Issues.Count) issue(s): $($Issues -join ' | ').$SourceNote"
    # Intune keeps about 2048 characters of output.
    if ($Text.Length -gt 2000) {
        $Text = $Text.Substring(0, 1990) + ' [cut]'
    }
    Write-Output $Text
    exit 1
}

Write-Output "Compliant.$SourceNote"
exit 0
