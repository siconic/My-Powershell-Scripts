# Win32 app uninstall script: removes the RenameHost task, the installed files and the HostRename registry key.
# The computer name is not changed back. The log file C:\ProgramData\<OrgName>\Log\RenameInstall.log is kept.

# Organization name. Used for the C:\ProgramData\<OrgName> folder and must be
# the same in Installer.ps1, RenameComputer.ps1, Uninstall.ps1 and detection.ps1.
# Letters, digits, - and _ only.
$OrgName = "COMPANY"

$TaskName = "RenameHost"
$InstallFolder = "C:\ProgramData\$OrgName\RenameHost"
$RegistryPath = "HKLM:\SOFTWARE\Packages\HostRename"

try
{
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Output "Scheduled task '$TaskName' removed."
    }

    if (Test-Path $InstallFolder)
    {
        Remove-Item -Path $InstallFolder -Recurse -Force -ErrorAction Stop
        Write-Output "Folder '$InstallFolder' removed."
    }

    if (Test-Path $RegistryPath)
    {
        Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
        Write-Output "Registry key '$RegistryPath' removed."
    }
}
catch
{
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}

exit 0
