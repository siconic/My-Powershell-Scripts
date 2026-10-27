# Win32 app detection script: installed when the RenameHost task is registered
# and the rename script is in place. The task may be disabled (rename finished).
# Whether the rename itself succeeded is in HKLM:\SOFTWARE\Packages\HostRename and the log.

$Task = Get-ScheduledTask -TaskName "RenameHost" -ErrorAction SilentlyContinue

if ($Task -and (Test-Path "C:\ProgramData\COMPANY\RenameHost\RenameComputer.ps1"))
{
    Write-Output "Installed"
    exit 0
}

exit 1
