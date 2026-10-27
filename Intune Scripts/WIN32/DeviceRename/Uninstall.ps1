# Win32 app uninstall script: removes the RenameHost task, the installed files and the HostRename registry key.
# The computer name is not changed back. The log file C:\ProgramData\<OrgName>\Log\RenameInstall.log is kept.
# The install folder is read from the registry (written by Installer.ps1). If that value is missing,
# it is built from Settings.psd1 in the package folder.

# Intune starts uninstall commands as a 32-bit process on 64-bit Windows. Restart in 64-bit PowerShell
# so the registry key removed is HKLM\SOFTWARE\Packages\HostRename, not the WOW6432Node copy.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    & "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$TaskName = "RenameHost"
$RegistryPath = "HKLM:\SOFTWARE\Packages\HostRename"

try
{
    $InstallFolder = (Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue).InstallFolder
    if (!$InstallFolder)
    {
        $SettingsFile = Join-Path $PSScriptRoot "Settings.psd1"
        if (Test-Path $SettingsFile)
        {
            $OrgName = (Import-PowerShellDataFile -Path $SettingsFile -ErrorAction Stop).OrgName
            if ($OrgName) { $InstallFolder = "C:\ProgramData\$OrgName\RenameHost" }
        }
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Output "Scheduled task '$TaskName' removed."
    }

    # Only delete a folder that has the expected form C:\ProgramData\<name>\RenameHost
    if ($InstallFolder -and $InstallFolder -match '^C:\\ProgramData\\[A-Za-z0-9_-]+\\RenameHost$')
    {
        if (Test-Path $InstallFolder)
        {
            Remove-Item -Path $InstallFolder -Recurse -Force -ErrorAction Stop
            Write-Output "Folder '$InstallFolder' removed."
        }
    }
    elseif ($InstallFolder)
    {
        Write-Output "Folder '$InstallFolder' is not in the expected location and was not removed."
    }
    else
    {
        Write-Output "Install folder unknown (no registry value and no Settings.psd1). No folder removed."
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
