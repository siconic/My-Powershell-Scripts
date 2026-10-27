# Win32 app detection script: installed when the RenameHost task is registered
# and the rename script is in place. The task may be disabled (rename finished).
# Whether the rename itself succeeded is in HKLM:\SOFTWARE\Packages\HostRename and the log.
#
# Intune runs this script on its own, outside the package folder, so it cannot read Settings.psd1.
# It reads the install folder that Installer.ps1 stored in HKLM\SOFTWARE\Packages\HostRename\InstallFolder.
# The 64-bit registry view is opened directly, so the result is the same whether Intune runs
# this script as a 32-bit or a 64-bit process.

$InstallFolder = $null
$Hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$Key = $Hklm.OpenSubKey("SOFTWARE\Packages\HostRename")
if ($Key)
{
    $InstallFolder = $Key.GetValue("InstallFolder")
    $Key.Close()
}
$Hklm.Close()

$Task = Get-ScheduledTask -TaskName "RenameHost" -ErrorAction SilentlyContinue

if ($Task -and $InstallFolder -and (Test-Path (Join-Path $InstallFolder "RenameComputer.ps1")))
{
    Write-Output "Installed"
    exit 0
}

exit 1
