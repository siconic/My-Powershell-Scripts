$directoryPath = "C:\ProgramData\Company\RenameHost"

$LogFolder = "C:\ProgramData\Company\Log"

$LogPath = "C:\ProgramData\Company\Log\RenameInstall.log"

# Create the log folder if it does not exist
if (!(Test-Path $LogFolder))
{
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

# Create the RenameHost folder if it does not exist
if (!(Test-Path $directoryPath))
{
    New-Item -Path $directoryPath -ItemType Directory -Force | Out-Null
}

# Start logging
Start-Transcript -Path $LogPath -Append

# Get the full serial number
$fullserial = Get-WmiObject Win32_BIOS | Select-Object -ExpandProperty "SerialNumber"

Write-Output "Full Serial Number: $fullserial"

# Validate serial number
if ([string]::IsNullOrWhiteSpace($fullserial))
{
    Write-Output "ERROR: BIOS serial number could not be retrieved."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

# Clean the serial number
$fullserial = $fullserial.Trim()
$fullserial = $fullserial -replace '[^A-Za-z0-9]', ''

# Validate serial number after cleaning
if ([string]::IsNullOrWhiteSpace($fullserial))
{
    Write-Output "ERROR: BIOS serial number is empty after cleaning."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

Write-Output "Clean Serial Number: $fullserial"
Write-Output "Serial Number Length: $($fullserial.Length)"

# Get the short serial number
# If serial is 10 characters or longer, use first 10 characters
# If serial is shorter than 10 characters, use complete serial number

if ($fullserial.Length -ge 10)
{
    $shortserial = $fullserial.Substring(0,10)

    Write-Output "Full Serial Number is 10 characters or longer."
    Write-Output "Using the first 10 characters of the serial number in the PC name."
}
else
{
    $shortserial = $fullserial

    Write-Output "Serial Number is shorter than 10 characters."
    Write-Output "Using entire serial number in PC name."
}

Write-Output "Serial Number Used: $shortserial"

# Get the current hostname
$hostname = (Get-ComputerInfo).CsName

Write-Output "Current Hostname: $hostname"

# Validate hostname
if ([string]::IsNullOrWhiteSpace($hostname))
{
    Write-Output "ERROR: Current hostname could not be retrieved."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

if ($hostname.Length -lt 3)
{
    Write-Output "ERROR: Current hostname is shorter than 3 characters."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

# Log the old hostname
$registryParentPath = "HKLM:\SOFTWARE\Packages"
$registryPath = "HKLM:\SOFTWARE\Packages\HostRename"

# Create parent registry path if it does not exist
if (!(Test-Path $registryParentPath))
{
    New-Item -Path $registryParentPath -Force | Out-Null
    Write-Output "Created registry path: $registryParentPath"
}

# Create HostRename registry path if it does not exist
if (!(Test-Path $registryPath))
{
    New-Item -Path $registryPath -Force | Out-Null
    Write-Output "Created registry path: $registryPath"
}

# Get the hostname prefix - first 3 characters
$hostnameprefix = $hostname.Substring(0,3)

Write-Output "The hostname prefix is '$hostnameprefix'"

# Define the new COMPANY hostname
# COMPANY Naming Standard:
# First 3 characters of existing hostname + serial number

$NewHostName = "$hostnameprefix$shortserial"

Write-Output "New COMPANY Hostname: $NewHostName"

# Validate the generated hostname
if ([string]::IsNullOrWhiteSpace($shortserial))
{
    Write-Output "ERROR: Serial number portion is empty."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

if ($NewHostName.Length -le 3)
{
    Write-Output "ERROR: Generated hostname '$NewHostName' is invalid."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

if ($NewHostName.Length -gt 15)
{
    Write-Output "ERROR: Generated hostname '$NewHostName' exceeds 15 characters."
    Write-Output "Computer rename will NOT be performed."
    Stop-Transcript
    exit 1
}

Write-Output "Generated hostname passed validation."

if ($hostname -ne $NewHostName)
{
    New-ItemProperty -Path $registryPath -Name "OldHostname" -Value "$hostname" -PropertyType String -Force

    Write-Output "Old hostname is stored in registry."
}

# Check whether hostname has COMPANY serial number or not

if ($hostname -ne $NewHostName)
{
    If ($fullserial.Length -ge 10)
    {
        # Rename computer
        Rename-Computer -NewName "$NewHostName" -Verbose -Force

        New-ItemProperty -Path $registryPath -Name "NewHostname" -Value "$NewHostName" -PropertyType String -Force

        Write-Output "Full Serial Number is 10 characters or longer. Using the first 10 characters of the serial in the PC name."

        # Define the registry path
        $registryPath = "HKLM:\SOFTWARE\Packages\HostRename"

        # Define the name and value of the new string
        $name = "Rename"
        $value = "1"

        # Create the new string value and set its data
        New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType String -Force
    }
    else
    {
        # Rename computer
        Rename-Computer -NewName "$NewHostName" -Verbose -Force

        New-ItemProperty -Path $registryPath -Name "NewHostname" -Value "$NewHostName" -PropertyType String -Force

        Write-Output "Serial Number is shorter than 10 Characters. Using entire serial number in PC name."

        # Define the registry path
        $registryPath = "HKLM:\SOFTWARE\Packages\HostRename"

        # Define the name and value of the new string
        $name = "Rename"
        $value = "1"

        # Create the new string value and set its data
        New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType String -Force
    }

    Add-Type -AssemblyName System.Windows.Forms

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Your Machine name has been updated with COMPANY standards, Click OK to restart the PC and apply the changes.",
        "Restart",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    If ($result -eq "OK")
    {
        $taskName = "RenameHost"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($task)
        {
            Disable-ScheduledTask -TaskName $taskName

            Write-Output "Task '$taskName' has been disabled."
        }

        Stop-Transcript

        Restart-Computer -Force
    }
}
else
{
    Write-Output "Hostname matches the current requirement of COMPANY."

    $taskName = "RenameHost"

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($task)
    {
        Disable-ScheduledTask -TaskName $taskName

        Write-Output "Task '$taskName' has been disabled."
    }
}

# Stop logging
try
{
    Stop-Transcript -ErrorAction SilentlyContinue
}
catch
{
}
