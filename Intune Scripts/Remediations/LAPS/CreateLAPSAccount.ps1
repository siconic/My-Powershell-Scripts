# =====================================================================
# Intune Remediations - Remediation Script
#
# Purpose:
#   - Create local account if it does not exist
#   - Configure initial/bootstrap password during creation
#   - Add newly created account to Local Administrators
#   - NEVER reset password when account already exists
#
# Log:
#   C:\ProgramData\Logs\localaccountcreation\LocalAccountCreation.log
#
# Exit 0 = Successful
# Exit 1 = Failed
# =====================================================================

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

$AccountName = "test"

# Bootstrap password used ONLY during initial account creation
$InitialPassword = "testpassword1234"

$Description = "LAPS-managed Admin Account"

# Built-in Administrators group
$AdministratorsSID = "S-1-5-32-544"

# Logging
$LogFolder = "C:\ProgramData\Logs\localaccountcreation"
$LogFile = Join-Path $LogFolder "LocalAccountCreation.log"


# =====================================================================
# Create Log Folder
# =====================================================================

try {

    if (-not (Test-Path -LiteralPath $LogFolder)) {

        New-Item `
            -Path $LogFolder `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop | Out-Null
    }

}
catch {

    Write-Output "Unable to create log folder: $($_.Exception.Message)"
    Exit 1
}


# =====================================================================
# Logging Function
# =====================================================================

function Write-Log {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $LogEntry = "$Timestamp | $Message"

    Write-Output $LogEntry

    try {

        Add-Content `
            -LiteralPath $LogFile `
            -Value $LogEntry `
            -Encoding UTF8 `
            -ErrorAction Stop

    }
    catch {

        Write-Output "WARNING: Unable to write to log file."
    }
}


# =====================================================================
# Start Remediation
# =====================================================================

Write-Log "============================================================"
Write-Log "LOCAL ACCOUNT CREATION REMEDIATION STARTED"
Write-Log "============================================================"

Write-Log "Computer Name : $env:COMPUTERNAME"
Write-Log "Account Name  : $AccountName"

try {

    # =================================================================
    # Check account
    # =================================================================

    Write-Log "------------------------------------------------------------"
    Write-Log "Checking whether '$AccountName' exists."

    $LocalUser = Get-LocalUser `
        -Name $AccountName `
        -ErrorAction SilentlyContinue


    # =================================================================
    # Create account if missing
    # =================================================================

    if ($null -eq $LocalUser) {

        Write-Log "Account Status : NOT PRESENT"
        Write-Log "Action         : Creating '$AccountName'."

        # Convert bootstrap password to SecureString
        $SecurePassword = ConvertTo-SecureString `
            -String $InitialPassword `
            -AsPlainText `
            -Force

        try {

            New-LocalUser `
                -Name $AccountName `
                -Password $SecurePassword `
                -Description $Description `
                -AccountNeverExpires `
                -PasswordNeverExpires `
                -ErrorAction Stop | Out-Null

            Write-Log "Account Creation : SUCCESS"

        }
        catch {

            Write-Log "Account Creation : FAILED"
            Write-Log "Error Message    : $($_.Exception.Message)"
            Write-Log "Exception Type   : $($_.Exception.GetType().FullName)"
            Write-Log "Error ID         : $($_.FullyQualifiedErrorId)"
            Write-Log "Script Line      : $($_.InvocationInfo.ScriptLineNumber)"

            throw
        }


        # -------------------------------------------------------------
        # Verify account exists after creation
        # -------------------------------------------------------------

        $LocalUser = Get-LocalUser `
            -Name $AccountName `
            -ErrorAction SilentlyContinue

        if ($null -eq $LocalUser) {

            throw "Account '$AccountName' could not be found after creation."
        }

        Write-Log "Account Validation : PASS"
        Write-Log "Account SID        : $($LocalUser.SID.Value)"
        Write-Log "Account Enabled    : $($LocalUser.Enabled)"
        Write-Log "Password           : Bootstrap password successfully configured."
        Write-Log "Password Value     : NOT LOGGED"

    }
    else {

        # =============================================================
        # Account already exists
        # =============================================================

        Write-Log "Account Status  : PRESENT"
        Write-Log "Account SID     : $($LocalUser.SID.Value)"
        Write-Log "Account Enabled : $($LocalUser.Enabled)"

        # IMPORTANT:
        # Never reset password for an existing account.
        # Windows LAPS may already have rotated the password.

        Write-Log "Password Action : NOT MODIFIED"
        Write-Log "Reason          : Account already exists."
    }


    # =================================================================
    # Ensure Account Is Enabled
    # =================================================================

    if (-not $LocalUser.Enabled) {

        Write-Log "------------------------------------------------------------"
        Write-Log "Account Status : DISABLED"
        Write-Log "Action         : Enabling '$AccountName'."

        Enable-LocalUser `
            -Name $AccountName `
            -ErrorAction Stop

        Write-Log "Enable Account : SUCCESS"

        # Refresh account information
        $LocalUser = Get-LocalUser `
            -Name $AccountName `
            -ErrorAction Stop
    }
    else {

        Write-Log "Account Enabled : YES"
    }


    # =================================================================
    # Check Local Administrators Membership
    # =================================================================

    Write-Log "------------------------------------------------------------"
    Write-Log "Checking Local Administrators membership."

    $AdminMembers = Get-LocalGroupMember `
        -SID $AdministratorsSID `
        -ErrorAction Stop

    $AdminMember = $AdminMembers | Where-Object {
        $_.SID.Value -eq $LocalUser.SID.Value
    }


    # =================================================================
    # Add To Local Administrators
    # =================================================================

    if ($null -eq $AdminMember) {

        Write-Log "Admin Membership : NOT PRESENT"
        Write-Log "Action           : Adding '$AccountName' to Local Administrators."

        Add-LocalGroupMember `
            -SID $AdministratorsSID `
            -Member $AccountName `
            -ErrorAction Stop

        Write-Log "Admin Membership : ADDED SUCCESSFULLY"

    }
    else {

        Write-Log "Admin Membership : PRESENT"
        Write-Log "Action           : No change required"
    }


    # =================================================================
    # Final Validation
    # =================================================================

    Write-Log "------------------------------------------------------------"
    Write-Log "Performing final validation."

    $FinalUser = Get-LocalUser `
        -Name $AccountName `
        -ErrorAction Stop

    $FinalAdminMembers = Get-LocalGroupMember `
        -SID $AdministratorsSID `
        -ErrorAction Stop

    $FinalAdminMember = $FinalAdminMembers | Where-Object {
        $_.SID.Value -eq $FinalUser.SID.Value
    }


    if (-not $FinalUser.Enabled) {

        throw "Final validation failed: '$AccountName' is disabled."
    }


    if ($null -eq $FinalAdminMember) {

        throw "Final validation failed: '$AccountName' is not a Local Administrator."
    }


    # =================================================================
    # Final Success
    # =================================================================

    Write-Log "------------------------------------------------------------"
    Write-Log "FINAL VALIDATION"
    Write-Log "------------------------------------------------------------"

    Write-Log "Account Exists      : YES"
    Write-Log "Account Name        : $($FinalUser.Name)"
    Write-Log "Account SID         : $($FinalUser.SID.Value)"
    Write-Log "Account Enabled     : YES"
    Write-Log "Local Administrator : YES"

    Write-Log "------------------------------------------------------------"
    Write-Log "RESULT    : SUCCESS"
    Write-Log "Exit Code : 0"
    Write-Log "============================================================"

    Exit 0

}
catch {

    # =================================================================
    # Failure
    # =================================================================

    Write-Log "------------------------------------------------------------"
    Write-Log "RESULT         : FAILED"
    Write-Log "Error Message  : $($_.Exception.Message)"
    Write-Log "Exception Type : $($_.Exception.GetType().FullName)"
    Write-Log "Error ID       : $($_.FullyQualifiedErrorId)"
    Write-Log "Script Line    : $($_.InvocationInfo.ScriptLineNumber)"
    Write-Log "Exit Code      : 1"
    Write-Log "============================================================"

    Exit 1
}
