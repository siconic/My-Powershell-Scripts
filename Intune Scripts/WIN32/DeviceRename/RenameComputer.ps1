# Renames the computer to the COMPANY naming standard:
#   first 3 characters of the current hostname (or $HostnamePrefix) + up to 10 characters of the BIOS serial number
# Run by the RenameHost scheduled task (as SYSTEM, shown to the user through ServiceUI.exe).
# The task is disabled only after the rename has succeeded and the user has restarted,
# or when the hostname already matches. After a failure the task stays enabled and tries again.

$OrgName = "COMPANY"

# Set a fixed prefix (for example a site code) to use it instead of the first 3 characters of the current hostname.
$HostnamePrefix = ""

$TaskName = "RenameHost"
$LogFolder = "C:\ProgramData\COMPANY\Log"
$LogPath = "C:\ProgramData\COMPANY\Log\RenameInstall.log"
$RegistryPath = "HKLM:\SOFTWARE\Packages\HostRename"

# Default names that must not be used as a prefix
$DefaultNamePatterns = @('^DESKTOP-', '^LAPTOP-', '^WIN-', '^MININT-')

# BIOS serial values that are placeholders, not real serial numbers (compared after cleaning)
$InvalidSerials = @('TOBEFILLEDBYOEM', 'DEFAULTSTRING', 'SYSTEMSERIALNUMBER', 'NONE', 'NA', 'INVALID', '0', '00000000', '0123456789', '123456789')

function Get-TargetHostName
{
    param(
        [string]$CurrentName,
        [string]$Serial,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Serial))
    {
        throw "BIOS serial number could not be retrieved."
    }

    $CleanSerial = ($Serial.Trim() -replace '[^A-Za-z0-9]', '').ToUpper()

    if ([string]::IsNullOrWhiteSpace($CleanSerial))
    {
        throw "BIOS serial number is empty after cleaning."
    }

    if ($InvalidSerials -contains $CleanSerial -or $CleanSerial -match '^0+$')
    {
        throw "BIOS serial number '$CleanSerial' is a placeholder value, not a real serial number."
    }

    if ($CleanSerial.Length -ge 10)
    {
        $ShortSerial = $CleanSerial.Substring(0, 10)
    }
    else
    {
        $ShortSerial = $CleanSerial
    }

    if ([string]::IsNullOrWhiteSpace($Prefix))
    {
        if ([string]::IsNullOrWhiteSpace($CurrentName) -or $CurrentName.Length -lt 3)
        {
            throw "Current hostname '$CurrentName' is shorter than 3 characters."
        }

        foreach ($Pattern in $DefaultNamePatterns)
        {
            if ($CurrentName -match $Pattern)
            {
                throw "Current hostname '$CurrentName' is a Windows default name. Set `$HostnamePrefix or rename the device manually."
            }
        }

        $Prefix = $CurrentName.Substring(0, 3)
    }

    $NewName = "$($Prefix)$($ShortSerial)".ToUpper()

    if ($NewName.Length -gt 15)
    {
        throw "Generated hostname '$NewName' exceeds 15 characters."
    }

    if ($NewName -notmatch '^[A-Z0-9-]+$' -or $NewName -match '^[0-9]+$')
    {
        throw "Generated hostname '$NewName' is not a valid computer name."
    }

    return $NewName
}

function Disable-RenameTask
{
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task)
    {
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
        Write-Output "Task '$TaskName' has been disabled."
    }
}

function Request-Restart
{
    param([string]$NewName)

    Add-Type -AssemblyName System.Windows.Forms

    $Message = "Your computer name has been changed to '$NewName' to meet the $OrgName naming standard.`r`n`r`n" +
        "A restart is required. Save your work, then click Yes to restart now.`r`n" +
        "Click No to restart later; you will be asked again in 15 minutes."

    $Result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "Restart required",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($Result -eq [System.Windows.Forms.DialogResult]::Yes)
    {
        Write-Output "User chose to restart now."
        Disable-RenameTask
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit 0
    }

    Write-Output "User postponed the restart. The task stays enabled and will ask again."
}

# Create the log folder if it does not exist
if (!(Test-Path $LogFolder))
{
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath -Append | Out-Null

try
{
    # Active name = name in use now. Pending name = name after the next restart.
    $ActiveName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -ErrorAction Stop).ComputerName
    $PendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction Stop).ComputerName
    Write-Output "Current hostname: $ActiveName"
    if ($PendingName -ne $ActiveName)
    {
        Write-Output "Pending hostname (after restart): $PendingName"
    }

    $Serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    Write-Output "BIOS serial number: $Serial"

    $NewHostName = Get-TargetHostName -CurrentName $ActiveName -Serial $Serial -Prefix $HostnamePrefix
    Write-Output "Target hostname: $NewHostName"

    if ($ActiveName -eq $NewHostName)
    {
        Write-Output "Hostname already matches the $OrgName naming standard."
        Disable-RenameTask
        Stop-Transcript | Out-Null
        exit 0
    }

    if (!(Test-Path $RegistryPath))
    {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    if ($PendingName -eq $NewHostName)
    {
        Write-Output "Rename to '$NewHostName' is already done and waits for a restart."
    }
    else
    {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($ComputerSystem.PartOfDomain)
        {
            Write-Output "Device is joined to domain '$($ComputerSystem.Domain)'. The rename needs a reachable domain controller."
        }

        New-ItemProperty -Path $RegistryPath -Name "OldHostname" -Value $ActiveName -PropertyType String -Force | Out-Null

        Rename-Computer -NewName $NewHostName -Force -ErrorAction Stop -WarningAction SilentlyContinue

        New-ItemProperty -Path $RegistryPath -Name "NewHostname" -Value $NewHostName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegistryPath -Name "Rename" -Value "1" -PropertyType String -Force | Out-Null
        Write-Output "Computer renamed to '$NewHostName'. A restart is required."
    }

    Request-Restart -NewName $NewHostName
}
catch
{
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output "Computer rename was NOT completed. The task stays enabled and tries again at the next run."
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

try { Stop-Transcript | Out-Null } catch { }
exit 0
