# Win32 app install script: copies the rename files and registers the RenameHost scheduled task.
# Can be run again (reinstall): existing files and the existing task are replaced.
# Exit 0 = success, Exit 1 = failure

$InstallFolder = "C:\ProgramData\COMPANY\RenameHost"
$LogFolder = "C:\ProgramData\COMPANY\Log"
$LogPath = "C:\ProgramData\COMPANY\Log\RenameInstall.log"
$TaskName = "RenameHost"
$Files = @("RenameHost.xml", "RenameComputer.ps1", "ServiceUI.exe")

foreach ($Folder in @("C:\ProgramData\COMPANY", $InstallFolder, $LogFolder))
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

    $TaskXml = Get-Content (Join-Path $InstallFolder "RenameHost.xml") -Raw -ErrorAction Stop
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
