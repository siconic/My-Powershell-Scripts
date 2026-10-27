# =====================================================================
# Intune Remediations - Detection Script
# Purpose:
#   - Check whether desired account exists
#   - Check whether desired account is a Local Administrator
#
# Exit 0 = Compliant
# Exit 1 = Non-Compliant
# =====================================================================

$ErrorActionPreference = "Stop"

$AccountName = "test"
$AdministratorsSID = "S-1-5-32-544"

try {

    # ---------------------------------------------------------------
    # Check whether local account exists
    # ---------------------------------------------------------------

    $LocalUser = Get-LocalUser `
        -Name $AccountName `
        -ErrorAction SilentlyContinue

    if ($null -eq $LocalUser) {

        Write-Output "Non-Compliant: Local account '$AccountName' does not exist."
        Exit 1
    }

    # ---------------------------------------------------------------
    # Check Local Administrators membership
    # ---------------------------------------------------------------

    $AdminMembers = Get-LocalGroupMember `
        -SID $AdministratorsSID `
        -ErrorAction Stop

    $IsAdministrator = $AdminMembers | Where-Object {
        $_.SID.Value -eq $LocalUser.SID.Value
    }

    if ($null -eq $IsAdministrator) {

        Write-Output "Non-Compliant: '$AccountName' exists but is not a member of Local Administrators."
        Exit 1
    }

    # ---------------------------------------------------------------
    # Compliant
    # ---------------------------------------------------------------

    Write-Output "Compliant: '$AccountName' exists and is a member of Local Administrators."
    Exit 0

}
catch {

    Write-Output "Detection failed: $($_.Exception.Message)"
    Exit 1
}
