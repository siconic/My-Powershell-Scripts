# Intune Remediations - Remediation Script
# Creates the local account for Windows LAPS and adds it to the local
# Administrators group. Does nothing if the account already exists.
# Exit 0 = success, Exit 1 = failure

# Fill in before uploading to Intune. Left blank in the repository.
# The password is only the initial password; LAPS rotates it afterwards.
$NewName = ""
$InitialPassword = ""

if ([string]::IsNullOrWhiteSpace($NewName) -or [string]::IsNullOrEmpty($InitialPassword)) {
    Write-Output "Remediation failed: `$NewName and `$InitialPassword must be set in the script."
    exit 1
}

try {
    if (Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue) {
        # Account already exists, nothing to create
        Write-Output "Account '$NewName' already exists. No change made."
        exit 0
    }

    $Password = ConvertTo-SecureString $InitialPassword -AsPlainText -Force
    $User = New-LocalUser -Name $NewName -Password $Password -PasswordNeverExpires -AccountNeverExpires -Description "LAPS-managed admin" -ErrorAction Stop

    # make sure the account is enabled
    Enable-LocalUser -Name $NewName -ErrorAction Stop

    # S-1-5-32-544 is the built-in Administrators group (works on any language of Windows)
    $IsMember = @(Get-LocalGroupMember -SID "S-1-5-32-544" -ErrorAction Stop | Where-Object { $_.SID.Value -eq $User.SID.Value })
    if ($IsMember.Count -eq 0) {
        Add-LocalGroupMember -SID "S-1-5-32-544" -Member $NewName -ErrorAction Stop
    }

    Write-Output "Created account '$NewName' and added it to Administrators."
    exit 0
}
catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    exit 1
}
