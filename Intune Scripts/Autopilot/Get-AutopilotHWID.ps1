<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash (HWID) of this device and
    saves it as a CSV file that can be imported into Intune.

.DESCRIPTION
    The script reads the device serial number and hardware hash directly from
    Windows (the same WMI class Get-WindowsAutopilotInfo uses), so it needs no
    internet connection and installs nothing from the PowerShell Gallery. It
    works in full Windows and at OOBE (Shift+F10).

    The script first asks "Is this device part of a bulk enrollment?". It
    then asks for a Group Tag (can be left blank), for single and bulk
    enrollment.

    In a console window the questions are asked in the console. In PowerShell
    ISE they are shown in a small window that stays on top of other windows.

    Files are written to the folder the script is run from (for example a USB
    drive), unless -OutputPath is given:

      <Serial>_<yyyyMMdd-HHmmss>.csv  One file per run for this device.
      AutopilotBulkImport.csv         Only for bulk enrollment. One file with
                                      every device, for a single Intune import.
                                      Always has the Group Tag column. A device
                                      that is already in the file is replaced,
                                      not added twice.
      HWIDCollectionLog.csv           One row per run: timestamp, serial,
                                      computer name, bulk yes/no, group tag,
                                      file name.

    The CSV files have the header Intune expects. The timestamp is in the
    file name and the log, not in the CSV columns, because Intune rejects
    unknown columns.

.PARAMETER BulkEnrollment
    Yes or No. When not given, the script asks.

.PARAMETER GroupTag
    Autopilot group tag. When not given, the script asks. Commas and double
    quotes are not allowed.

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
    Version 2.1
    2.1 - The Group Tag question is also asked for single enrollment.
    2.0 - Questions are asked at the start, before the hash is collected.
          In PowerShell ISE the questions use a window that stays on top
          (Read-Host in ISE waited for input without a visible prompt).
          Bulk enrollment asks for a Group Tag for every device.
          AutopilotBulkImport.csv always has the Group Tag column; a bulk
          file from 1.0 without that column is converted automatically.
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

# --- Question helpers --------------------------------------------------------
# PowerShell ISE: a small window that stays on top. Console: Read-Host.

$script:UseDialog = ($Host.Name -eq 'Windows PowerShell ISE Host')

function Show-QuestionDialog {
    param(
        [string]$Message,
        [switch]$YesNo
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Autopilot HWID'
    $form.TopMost         = $true
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox     = $false
    $form.MaximizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(400, 130)

    $label          = New-Object System.Windows.Forms.Label
    $label.Text     = $Message
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(376, 40)
    $form.Controls.Add($label)

    $textBox = $null
    if ($YesNo) {
        $yesButton              = New-Object System.Windows.Forms.Button
        $yesButton.Text         = 'Yes'
        $yesButton.Location     = New-Object System.Drawing.Point(220, 90)
        $yesButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($yesButton)

        $noButton              = New-Object System.Windows.Forms.Button
        $noButton.Text         = 'No'
        $noButton.Location     = New-Object System.Drawing.Point(310, 90)
        $noButton.DialogResult = [System.Windows.Forms.DialogResult]::No
        $form.Controls.Add($noButton)
    }
    else {
        $textBox          = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(12, 55)
        $textBox.Size     = New-Object System.Drawing.Size(376, 22)
        $form.Controls.Add($textBox)

        $okButton              = New-Object System.Windows.Forms.Button
        $okButton.Text         = 'OK'
        $okButton.Location     = New-Object System.Drawing.Point(310, 90)
        $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($okButton)
        $form.AcceptButton = $okButton
    }

    $form.Add_Shown({ $form.Activate() })
    $result = $form.ShowDialog()
    $text = $null
    if ($textBox) { $text = $textBox.Text }
    $form.Dispose()

    [PSCustomObject]@{ Result = $result; Text = $text }
}

function Read-YesNo {
    param([string]$Question)
    while ($true) {
        if ($script:UseDialog) {
            $answer = Show-QuestionDialog -Message $Question -YesNo
            if ($answer.Result -eq [System.Windows.Forms.DialogResult]::Yes) { return $true }
            if ($answer.Result -eq [System.Windows.Forms.DialogResult]::No)  { return $false }
        }
        else {
            $answer = "$(Read-Host "$Question (Y/N)")".Trim().ToUpper()
            if (@('Y', 'YES') -contains $answer) { return $true }
            if (@('N', 'NO')  -contains $answer) { return $false }
        }
    }
}

function Read-GroupTag {
    while ($true) {
        $question = 'Enter the Group Tag for this device (leave blank for none):'
        if ($script:UseDialog) {
            $tag = "$((Show-QuestionDialog -Message $question).Text)".Trim()
        }
        else {
            $tag = "$(Read-Host $question)".Trim()
        }
        if ($tag -match '^[^,"]*$') { return $tag }
        Write-Host 'The Group Tag cannot contain commas or double quotes.' -ForegroundColor Yellow
    }
}

# --- Administrator check (the hardware hash can only be read as administrator)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as administrator. Right-click PowerShell and choose 'Run as administrator'." -ForegroundColor Red
    exit 1
}

# --- Questions (asked first, before anything is collected or saved)
if ($BulkEnrollment) {
    $isBulk = ($BulkEnrollment -eq 'Yes')
}
else {
    $isBulk = Read-YesNo -Question 'Is this device part of a bulk enrollment?'
}

if (-not $PSBoundParameters.ContainsKey('GroupTag')) {
    $GroupTag = Read-GroupTag
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
Write-Host 'Reading serial number and hardware hash...'
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
$baseHeader = 'Device Serial Number,Windows Product ID,Hardware Hash'
$tagHeader  = "$($baseHeader),Group Tag"
$baseRow    = "$($serialNumber),,$($hardwareHash)"
$tagRow     = "$($baseRow),$($GroupTag)"

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeSerial = $serialNumber -replace '[\\/:*?"<>|\s]', '_'
$deviceFile = Join-Path $OutputPath "$($safeSerial)_$($timestamp).csv"
$bulkFile   = Join-Path $OutputPath 'AutopilotBulkImport.csv'
$logFile    = Join-Path $OutputPath 'HWIDCollectionLog.csv'

# --- Save this device's own file (Group Tag column only when a tag is set)
if ($GroupTag) {
    $deviceLines = @($tagHeader, $tagRow)
}
else {
    $deviceLines = @($baseHeader, $baseRow)
}
Set-Content -LiteralPath $deviceFile -Value $deviceLines -Encoding ASCII
Write-Host "Hardware hash saved to: $deviceFile" -ForegroundColor Green

# --- Add the device to the bulk file (always with the Group Tag column)
$bulkDeviceCount = $null
if ($isBulk) {
    $keptLines = @()
    if (Test-Path -LiteralPath $bulkFile) {
        $existingLines = @(Get-Content -LiteralPath $bulkFile | Where-Object { $_.Trim() })
        $dataLines     = @($existingLines | Select-Object -Skip 1)

        if ($existingLines.Count -gt 0 -and $existingLines[0] -eq $baseHeader) {
            # Bulk file from version 1.0 without the Group Tag column: add it.
            $dataLines = @($dataLines | ForEach-Object { "$($_)," })
            Write-Host "Added the Group Tag column to the existing bulk file." -ForegroundColor Yellow
        }
        elseif ($existingLines.Count -gt 0 -and $existingLines[0] -ne $tagHeader) {
            Write-Host "The first line of $bulkFile is not a known Autopilot header:" -ForegroundColor Red
            Write-Host "  $($existingLines[0])" -ForegroundColor Red
            Write-Host "The bulk file was not changed. This device's own file was still saved." -ForegroundColor Red
            exit 1
        }

        $keptLines = @($dataLines | Where-Object { ($_ -split ',')[0] -ne $serialNumber })
        if ($keptLines.Count -lt $dataLines.Count) {
            Write-Host "Serial $serialNumber was already in the bulk file. Its row was replaced with the new hash." -ForegroundColor Yellow
        }
    }

    $bulkLines = @($tagHeader) + $keptLines + @($tagRow)
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
Write-Host "Group Tag:     $(if ($GroupTag) { $GroupTag } else { '(none)' })"
Write-Host "Done."
