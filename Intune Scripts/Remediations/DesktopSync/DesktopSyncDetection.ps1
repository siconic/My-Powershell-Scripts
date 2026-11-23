<#
.SYNOPSIS
    Intune remediation - detection script for desktop shortcuts, desktop
    icons and supporting files.

.DESCRIPTION
    Checks, in the order of the Configuration region:
      1. Default and user desktops: files from the share ($UserDesktopFiles)
         and Office shortcuts ($UserDesktopShortcuts) on C:\Users\Default\Desktop
         and on the desktop of every user profile (the OneDrive desktop when
         Known Folder Move is on).
      2. Public desktop: files from the share ($PublicDesktopFiles), only for
         apps that are installed.
      3. User profile settings: desktop icons ($DesktopIcons) in each user's
         registry and in the Default profile. Registry hives of signed-out
         users are loaded for the check and unloaded afterwards.
      4. System files ($SystemFiles).
    A file is compliant when it exists, has the same SHA256 hash as the source
    and inherits permissions from its folder.

    When the share is not reachable, only the Office shortcuts and desktop
    icons are checked, and the output says so.

    Exit 0 = compliant. Exit 1 = remediation needed; the output lists each
    problem.

    Intune settings:
      Run this script using the logged-on credentials : No (runs as SYSTEM)
      Run script in 64-bit PowerShell                 : Yes
    The script also restarts itself in 64-bit PowerShell if it is started in
    32-bit PowerShell.

    Keep the Configuration and Shared functions regions identical in
    DesktopSyncDetection.ps1 and DesktopSyncRemediation.ps1.

.NOTES
    Version : 2.0
    2.0 - Restructured configuration in four sections: Default and user
          desktops, Public desktop, user profile settings, system files.
          Shortcuts go to the Default profile and every user profile desktop
          again (desktop folder read from the user's registry, so OneDrive
          desktops are found). Office shortcuts created on the device. Public
          desktop shortcuts only for installed apps. Desktop icons (User
          files, Control Panel, Network, Recycle Bin) set per user. Bat
          folder, speedtest.url and jnlp.jsp removed. Profile-copy cleanup
          from 1.0 removed.
    1.0 - First version in the repository.
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

$PublicRoot = $env:PUBLIC
if (-not $PublicRoot) { $PublicRoot = Join-Path $env:SystemDrive 'Users\Public' }
$PublicDesktop = Join-Path $PublicRoot 'Desktop'

$System32   = Join-Path $env:SystemRoot 'System32'
$Wallpapers = Join-Path $env:SystemRoot 'Web\Wallpaper'
$ChromeExe  = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")

# 1. DEFAULT AND USER DESKTOPS
#    Copied to C:\Users\Default\Desktop (new profiles) and to the desktop of
#    every existing user profile (the OneDrive desktop when Known Folder Move
#    is on). Path is relative to the desktop.
$UserDesktopFiles = @(
    @{ Source = 'Desktop\Icons\IPconfig.lnk';         Path = 'IPconfig.lnk' },
    @{ Source = 'Desktop\Icons\<ORG> Intranet.url';   Path = '<ORG> Intranet.url' },
    @{ Source = 'Desktop\Icons\<App1>.lnk';           Path = '<App1>.lnk' },
    @{ Source = 'Desktop\Icons\<App2>.lnk';           Path = '<App2>.lnk' },
    @{ Source = 'Desktop\Icons\<VPN>.lnk';            Path = '<VPN>.lnk' }
)

#    Office shortcuts on the same desktops. Created on the device (no share
#    file needed), only when the program exists in one of $OfficeFolders.
$OfficeFolders = @(
    "$env:ProgramFiles\Microsoft Office\root\Office16",
    "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16"
)
$UserDesktopShortcuts = @(
    @{ Path = 'Access.lnk';     Program = 'MSACCESS.EXE' },
    @{ Path = 'Excel.lnk';      Program = 'EXCEL.EXE' },
    @{ Path = 'Outlook.lnk';    Program = 'OUTLOOK.EXE' },
    @{ Path = 'PowerPoint.lnk'; Program = 'POWERPNT.EXE' },
    @{ Path = 'Word.lnk';       Program = 'WINWORD.EXE' }
)

# 2. PUBLIC DESKTOP (C:\Users\Public\Desktop, shown to every user)
#    Copied from the share only when one of the RequirePath files exists,
#    so no shortcut is placed for an app that is not installed.
$PublicDesktopFiles = @(
    @{ Source = 'Desktop\Public\Google Chrome.lnk';    Path = 'Google Chrome.lnk';    RequirePath = $ChromeExe },
    @{ Source = 'Desktop\Public\VLC media player.lnk'; Path = 'VLC media player.lnk'; RequirePath = @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe") },
    @{ Source = 'Desktop\Public\<App3>.lnk';           Path = '<App3>.lnk';           RequirePath = @("$env:ProgramFiles\<Vendor>\<App3>\<App3>.exe") }
)

# 3. USER PROFILE SETTINGS (each user's registry and the Default profile)
#    Desktop icons. Show = $true shows the icon, $false hides it.
$DesktopIcons = @(
    @{ Name = 'User files';   Clsid = '{59031a47-3f72-44a7-89c5-5595fe6b30ee}'; Show = $true },
    @{ Name = 'Control Panel'; Clsid = '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}'; Show = $true },
    @{ Name = 'Network';      Clsid = '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'; Show = $true },
    @{ Name = 'Recycle Bin';  Clsid = '{645FF040-5081-101B-9F08-00AA002F954E}'; Show = $true }
)

# 4. SYSTEM FILES
#    Destination is the full path. RequirePath is optional.
$SystemFiles = @(
    @{ Source = 'Desktop\Icons\<App1>.ico';      Destination = "$System32\<App1>.ico" },
    @{ Source = 'Desktop\Icons\<App2>.ico';      Destination = "$System32\<App2>.ico" },
    @{ Source = 'Desktop\Icons\<ORG>icons.dll';  Destination = "$System32\<ORG>icons.dll" },
    @{ Source = 'Desktop\Apps\<Config>.ini';     Destination = "$env:SystemRoot\<Config>.ini" },
    @{ Source = 'Desktop\Apps\<Wallpaper>.jpg';  Destination = "$Wallpapers\<Wallpaper>.jpg" },
    @{ Source = 'Desktop\Icons\<App1>.ico';      Destination = "$env:ProgramFiles\Google\Chrome\Application\<App1>.ico"; RequirePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" },
    @{ Source = 'Desktop\Icons\<App2>.ico';      Destination = "$env:ProgramFiles\Google\Chrome\Application\<App2>.ico"; RequirePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" }
)
#endregion Configuration

#region Shared functions
# ---------------------------------------------------------------------------
# Keep this region identical in the detection and remediation scripts.
# ---------------------------------------------------------------------------

$IconKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$ShellFoldersKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$script:MountedHives = @()

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

# Returns the first path in the list that exists as a file, or $null.
function Resolve-ExistingFile {
    param([string[]]$Paths)
    foreach ($Path in @($Paths)) {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $Path
        }
    }
    return $null
}

# Returns one of: OK, NotApplicable, SourceMissing, Missing, Outdated,
# Permissions, or "Error: <message>".
function Get-FileState {
    param(
        [string]$SourcePath,
        [string]$Destination,
        [string[]]$RequirePath
    )
    try {
        if (@($RequirePath | Where-Object { $_ }).Count -gt 0 -and -not (Resolve-ExistingFile $RequirePath)) {
            return 'NotApplicable'
        }
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            return 'SourceMissing'
        }
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            return 'Missing'
        }
        $SourceHash      = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $DestinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($SourceHash -ne $DestinationHash) {
            return 'Outdated'
        }
        if (-not (Test-InheritanceEnabled $Destination)) {
            return 'Permissions'
        }
        return 'OK'
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}

# Full path of an Office program, or $null when it is not installed.
function Get-OfficeProgram {
    param([string]$Program)
    $Candidates = @($OfficeFolders | ForEach-Object { Join-Path $_ $Program })
    return (Resolve-ExistingFile $Candidates)
}

# Returns one of: OK, NotApplicable, Missing, Outdated, or "Error: <message>".
function Get-ShortcutState {
    param(
        [string]$Path,
        [string]$TargetPath
    )
    if (-not $TargetPath) {
        return 'NotApplicable'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'Missing'
    }
    try {
        $Shell = New-Object -ComObject WScript.Shell
        $CurrentTarget = $Shell.CreateShortcut($Path).TargetPath
        if ($CurrentTarget -ne $TargetPath) {
            return 'Outdated'
        }
        return 'OK'
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}

# Returns one of: OK, Missing, Outdated, or "Error: <message>".
function Get-IconState {
    param(
        [string]$RegistryRoot,
        [hashtable]$Icon
    )
    try {
        $Wanted = 1
        if ($Icon.Show) { $Wanted = 0 }
        $Item = Get-ItemProperty -LiteralPath "$RegistryRoot\$IconKeyPath" -Name $Icon.Clsid -ErrorAction SilentlyContinue
        if ($null -eq $Item) {
            return 'Missing'
        }
        if ($Item.($Icon.Clsid) -ne $Wanted) {
            return 'Outdated'
        }
        return 'OK'
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}

# Loads a user registry hive (NTUSER.DAT) under HKEY_USERS\DesktopSync_N.
# Returns the registry path, or $null when the hive cannot be loaded.
function Mount-UserHive {
    param([string]$HiveFile)
    if (-not (Test-Path -LiteralPath $HiveFile -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }
    $MountName = "DesktopSync_$($script:MountedHives.Count + 1)"
    & reg.exe load "HKU\$MountName" "$HiveFile" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $script:MountedHives += "HKU\$MountName"
    return "Registry::HKEY_USERS\$MountName"
}

# Unloads the hives this script loaded (or, with -Stale, hives left loaded by
# an earlier run that stopped early).
function Dismount-UserHives {
    param([switch]$Stale)
    $Hives = $script:MountedHives
    if ($Stale) {
        $Hives = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'DesktopSync_*' } |
            ForEach-Object { "HKU\$($_.PSChildName)" })
    }
    foreach ($Hive in $Hives) {
        for ($Try = 1; $Try -le 5; $Try++) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload $Hive 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $Stale) {
        $script:MountedHives = @()
    }
}

# The user's desktop folder from the user's registry (User Shell Folders),
# so a OneDrive Known Folder Move desktop is found. Falls back to
# <profile>\Desktop.
function Get-DesktopPath {
    param(
        [string]$RegistryRoot,
        [string]$ProfilePath
    )
    $Fallback = Join-Path $ProfilePath 'Desktop'
    if (-not $RegistryRoot) {
        return $Fallback
    }
    $Value = $null
    try {
        $Key = Get-Item -LiteralPath "$RegistryRoot\$ShellFoldersKeyPath" -ErrorAction Stop
        $Value = $Key.GetValue('Desktop', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $Key.Close()
    }
    catch {
        return $Fallback
    }
    if (-not $Value) {
        return $Fallback
    }
    # %USERPROFILE% must be the user's profile, not the SYSTEM profile.
    $Value = $Value -ireplace '%USERPROFILE%', $ProfilePath
    if ($Value -match '%') {
        return $Fallback
    }
    return $Value
}

# One object per user profile plus the Default profile:
#   Name, Desktop (or $null), RegistryRoot (or $null), Notes.
# Call Dismount-UserHives when done.
function Get-UserTargets {
    Dismount-UserHives -Stale

    $Entries = @()
    $Profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath })
    foreach ($UserProfile in $Profiles) {
        $Entries += [pscustomobject]@{
            Name        = (Split-Path $UserProfile.LocalPath -Leaf)
            ProfilePath = $UserProfile.LocalPath
            Sid         = $UserProfile.SID
            Loaded      = [bool]$UserProfile.Loaded
            IsDefault   = $false
        }
    }
    $Entries += [pscustomobject]@{
        Name        = 'Default'
        ProfilePath = (Join-Path $env:SystemDrive 'Users\Default')
        Sid         = $null
        Loaded      = $false
        IsDefault   = $true
    }

    $Targets = @()
    foreach ($Entry in $Entries) {
        if (-not (Test-Path -LiteralPath $Entry.ProfilePath -PathType Container)) {
            continue
        }
        $Notes = @()

        $RegistryRoot = $null
        if ($Entry.Loaded -and $Entry.Sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$($Entry.Sid)")) {
            $RegistryRoot = "Registry::HKEY_USERS\$($Entry.Sid)"
        }
        else {
            $RegistryRoot = Mount-UserHive (Join-Path $Entry.ProfilePath 'NTUSER.DAT')
        }
        if (-not $RegistryRoot) {
            $Notes += 'registry not available, desktop icons skipped'
        }

        if ($Entry.IsDefault) {
            $Desktop = Join-Path $Entry.ProfilePath 'Desktop'
        }
        else {
            $Desktop = Get-DesktopPath $RegistryRoot $Entry.ProfilePath
        }
        if ($Desktop.StartsWith('\\')) {
            $Notes += "desktop redirected to $Desktop, files skipped"
            $Desktop = $null
        }

        $Targets += [pscustomobject]@{
            Name         = $Entry.Name
            Desktop      = $Desktop
            RegistryRoot = $RegistryRoot
            Notes        = $Notes
        }
    }
    return $Targets
}
#endregion Shared functions

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

$ShareReachable = Test-Path -LiteralPath $ShareRoot
$Issues = @()
$Notes = @()
$SourceMissing = @()

function Add-Result {
    param(
        [string]$State,
        [string]$Label,
        [string]$Source
    )
    if ($State -eq 'OK' -or $State -eq 'NotApplicable') {
        return
    }
    if ($State -eq 'SourceMissing') {
        $script:SourceMissing += $Source
        return
    }
    $script:Issues += "$($State): $Label"
}

try {
    # 1. Default and user desktops, 3. user profile settings
    foreach ($Target in @(Get-UserTargets)) {

        foreach ($Note in @($Target.Notes)) {
            $Notes += "$($Target.Name): $Note"
        }

        if ($Target.Desktop) {
            if ($ShareReachable) {
                foreach ($Item in $UserDesktopFiles) {
                    $State = Get-FileState (Join-Path $ShareRoot $Item.Source) (Join-Path $Target.Desktop $Item.Path) $null
                    Add-Result $State "$($Target.Name) desktop\$($Item.Path)" $Item.Source
                }
            }
            foreach ($Item in $UserDesktopShortcuts) {
                $State = Get-ShortcutState (Join-Path $Target.Desktop $Item.Path) (Get-OfficeProgram $Item.Program)
                Add-Result $State "$($Target.Name) desktop\$($Item.Path)" ''
            }
        }

        if ($Target.RegistryRoot) {
            foreach ($Icon in $DesktopIcons) {
                $State = Get-IconState $Target.RegistryRoot $Icon
                Add-Result $State "$($Target.Name) icon $($Icon.Name)" ''
            }
        }
    }

    if ($ShareReachable) {
        # 2. Public desktop
        foreach ($Item in $PublicDesktopFiles) {
            $State = Get-FileState (Join-Path $ShareRoot $Item.Source) (Join-Path $PublicDesktop $Item.Path) $Item.RequirePath
            Add-Result $State "Public desktop\$($Item.Path)" $Item.Source
        }

        # 4. System files
        foreach ($Item in $SystemFiles) {
            $State = Get-FileState (Join-Path $ShareRoot $Item.Source) $Item.Destination $Item.RequirePath
            Add-Result $State $Item.Destination $Item.Source
        }
    }
}
finally {
    Dismount-UserHives
}

$Extra = @()
if (-not $ShareReachable) {
    $Extra += "file server share not reachable ($ShareRoot), file checks skipped"
}
$SourceMissing = @($SourceMissing | Sort-Object -Unique)
if ($SourceMissing.Count -gt 0) {
    $Extra += "source missing on share (skipped): $($SourceMissing -join ', ')"
}
$Extra += $Notes
$Tail = ''
if ($Extra.Count -gt 0) {
    $Tail = " Notes: $($Extra -join '; ')"
}

if ($Issues.Count -gt 0) {
    $Text = "Non-compliant, $($Issues.Count) issue(s): $($Issues -join ' | ').$Tail"
    # Intune keeps about 2048 characters of output.
    if ($Text.Length -gt 2000) {
        $Text = $Text.Substring(0, 1990) + ' [cut]'
    }
    Write-Output $Text
    exit 1
}

$Text = "Compliant.$Tail"
if ($Text.Length -gt 2000) {
    $Text = $Text.Substring(0, 1990) + ' [cut]'
}
Write-Output $Text
exit 0
