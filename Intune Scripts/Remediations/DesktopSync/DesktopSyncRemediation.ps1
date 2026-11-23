<#
.SYNOPSIS
    Intune remediation - remediation script for desktop shortcut and file sync.

.DESCRIPTION
    For every file in $ManagedFiles that is missing, has a different SHA256
    hash than the source on the file server, or does not inherit permissions:
    copies the file from the share and turns permission inheritance back on.
    A destination file that is in use (for example an icon DLL that Explorer
    has loaded) is renamed to <name>.old first, and the new file is copied in
    its place; the .old file is deleted on a later run.

    With $RemoveProfileCopies = $true it deletes copies of the Public desktop
    files from user profile desktops (including OneDrive desktops), and
    deletes managed subfolders there (for example Bat) when they are empty.

    Log: C:\ProgramData\Logs\DesktopSync\DesktopSyncRemediation.log
    Exit 0 = all done, or the file server share is not reachable.
    Exit 1 = at least one file could not be fixed (see the log).

    Intune settings:
      Run this script using the logged-on credentials : No (runs as SYSTEM)
      Run script in 64-bit PowerShell                 : Yes
    The script also restarts itself in 64-bit PowerShell if it is started in
    32-bit PowerShell, so System32 is never redirected to SysWOW64.

    Keep the Configuration and Shared functions regions identical in
    DesktopSyncDetection.ps1 and DesktopSyncRemediation.ps1.

.NOTES
    Version : 1.0
    1.0 - First version in the repository. Shortcuts go to the Public desktop
          instead of every profile desktop; per-profile copies are removed.
          One file list (Source/Destination) shared by detection and
          remediation. SHA256 hash comparison instead of size and date. Files
          under the Chrome folder are only managed when chrome.exe exists, and
          no destination folder is created for them. In-use files are renamed
          before copying. Inheritance is only reset when it is turned off.
          Unreachable share is logged. Restarts in 64-bit PowerShell when
          needed.
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
# Logging
# ---------------------------------------------------------------------------

$LogFolder = Join-Path $env:ProgramData 'Logs\DesktopSync'
$LogFile = Join-Path $LogFolder 'DesktopSyncRemediation.log'

if (-not (Test-Path -LiteralPath $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

# Keep one previous log when the log grows over 1 MB.
if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        Add-Content -LiteralPath $LogFile -Value "$Timestamp [$Level] $Message" -ErrorAction Stop
    }
    catch {
        # Logging must never stop the remediation.
    }
}

# ---------------------------------------------------------------------------
# Remediation functions
# ---------------------------------------------------------------------------

# Reads and writes only the access rules (DACL). Set-Acl with an object from
# Get-Acl also tries to write the audit rules (SACL), which needs
# SeSecurityPrivilege.
function Enable-Inheritance {
    param([string]$Path)
    $File = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $Acl = $File.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $Acl.SetAccessRuleProtection($false, $true)
    $File.SetAccessControl($Acl)
}

# Copies the source over the destination. When the destination is in use,
# renames it to <name>.old and copies again.
function Copy-ManagedFile {
    param(
        [string]$SourcePath,
        [string]$Destination
    )
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $Destination -Force -ErrorAction Stop
    }
    catch {
        if (-not (Test-Path -LiteralPath $Destination)) {
            throw
        }
        $OldPath = "$Destination.old"
        if (Test-Path -LiteralPath $OldPath) {
            Remove-Item -LiteralPath $OldPath -Force -ErrorAction Stop
        }
        Rename-Item -LiteralPath $Destination -NewName (Split-Path $OldPath -Leaf) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $SourcePath -Destination $Destination -Force -ErrorAction Stop
        Write-Log "In use, renamed old file to $OldPath before copying: $Destination" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Remediation
# ---------------------------------------------------------------------------

Write-Log 'Remediation started.'

if (-not (Test-Path -LiteralPath $ShareRoot)) {
    Write-Log "File server share is not reachable ($ShareRoot). Nothing done." 'WARN'
    Write-Output "Not run: file server share is not reachable ($ShareRoot)."
    exit 0
}

$FailureCount = 0
$ChangeCount = 0

foreach ($Item in $ManagedFiles) {

    $Destination = $Item.Destination

    # Delete a leftover .old file from an earlier in-use copy.
    $OldPath = "$Destination.old"
    if (Test-Path -LiteralPath $OldPath) {
        try {
            Remove-Item -LiteralPath $OldPath -Force -ErrorAction Stop
            Write-Log "Deleted old file: $OldPath"
        }
        catch {
            Write-Log "Old file still in use, will retry next run: $OldPath" 'WARN'
        }
    }

    $State = Get-FileState $Item

    if ($State -eq 'OK' -or $State -eq 'NotApplicable') {
        continue
    }

    if ($State -eq 'SourceMissing') {
        Write-Log "Source missing on share, skipped: $(Join-Path $ShareRoot $Item.Source)" 'WARN'
        continue
    }

    if ($State -like 'Error*') {
        Write-Log "Check failed for $($Destination). $State" 'ERROR'
        $FailureCount++
        continue
    }

    try {
        if ($State -eq 'Missing' -or $State -eq 'Outdated') {
            $Folder = Split-Path $Destination -Parent
            if (-not (Test-Path -LiteralPath $Folder)) {
                New-Item -Path $Folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Log "Created folder: $Folder"
            }
            Copy-ManagedFile -SourcePath (Join-Path $ShareRoot $Item.Source) -Destination $Destination
        }

        if (-not (Test-InheritanceEnabled $Destination)) {
            Enable-Inheritance $Destination
            Write-Log "Permission inheritance turned on: $Destination"
        }

        $NewState = Get-FileState $Item
        if ($NewState -eq 'OK') {
            Write-Log "Fixed ($State): $Destination"
            $ChangeCount++
        }
        else {
            Write-Log "Still not compliant after fix ($NewState): $Destination" 'ERROR'
            $FailureCount++
        }
    }
    catch {
        Write-Log "Fix failed ($State) for $($Destination): $($_.Exception.Message)" 'ERROR'
        $FailureCount++
    }
}

if ($RemoveProfileCopies) {

    foreach ($Path in @(Get-ProfileCopies)) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-Log "Deleted profile copy: $Path"
            $ChangeCount++
        }
        catch {
            Write-Log "Could not delete profile copy $($Path): $($_.Exception.Message)" 'ERROR'
            $FailureCount++
        }
    }

    # Delete managed subfolders (for example Bat) from profile desktops when
    # they are now empty.
    $SubFolders = @(Get-PublicDesktopRelativePaths |
        ForEach-Object { Split-Path $_ -Parent } |
        Where-Object { $_ } |
        Sort-Object -Unique)

    foreach ($Desktop in @(Get-ProfileDesktops)) {
        foreach ($SubFolder in $SubFolders) {
            $Path = Join-Path $Desktop $SubFolder
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) { continue }
            if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0) { continue }
            try {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                Write-Log "Deleted empty folder: $Path"
            }
            catch {
                Write-Log "Could not delete empty folder $($Path): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

if ($FailureCount -gt 0) {
    Write-Log "Remediation finished: $ChangeCount change(s), $FailureCount failure(s)." 'ERROR'
    Write-Output "Finished with $FailureCount failure(s), $ChangeCount change(s). See $LogFile"
    exit 1
}

Write-Log "Remediation finished: $ChangeCount change(s), no failures."
Write-Output "Finished: $ChangeCount change(s), no failures."
exit 0
