# Win32 app install script: copies the rename files and registers the RenameHost scheduled task.
# Can be run again (reinstall): existing files and the existing task are replaced.
# Exit 0 = success, Exit 1 = failure

# Organization name. Used for the C:\ProgramData\<OrgName> folder and must be
# the same in Installer.ps1, RenameComputer.ps1, Uninstall.ps1 and detection.ps1.
# Letters, digits, - and _ only.
$OrgName = "COMPANY"

if ($OrgName -notmatch '^[A-Za-z0-9_-]+$')
{
    Write-Output "ERROR: `$OrgName '$OrgName' may contain only letters, digits, - and _."
    exit 1
}

$BaseFolder = "C:\ProgramData\$OrgName"
$InstallFolder = "$BaseFolder\RenameHost"
$LogFolder = "$BaseFolder\Log"
$LogPath = "$LogFolder\RenameInstall.log"
$TaskName = "RenameHost"
$Files = @("RenameHost.xml", "RenameComputer.ps1", "ServiceUI.exe")

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

    # RenameHost.xml has the token __ORGNAME__ in its paths; it is replaced with $OrgName here
    $TaskXml = (Get-Content (Join-Path $InstallFolder "RenameHost.xml") -Raw -ErrorAction Stop).Replace("__ORGNAME__", $OrgName)
    Register-ScheduledTask -Xml $TaskXml -TaskName $TaskName -TaskPath "\" -User "SYSTEM" -Force -ErrorAction Stop | Out-Null
    Write-Output "Scheduled task '$TaskName' registered."

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
