# =====================================================================
# Intune Remediation
# Purpose : Enable Location Services and Automatic Time Zone
# Run As  : SYSTEM
# Bitness : 64-bit PowerShell
# Logs    : C:\ProgramData\Logs\Autotimezone
# =====================================================================

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

$LocationPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
$TZAutoUpdatePath = "HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate"

$ExpectedLocationValue = "Allow"
$ExpectedTZStartValue = 3

# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------

$LogFolder = "C:\ProgramData\Logs\Autotimezone"
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogFolder "AutoTimeZone_Remediation_$TimeStamp.log"

if (-not (Test-Path -Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

$TranscriptStarted = $false
$ExitCode = 1

try {
    Start-Transcript -Path $LogFile -Force | Out-Null
    $TranscriptStarted = $true
}
catch {
    Write-Output "WARNING: Unable to start transcript: $($_.Exception.Message)"
}

try {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "       AUTOMATIC TIME ZONE REMEDIATION"
    Write-Output "============================================================"
    Write-Output "Computer Name : $env:COMPUTERNAME"
    Write-Output "Start Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "Log File      : $LogFile"
    Write-Output "64-bit OS     : $([Environment]::Is64BitOperatingSystem)"
    Write-Output "64-bit PS     : $([Environment]::Is64BitProcess)"
    Write-Output "============================================================"

    # ================================================================
    # BEFORE REMEDIATION
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "              BEFORE REMEDIATION"
    Write-Output "============================================================"

    # ---------------------------------------------------------------
    # Location Services - BEFORE
    # ---------------------------------------------------------------

    Write-Output ""
    Write-Output "[LOCATION SERVICES]"
    Write-Output "Registry Path : $LocationPath"

    $LocationPathExistsBefore = Test-Path -Path $LocationPath

    if ($LocationPathExistsBefore) {

        Write-Output "Path Status   : PRESENT"

        try {
            $LocationValueBefore = Get-ItemPropertyValue `
                -Path $LocationPath `
                -Name "Value" `
                -ErrorAction Stop

            Write-Output "Value Status  : PRESENT"
            Write-Output "Value BEFORE  : $LocationValueBefore"
        }
        catch {
            $LocationValueBefore = $null

            Write-Output "Value Status  : NOT PRESENT"
            Write-Output "Value BEFORE  : <Not Configured>"
        }
    }
    else {

        $LocationValueBefore = $null

        Write-Output "Path Status   : NOT PRESENT"
        Write-Output "Value Status  : NOT PRESENT"
        Write-Output "Value BEFORE  : <Not Configured>"
    }

    # ---------------------------------------------------------------
    # Auto Time Zone - BEFORE
    # ---------------------------------------------------------------

    Write-Output ""
    Write-Output "[AUTOMATIC TIME ZONE]"
    Write-Output "Registry Path : $TZAutoUpdatePath"

    $TZPathExistsBefore = Test-Path -Path $TZAutoUpdatePath

    if ($TZPathExistsBefore) {

        Write-Output "Path Status   : PRESENT"

        try {
            $TZValueBefore = Get-ItemPropertyValue `
                -Path $TZAutoUpdatePath `
                -Name "Start" `
                -ErrorAction Stop

            Write-Output "Value Status  : PRESENT"
            Write-Output "Value BEFORE  : $TZValueBefore"
        }
        catch {
            $TZValueBefore = $null

            Write-Output "Value Status  : NOT PRESENT"
            Write-Output "Value BEFORE  : <Not Configured>"
        }
    }
    else {

        $TZValueBefore = $null

        Write-Output "Path Status   : NOT PRESENT"
        Write-Output "Value Status  : NOT PRESENT"
        Write-Output "Value BEFORE  : <Not Configured>"
    }

    # ================================================================
    # REMEDIATION
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "                 CHANGES APPLIED"
    Write-Output "============================================================"

    # ---------------------------------------------------------------
    # Location Services Remediation
    # ---------------------------------------------------------------

    if (-not $LocationPathExistsBefore) {

        Write-Output ""
        Write-Output "[CHANGE] Creating missing Location registry path"
        Write-Output "Path     : $LocationPath"

        New-Item `
            -Path $LocationPath `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Output "Result   : Registry path CREATED"
    }
    else {
        Write-Output ""
        Write-Output "[NO CHANGE] Location registry path already exists"
    }

    if ($LocationValueBefore -ne $ExpectedLocationValue) {

        Write-Output "[CHANGE] Location value requires remediation"
        Write-Output "Before   : $(if ($null -eq $LocationValueBefore) {'<Not Configured>'} else {$LocationValueBefore})"
        Write-Output "Target   : $ExpectedLocationValue"

        New-ItemProperty `
            -Path $LocationPath `
            -Name "Value" `
            -Value $ExpectedLocationValue `
            -PropertyType String `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Output "Result   : Location value changed successfully"
    }
    else {

        Write-Output "[NO CHANGE] Location value already equals $ExpectedLocationValue"
    }

    # ---------------------------------------------------------------
    # Automatic Time Zone Remediation
    # ---------------------------------------------------------------

    if (-not $TZPathExistsBefore) {
        throw "Automatic Time Zone registry path does not exist: $TZAutoUpdatePath"
    }

    if ($TZValueBefore -ne $ExpectedTZStartValue) {

        Write-Output ""
        Write-Output "[CHANGE] Automatic Time Zone requires remediation"
        Write-Output "Before   : $(if ($null -eq $TZValueBefore) {'<Not Configured>'} else {$TZValueBefore})"
        Write-Output "Target   : $ExpectedTZStartValue"

        New-ItemProperty `
            -Path $TZAutoUpdatePath `
            -Name "Start" `
            -Value $ExpectedTZStartValue `
            -PropertyType DWord `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Output "Result   : Start value changed successfully"
    }
    else {

        Write-Output ""
        Write-Output "[NO CHANGE] Automatic Time Zone Start already equals $ExpectedTZStartValue"
    }

    # ================================================================
    # AFTER REMEDIATION
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "               AFTER REMEDIATION"
    Write-Output "============================================================"

    # ---------------------------------------------------------------
    # Location - AFTER
    # ---------------------------------------------------------------

    $LocationPathExistsAfter = Test-Path -Path $LocationPath

    Write-Output ""
    Write-Output "[LOCATION SERVICES]"
    Write-Output "Registry Path : $LocationPath"

    if ($LocationPathExistsAfter) {

        Write-Output "Path Status   : PRESENT"

        try {

            $LocationValueAfter = Get-ItemPropertyValue `
                -Path $LocationPath `
                -Name "Value" `
                -ErrorAction Stop

            Write-Output "Value Status  : PRESENT"
            Write-Output "Value AFTER   : $LocationValueAfter"
        }
        catch {

            $LocationValueAfter = $null

            Write-Output "Value Status  : NOT PRESENT"
            Write-Output "Value AFTER   : <Not Configured>"
        }
    }
    else {

        $LocationValueAfter = $null

        Write-Output "Path Status   : NOT PRESENT"
        Write-Output "Value Status  : NOT PRESENT"
        Write-Output "Value AFTER   : <Not Configured>"
    }

    # ---------------------------------------------------------------
    # Auto Time Zone - AFTER
    # ---------------------------------------------------------------

    $TZPathExistsAfter = Test-Path -Path $TZAutoUpdatePath

    Write-Output ""
    Write-Output "[AUTOMATIC TIME ZONE]"
    Write-Output "Registry Path : $TZAutoUpdatePath"

    if ($TZPathExistsAfter) {

        Write-Output "Path Status   : PRESENT"

        try {

            $TZValueAfter = Get-ItemPropertyValue `
                -Path $TZAutoUpdatePath `
                -Name "Start" `
                -ErrorAction Stop

            Write-Output "Value Status  : PRESENT"
            Write-Output "Value AFTER   : $TZValueAfter"
        }
        catch {

            $TZValueAfter = $null

            Write-Output "Value Status  : NOT PRESENT"
            Write-Output "Value AFTER   : <Not Configured>"
        }
    }
    else {

        $TZValueAfter = $null

        Write-Output "Path Status   : NOT PRESENT"
        Write-Output "Value Status  : NOT PRESENT"
        Write-Output "Value AFTER   : <Not Configured>"
    }

    # ================================================================
    # BEFORE / AFTER SUMMARY
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "             BEFORE / AFTER SUMMARY"
    Write-Output "============================================================"

    Write-Output ""
    Write-Output "LOCATION SERVICES"
    Write-Output "Path Before : $(if ($LocationPathExistsBefore) {'PRESENT'} else {'NOT PRESENT'})"
    Write-Output "Path After  : $(if ($LocationPathExistsAfter) {'PRESENT'} else {'NOT PRESENT'})"
    Write-Output "Value Before: $(if ($null -eq $LocationValueBefore) {'<Not Configured>'} else {$LocationValueBefore})"
    Write-Output "Value After : $(if ($null -eq $LocationValueAfter) {'<Not Configured>'} else {$LocationValueAfter})"

    Write-Output ""
    Write-Output "AUTOMATIC TIME ZONE"
    Write-Output "Path Before : $(if ($TZPathExistsBefore) {'PRESENT'} else {'NOT PRESENT'})"
    Write-Output "Path After  : $(if ($TZPathExistsAfter) {'PRESENT'} else {'NOT PRESENT'})"
    Write-Output "Value Before: $(if ($null -eq $TZValueBefore) {'<Not Configured>'} else {$TZValueBefore})"
    Write-Output "Value After : $(if ($null -eq $TZValueAfter) {'<Not Configured>'} else {$TZValueAfter})"

    # ================================================================
    # SERVICE AND TIME ZONE INFORMATION
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "             CURRENT DEVICE STATUS"
    Write-Output "============================================================"

    $TZService = Get-Service -Name "tzautoupdate" -ErrorAction SilentlyContinue

    if ($null -ne $TZService) {
        Write-Output "TZ Service Status : $($TZService.Status)"
        Write-Output "TZ Service Start  : $($TZService.StartType)"
    }
    else {
        Write-Output "TZ Service Status : SERVICE NOT FOUND"
    }

    $CurrentTimeZone = Get-TimeZone

    Write-Output "ntTimeZone.Id)"

    # ================================================================
    # FINAL VALIDATION
    # ================================================================

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "                   FINAL RESULT"
    Write-Output "============================================================"

    $LocationPass = (
        $LocationPathExistsAfter -and
        ($LocationValueAfter -eq $ExpectedLocationValue)
    )

    $TZPass = (
        $TZPathExistsAfter -and
        ([int]$TZValueAfter -eq $ExpectedTZStartValue)
    )

    if ($LocationPass) {
        Write-Output "Location Services : PASS"
    }
    else {
        Write-Output "Location Services : FAIL"
    }

    if ($TZPass) {
        Write-Output "Automatic TZ      : PASS"
    }
    else {
        Write-Output "Automatic TZ      : FAIL"
    }

    if ($LocationPass -and $TZPass) {

        Write-Output "Overall Result     : SUCCESS"
        Write-Output "Exit Code          : 0"

        $ExitCode = 0
    }
    else {

        Write-Output "Overall Result     : FAILED"
        Write-Output "Exit Code          : 1"

        $ExitCode = 1
    }
}
catch {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "                 REMEDIATION FAILED"
    Write-Output "============================================================"

    Write-Output "Error Message : $($_.Exception.Message)"
    Write-Output "Error Type    : $($_.Exception.GetType().FullName)"
    Write-Output "Script Line   : $($_.InvocationInfo.ScriptLineNumber)"
    Write-Output "Position      : $($_.InvocationInfo.PositionMessage)"

    $ExitCode = 1
}
finally {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "End Time      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "Final ExitCode: $ExitCode"
    Write-Output "============================================================"

    if ($TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Transcript failure must not alter remediation exit code
        }
    }
}

Exit $ExitCode
