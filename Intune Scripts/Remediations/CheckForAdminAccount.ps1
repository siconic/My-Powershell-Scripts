# Intune Remediations - Detection Script for CreateLAPSAdminAccount.ps1
# Exit 0 = account exists (compliant)
# Exit 1 = account missing or check failed (Intune runs the remediation)

# Fill in before uploading to Intune. Left blank in the repository.
$NewName = ""

if ([string]::IsNullOrWhiteSpace($NewName)) {
    Write-Output "Detection failed: `$NewName is not set in the script."
    exit 1
}

try {
    if (Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue) {
        Write-Output "Compliant: account '$NewName' exists."
        exit 0
    }
    Write-Output "Non-compliant: account '$NewName' does not exist."
    exit 1
}
catch {
    Write-Output "Detection failed: $($_.Exception.Message)"
    exit 1
}
