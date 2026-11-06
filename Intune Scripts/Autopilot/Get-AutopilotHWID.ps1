<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash (HWID) of this device and
    saves it as a CSV file that can be imported into Intune.

.DESCRIPTION
    The script reads the device serial number and hardware hash directly from
    Windows (the same WMI class Get-WindowsAutopilotInfo uses), so it needs no
    internet connection and installs nothing from the PowerShell Gallery. It
    works in full Windows and at OOBE (Shift+F10).

    Files are written to the folder the script is run from (for example a USB
    drive), unless -OutputPath is given:

      <Serial>_<yyyyMMdd-HHmmss>.csv  One file per run for this device.
      AutopilotBulkImport.csv         Only for bulk enrollment. One file with
                                      every device, for a single Intune import.
                                      A device that is already in the file is
                                      replaced, not added twice.
      HWIDCollectionLog.csv           One row per run: timestamp, serial,
                                      computer name, bulk yes/no, file name.

    The CSV files have the exact header Intune expects. The timestamp is in the
    file name and the log, not in the CSV columns, because Intune rejects
    unknown columns.

.PARAMETER BulkEnrollment
    Yes or No. When not given, the script asks:
    "Is this device part of a bulk enrollment?"

.PARAMETER GroupTag
    Optional Autopilot group tag, added as the "Group Tag" column. All devices
    in one bulk file must either all have a group tag column or all not have it.

.PARAMETER OutputPath
    Folder for the output files. Default: the folder the script is in, or the
    current folder when the code is pasted into a console.

.EXAMPLE
    .\Get-AutopilotHWID.ps1

.EXAMPLE
    .\Get-AutopilotHWID.ps1 -BulkEnrollment Yes -GroupTag "Kiosk"

.EXAMPLE
    At OOBE: Shift+F10, then
    powershell.exe -ExecutionPolicy Bypass -File D:\Get-AutopilotHWID.ps1

.NOTES
    Version 1.0
    1.0 - Collects the hash without Get-WindowsAutopilotInfo, saves to the
          script folder with a timestamp in the file name, optional bulk CSV
          and group tag, run log, administrator check.
#>
[CmdletBinding()]
param(
    [ValidateSet('Yes', 'No')]
    [string]$BulkEnrollment,

    [ValidatePattern('^[^,"]*$')]
    [string]$GroupTag,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# --- Administrator check (the hardware hash can only be read as administrator)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as administrator. Right-click PowerShell and choose 'Run as administrator'." -ForegroundColor Red
    exit 1
}

# --- Output folder: where the script is run from
if (-not $OutputPath) {
    if ($PSScriptRoot) {
        $OutputPath = $PSScriptRoot
    }
    else {
        $OutputPath = (Get-Location).Path
    }
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# --- Collect serial number and hardware hash
$serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
if ($serialNumber) {
    $serialNumber = $serialNumber.Trim()
}
if (-not $serialNumber) {
    Write-Host "No serial number found in the BIOS. Intune needs a serial number to import the device." -ForegroundColor Red
    exit 1
}

try {
    $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
}
catch {
    Write-Host "Could not read the hardware hash: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$hardwareHash = $devDetail.DeviceHardwareData
if (-not $hardwareHash) {
    Write-Host "The hardware hash is empty. This can happen on virtual machines without a virtual TPM or on unsupported Windows editions." -ForegroundColor Red
    exit 1
}

# --- Build the CSV lines in the format Intune expects (no quotes)
$columns = @('Device Serial Number', 'Windows Product ID', 'Hardware Hash')
$values  = @($serialNumber, '', $hardwareHash)
if ($GroupTag) {
    $columns += 'Group Tag'
    $values  += $GroupTag
}
$header = $columns -join ','
$row    = $values -join ','

$timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeSerial     = $serialNumber -replace '[\\/:*?"<>|\s]', '_'
$deviceFile     = Join-Path $OutputPath "$($safeSerial)_$($timestamp).csv"
$bulkFile       = Join-Path $OutputPath 'AutopilotBulkImport.csv'
$logFile        = Join-Path $OutputPath 'HWIDCollectionLog.csv'

# --- Save this device's own file
Set-Content -LiteralPath $deviceFile -Value @($header, $row) -Encoding ASCII
Write-Host "Hardware hash saved to: $deviceFile" -ForegroundColor Green

# --- Bulk enrollment question
if ($BulkEnrollment) {
    $isBulk = ($BulkEnrollment -eq 'Yes')
}
else {
    do {
        $answer = "$(Read-Host 'Is this device part of a bulk enrollment? (Y/N)')".Trim().ToUpper()
    } while (@('Y', 'YES', 'N', 'NO') -notcontains $answer)
    $isBulk = $answer.StartsWith('Y')
}

# --- Add the device to the bulk file
$bulkDeviceCount = $null
if ($isBulk) {
    if (Test-Path -LiteralPath $bulkFile) {
        $existingLines = @(Get-Content -LiteralPath $bulkFile | Where-Object { $_.Trim() })
        if ($existingLines.Count -gt 0 -and $existingLines[0] -ne $header) {
            Write-Host "The columns in $bulkFile do not match this device:" -ForegroundColor Red
            Write-Host "  File:        $($existingLines[0])" -ForegroundColor Red
            Write-Host "  This device: $header" -ForegroundColor Red
            Write-Host "Use -GroupTag for every device in the file, or for none. This device's own file was still saved." -ForegroundColor Red
            exit 1
        }
        $dataLines = @($existingLines | Select-Object -Skip 1)
        $keptLines = @($dataLines | Where-Object { ($_ -split ',')[0] -ne $serialNumber })
        if ($keptLines.Count -lt $dataLines.Count) {
            Write-Host "Serial $serialNumber was already in the bulk file. Its row was replaced with the new hash." -ForegroundColor Yellow
        }
        $bulkLines = @($header) + $keptLines + @($row)
    }
    else {
        $bulkLines = @($header, $row)
    }

    Set-Content -LiteralPath $bulkFile -Value $bulkLines -Encoding ASCII
    $bulkDeviceCount = $bulkLines.Count - 1
    Write-Host "Device added to bulk file: $bulkFile ($bulkDeviceCount devices)" -ForegroundColor Green
    if ($bulkDeviceCount -gt 500) {
        Write-Host "Warning: Intune imports at most 500 devices per CSV file. Split this file before importing." -ForegroundColor Yellow
    }
}

# --- Run log
[PSCustomObject]@{
    Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    SerialNumber   = $serialNumber
    ComputerName   = $env:COMPUTERNAME
    BulkEnrollment = $(if ($isBulk) { 'Yes' } else { 'No' })
    GroupTag       = $GroupTag
    DeviceFile     = (Split-Path $deviceFile -Leaf)
} | Export-Csv -LiteralPath $logFile -Append -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Serial number: $serialNumber"
Write-Host "Computer name: $env:COMPUTERNAME"
Write-Host "Bulk:          $(if ($isBulk) { 'Yes' } else { 'No' })"
Write-Host "Done."
