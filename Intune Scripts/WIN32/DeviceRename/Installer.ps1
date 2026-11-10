# Win32 app install script: copies the rename files and registers the RenameHost scheduled task.
# Settings come from Settings.psd1 in the package folder (the folder this script runs from).
# Can be run again (reinstall): existing files and the existing task are replaced.
# Exit 0 = success, Exit 1 = failure

# Intune starts install commands as a 32-bit process on 64-bit Windows. Restart in 64-bit PowerShell
# so the registry values go to HKLM\SOFTWARE (not WOW6432Node), where the other scripts read them.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    & "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$TaskName = "RenameHost"
$RegistryPath = "HKLM:\SOFTWARE\Packages\HostRename"
$Files = @("Settings.psd1", "RenameHost.xml", "RenameComputer.ps1", "ServiceUI.exe")

try
{
    $Settings = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "Settings.psd1") -ErrorAction Stop
}
catch
{
    Write-Output "ERROR: Cannot read Settings.psd1 in '$PSScriptRoot': $($_.Exception.Message)"
    exit 1
}

$OrgName = $Settings.OrgName
if ($OrgName -notmatch '^[A-Za-z0-9_-]+$')
{
    Write-Output "ERROR: OrgName '$OrgName' in Settings.psd1 may contain only letters, digits, - and _."
    exit 1
}

if ($Settings.HostnamePrefix -and $Settings.HostnamePrefix -notmatch '^[A-Za-z0-9-]{1,5}$')
{
    Write-Output "ERROR: HostnamePrefix '$($Settings.HostnamePrefix)' in Settings.psd1 must be 1 to 5 letters, digits or -."
    exit 1
}

$BaseFolder = "C:\ProgramData\$OrgName"
$InstallFolder = "$BaseFolder\RenameHost"
$LogFolder = "$BaseFolder\Log"
$LogPath = "$LogFolder\RenameInstall.log"

foreach ($Folder in @($BaseFolder, $InstallFolder, $LogFolder))
{
    if (!(Test-Path -Path $Folder))
    {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        Write-Output "Folder '$Folder' created."
    }
}

Start-Transcript -Path $LogPath -Append | Out-Null

try
{
    foreach ($File in $Files)
    {
        Copy-Item -Path (Join-Path $PSScriptRoot $File) -Destination $InstallFolder -Force -ErrorAction Stop
        Write-Output "Copied '$File' to '$InstallFolder'."
    }

    # RenameHost.xml has the token __ORGNAME__ in its paths; it is replaced with OrgName here
    $TaskXml = (Get-Content (Join-Path $InstallFolder "RenameHost.xml") -Raw -ErrorAction Stop).Replace("__ORGNAME__", $OrgName)
    Register-ScheduledTask -Xml $TaskXml -TaskName $TaskName -TaskPath "\" -User "SYSTEM" -Force -ErrorAction Stop | Out-Null
    Write-Output "Scheduled task '$TaskName' registered."

    # Record the install folder. detection.ps1 and Uninstall.ps1 read it from here,
    # because Intune runs detection.ps1 outside the package folder.
    if (!(Test-Path $RegistryPath))
    {
        New-Item -Path $RegistryPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $RegistryPath -Name "InstallFolder" -Value $InstallFolder -PropertyType String -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "OrgName" -Value $OrgName -PropertyType String -Force -ErrorAction Stop | Out-Null
    Write-Output "Install folder recorded in '$RegistryPath'."

    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Output "Scheduled task '$TaskName' started."
}
catch
{
    Write-Output "ERROR: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}

Stop-Transcript | Out-Null
exit 0
