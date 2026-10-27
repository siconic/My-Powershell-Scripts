# Win32 app detection script: installed when the RenameHost task is registered
# and the rename script is in place. The task may be disabled (rename finished).
# Whether the rename itself succeeded is in HKLM:\SOFTWARE\Packages\HostRename and the log.

# Organization name. Used for the C:\ProgramData\<OrgName> folder and must be
# the same in Installer.ps1, RenameComputer.ps1, Uninstall.ps1 and detection.ps1.
# Letters, digits, - and _ only.
$OrgName = "COMPANY"

$Task = Get-ScheduledTask -TaskName "RenameHost" -ErrorAction SilentlyContinue

if ($Task -and (Test-Path "C:\ProgramData\$OrgName\RenameHost\RenameComputer.ps1"))
{
    Write-Output "Installed"
    exit 0
}

exit 1
