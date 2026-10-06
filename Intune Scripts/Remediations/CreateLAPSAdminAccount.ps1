$NewName  = ""
$Password = ConvertTo-SecureString "" -AsPlainText -Force

    if (Get-LocalUser -Name $NewName -ErrorAction SilentlyContinue) {
        # NewName already exists, nothing to rename or create
        exit 0
    }
    else {
        New-LocalUser -Name $NewName -Password $Password -PasswordNeverExpires $true -AccountNeverExpires $true -Description "LAPS-managed admin" -ErrorAction Stop

    	# make sure the account is enabled
    	Enable-LocalUser -Name $NewName -ErrorAction Stop

    	# S-1-5-32-544 is the built-in Administrators group (works on any language of Windows)
    	if (-not (Get-LocalGroupMember -SID "S-1-5-32-544" | Where-Object { $_.Name -like "*\$NewName" })) {
        	Add-LocalGroupMember -SID "S-1-5-32-544" -Member $NewName -ErrorAction Stop
    	}
    }

exit 0
