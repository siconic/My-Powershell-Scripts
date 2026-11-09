<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash (HWID) of this device, saves
    it as a CSV file for Intune, and can import it to Intune directly.

.DESCRIPTION
    The script reads the device serial number and hardware hash directly from
    Windows (the same WMI class Get-WindowsAutopilotInfo uses). Single and
    Bulk need no internet connection and install nothing, so they work in
    full Windows and at OOBE (Shift+F10).

    The script first asks "How should this device be enrolled?":

      Single CSV     Save a CSV file for this device.
      Bulk CSV       Save a CSV file for this device and add the device to
                     AutopilotBulkImport.csv, for one Intune import of many
                     devices.
      Online import  Save a CSV file for this device and import the device
                     to Intune now through Microsoft Graph. Needs internet
                     and an account that may import Autopilot devices.

    It then asks for a Group Tag (can be left blank).

    In a console window the questions are asked in the console. In PowerShell
    ISE they are shown in a small window that stays on top of other windows.

    Files are written to the folder the script is run from (for example a USB
    drive), unless -OutputPath is given:

      <Serial>_<yyyyMMdd-HHmmss>.csv  One file per run for this device.
      AutopilotBulkImport.csv         Bulk CSV only. Every device, for a single
                                      Intune import. Always has the Group Tag
                                      column. A device that is already in the
                                      file is replaced, not added twice.
      HWIDCollectionLog.csv           One row per run: timestamp, serial,
                                      computer name, mode, group tag, file
                                      name, online import result.

    The CSV files have the header Intune expects. The timestamp is in the
    file name and the log, not in the CSV columns, because Intune rejects
    unknown columns.

    Online import:
      - Installs the Microsoft.Graph.Authentication module (CurrentUser) from
        the PowerShell Gallery when it is missing.
      - Runs Set-MgGraphOption -DisableLoginByWAM $true before signing in, so
        the sign-in uses a browser window instead of the Windows sign-in
        broker (WAM). This setting is saved for the user account and also
        applies to later Connect-MgGraph sessions.
      - Signs in with the scope DeviceManagementServiceConfig.ReadWrite.All,
        uploads the device, waits up to 10 minutes for Intune to process it,
        and signs out again.

.PARAMETER Mode
    Single, Bulk or Online. When not given, the script asks.

.PARAMETER BulkEnrollment
    Kept from version 2.x. Yes is the same as -Mode Bulk, No is the same as
    -Mode Single. -Mode wins when both are given.

.PARAMETER GroupTag
    Autopilot group tag. When not given, the script asks. Commas and double
    quotes are not allowed.

.PARAMETER OutputPath
    Folder for the output files. Default: the folder the script is in, or the
    current folder when the code is pasted into a console.

.PARAMETER UseDeviceCode
    Online import only. Sign in with a device code (enter the code on another
    device) instead of a browser window on this device. Useful at OOBE.

.EXAMPLE
    .\Get-AutopilotHWID.ps1

.EXAMPLE
    .\Get-AutopilotHWID.ps1 -Mode Bulk -GroupTag "Kiosk"

.EXAMPLE
    .\Get-AutopilotHWID.ps1 -Mode Online -GroupTag "Kiosk" -UseDeviceCode

.EXAMPLE
    At OOBE: Shift+F10, then
    powershell.exe -ExecutionPolicy Bypass -File D:\Get-AutopilotHWID.ps1

.NOTES
    Version 3.0
    3.0 - New first question with three choices: Single CSV, Bulk CSV,
          Online import. Online import uploads the device to Intune through
          Microsoft Graph, with Set-MgGraphOption -DisableLoginByWAM $true.
          New parameters -Mode and -UseDeviceCode. Log column BulkEnrollment
          replaced by Mode and OnlineImport; a log file with the old columns
          is renamed to HWIDCollectionLog_old_<timestamp>.csv.
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
    [ValidateSet('Single', 'Bulk', 'Online')]
    [string]$Mode,

    [ValidateSet('Yes', 'No')]
    [string]$BulkEnrollment,

    [ValidatePattern('^[^,"]*$')]
    [string]$GroupTag,

    [string]$OutputPath,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'

# --- Question helpers --------------------------------------------------------
# PowerShell ISE: a small window that stays on top. Console: Read-Host.

$script:UseDialog = ($Host.Name -eq 'Windows PowerShell ISE Host')

function Show-QuestionDialog {
    param(
        [string]$Message,
        [string[]]$Choices,
        [switch]$TextInput
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
    $form.ClientSize      = New-Object System.Drawing.Size(420, 140)

    $label          = New-Object System.Windows.Forms.Label
    $label.Text     = $Message
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(396, 54)
    $form.Controls.Add($label)

    $textBox = $null
    if ($TextInput) {
        $textBox          = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(12, 68)
        $textBox.Size     = New-Object System.Drawing.Size(396, 22)
        $form.Controls.Add($textBox)
        $Choices = @('OK')
    }

    # Buttons, right-aligned. Each button stores its text in the form's Tag.
    $buttonWidth = 120
    $x = 420 - 12 - ($Choices.Count * ($buttonWidth + 8)) + 8
    foreach ($choice in $Choices) {
        $button          = New-Object System.Windows.Forms.Button
        $button.Text     = $choice
        $button.Size     = New-Object System.Drawing.Size($buttonWidth, 28)
        $button.Location = New-Object System.Drawing.Point($x, 100)
        $button.Add_Click({
            $parentForm     = $this.FindForm()
            $parentForm.Tag = $this.Text
            $parentForm.Close()
        })
        $form.Controls.Add($button)
        if ($TextInput) { $form.AcceptButton = $button }
        $x += $buttonWidth + 8
    }

    $form.Add_Shown({ $this.Activate() })
    [void]$form.ShowDialog()
    $text = $null
    if ($textBox) { $text = $textBox.Text }
    $result = [PSCustomObject]@{ Choice = $form.Tag; Text = $text }
    $form.Dispose()
    $result
}

function Read-EnrollmentMode {
    $question = 'How should this device be enrolled?'
    while ($true) {
        if ($script:UseDialog) {
            $message = "$($question)`nSingle CSV: save a CSV for this device.`nBulk CSV: also add it to AutopilotBulkImport.csv.`nOnline import: import it to Intune now (sign-in needed)."
            $answer  = Show-QuestionDialog -Message $message -Choices @('Single CSV', 'Bulk CSV', 'Online import')
            if ($answer.Choice -eq 'Single CSV')    { return 'Single' }
            if ($answer.Choice -eq 'Bulk CSV')      { return 'Bulk' }
            if ($answer.Choice -eq 'Online import') { return 'Online' }
        }
        else {
            Write-Host $question
            Write-Host '  1  Single CSV     Save a CSV for this device.'
            Write-Host '  2  Bulk CSV       Also add it to AutopilotBulkImport.csv.'
            Write-Host '  3  Online import  Import it to Intune now (sign-in needed).'
            $answer = "$(Read-Host 'Enter 1, 2 or 3')".Trim().ToUpper()
            if (@('1', 'SINGLE') -contains $answer) { return 'Single' }
            if (@('2', 'BULK')   -contains $answer) { return 'Bulk' }
            if (@('3', 'ONLINE') -contains $answer) { return 'Online' }
            Write-Host 'Please enter 1, 2 or 3.' -ForegroundColor Yellow
        }
    }
}

function Read-GroupTag {
    while ($true) {
        $question = 'Enter the Group Tag for this device (leave blank for none):'
        if ($script:UseDialog) {
            $tag = "$((Show-QuestionDialog -Message $question -TextInput).Text)".Trim()
        }
        else {
            $tag = "$(Read-Host $question)".Trim()
        }
        if ($tag -match '^[^,"]*$') { return $tag }
        Write-Host 'The Group Tag cannot contain commas or double quotes.' -ForegroundColor Yellow
    }
}

# --- Online import helpers (Microsoft Graph) ---------------------------------

function Initialize-GraphModule {
    # Returns $true when Connect-MgGraph and Set-MgGraphOption -DisableLoginByWAM are ready.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        Write-Host 'Installing the Microsoft.Graph.Authentication module from the PowerShell Gallery...'
        $nuget = @(Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' })
        if ($nuget.Count -eq 0) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module -Name 'Microsoft.Graph.Authentication'

    $optionCommand = Get-Command -Name 'Set-MgGraphOption' -ErrorAction SilentlyContinue
    if (-not $optionCommand -or -not $optionCommand.Parameters.ContainsKey('DisableLoginByWAM')) {
        Write-Host 'The installed Microsoft.Graph.Authentication module is too old: Set-MgGraphOption has no -DisableLoginByWAM parameter. Updating the module...' -ForegroundColor Yellow
        Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Force -AllowClobber
        Write-Host 'The module was updated. Close PowerShell, open it again as administrator and run this script again.' -ForegroundColor Red
        return $false
    }
    return $true
}

function Connect-IntuneGraph {
    param([switch]$UseDeviceCode)

    # Sign in with a browser window instead of the Windows sign-in broker (WAM).
    Set-MgGraphOption -DisableLoginByWAM $true

    $connectParams = @{
        Scopes    = @('DeviceManagementServiceConfig.ReadWrite.All')
        NoWelcome = $true
    }
    if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
    Connect-MgGraph @connectParams

    $context = Get-MgContext
    if (-not $context) {
        throw 'The sign-in to Microsoft Graph did not complete.'
    }
    Write-Host "Signed in as $($context.Account)" -ForegroundColor Green
}

function Import-AutopilotDevice {
    param(
        [string]$SerialNumber,
        [string]$HardwareHash,
        [string]$GroupTag,
        [int]$TimeoutMinutes = 10
    )
    $uri  = 'https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities'
    $body = @{
        '@odata.type'             = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        serialNumber              = $SerialNumber
        productKey                = ''
        hardwareIdentifier        = $HardwareHash
        groupTag                  = $GroupTag
        assignedUserPrincipalName = ''
        state                     = @{
            '@odata.type'        = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
            deviceImportStatus   = 'pending'
            deviceRegistrationId = ''
            deviceErrorCode      = 0
            deviceErrorName      = ''
        }
    }
    $json    = $body | ConvertTo-Json -Depth 5
    $created = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $json -ContentType 'application/json' -OutputType PSObject
    Write-Host 'Upload done. Waiting for Intune to process the import (checked every 15 seconds, up to 10 minutes)...'

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $status   = 'pending'
    $item     = $null
    while (@('unknown', 'pending') -contains $status -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $item   = Invoke-MgGraphRequest -Method GET -Uri "$($uri)/$($created.id)" -OutputType PSObject
        $status = "$($item.state.deviceImportStatus)"
        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  Import status: $status"
    }
    if (@('unknown', 'pending') -contains $status) {
        $status = 'timeout'
    }

    $errorCode = $null
    $errorName = $null
    if ($item) {
        $errorCode = $item.state.deviceErrorCode
        $errorName = $item.state.deviceErrorName
    }
    [PSCustomObject]@{
        Status    = $status
        ErrorCode = $errorCode
        ErrorName = $errorName
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
if ($Mode) {
    $selectedMode = $Mode
}
elseif ($BulkEnrollment) {
    $selectedMode = $(if ($BulkEnrollment -eq 'Yes') { 'Bulk' } else { 'Single' })
}
else {
    $selectedMode = Read-EnrollmentMode
}
$isBulk = ($selectedMode -eq 'Bulk')

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
$exitCode   = 0

# --- Save this device's own file (Group Tag column only when a tag is set)
if ($GroupTag) {
    $deviceLines = @($tagHeader, $tagRow)
}
else {
    $deviceLines = @($baseHeader, $baseRow)
}
Set-Content -LiteralPath $deviceFile -Value $deviceLines -Encoding ASCII
Write-Host "Hardware hash saved to: $deviceFile" -ForegroundColor Green

# --- Bulk CSV: add the device to the bulk file (always with the Group Tag column)
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

# --- Online import to Intune
$onlineResult = ''
if ($selectedMode -eq 'Online') {
    try {
        if (Initialize-GraphModule) {
            Connect-IntuneGraph -UseDeviceCode:$UseDeviceCode
            $import       = Import-AutopilotDevice -SerialNumber $serialNumber -HardwareHash $hardwareHash -GroupTag $GroupTag
            $onlineResult = $import.Status

            if ($import.Status -eq 'complete') {
                Write-Host "The device was imported to Intune (Windows Autopilot devices)." -ForegroundColor Green
                try {
                    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync' | Out-Null
                    Write-Host 'Autopilot sync started. The deployment profile is assigned after the sync, which can take some time.'
                }
                catch {
                    Write-Host "Could not start an Autopilot sync (it may already have run recently): $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            elseif ($import.Status -eq 'error') {
                $onlineResult = "error $($import.ErrorCode) $($import.ErrorName)"
                Write-Host "Intune rejected the import: error $($import.ErrorCode) $($import.ErrorName)" -ForegroundColor Red
                Write-Host 'A common cause is a device that is already registered in Autopilot, in this tenant or another one.' -ForegroundColor Red
                $exitCode = 1
            }
            elseif ($import.Status -eq 'timeout') {
                Write-Host 'Intune has not finished processing the import after 10 minutes. Check Intune admin center > Devices > Windows > Enrollment > Devices.' -ForegroundColor Yellow
            }
            else {
                Write-Host "Import finished with status: $($import.Status)" -ForegroundColor Yellow
            }
        }
        else {
            $onlineResult = 'module update needed'
            $exitCode     = 1
        }
    }
    catch {
        $onlineResult = "failed: $($_.Exception.Message)"
        Write-Host "Online import failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "The device CSV was saved and can be imported in the Intune admin center: $deviceFile" -ForegroundColor Red
        $exitCode = 1
    }
    finally {
        if (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue) {
            if (Get-MgContext) {
                Disconnect-MgGraph | Out-Null
                Write-Host 'Signed out of Microsoft Graph.'
            }
        }
    }
}

# --- Run log (a log with the columns of version 2.x or older is renamed first)
$logHeader = '"Timestamp","SerialNumber","ComputerName","Mode","GroupTag","DeviceFile","OnlineImport"'
if (Test-Path -LiteralPath $logFile) {
    $firstLogLine = Get-Content -LiteralPath $logFile -TotalCount 1
    if ($firstLogLine -ne $logHeader) {
        Rename-Item -LiteralPath $logFile -NewName "HWIDCollectionLog_old_$($timestamp).csv"
    }
}
[PSCustomObject]@{
    Timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    SerialNumber = $serialNumber
    ComputerName = $env:COMPUTERNAME
    Mode         = $selectedMode
    GroupTag     = $GroupTag
    DeviceFile   = (Split-Path $deviceFile -Leaf)
    OnlineImport = $onlineResult
} | Export-Csv -LiteralPath $logFile -Append -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Serial number: $serialNumber"
Write-Host "Computer name: $env:COMPUTERNAME"
Write-Host "Mode:          $selectedMode"
Write-Host "Group Tag:     $(if ($GroupTag) { $GroupTag } else { '(none)' })"
if ($selectedMode -eq 'Online') {
    Write-Host "Online import: $onlineResult"
}
Write-Host "Done."
exit $exitCode
