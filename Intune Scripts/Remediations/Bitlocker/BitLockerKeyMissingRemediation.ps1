try {
    # Get BitLocker information for OS drive
        $BLVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
 
    # Verify BitLocker is enabled
    if ($BLVolume.ProtectionStatus -ne "On") {
        Write-Output "BitLocker protection is not enabled on the system drive."
        Exit 1
    }
 
    # Get Recovery Password protector
    $RecoveryProtector = $BLVolume.KeyProtector |
        Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
        Select-Object -First 1
 
    # Verify Recovery Password protector exists
    if (-not $RecoveryProtector) {
        Write-Output "Recovery Password protector not found."
        Exit 1
    }
 
    # Backup recovery key to Microsoft Entra ID

    BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $RecoveryProtector.KeyProtectorId
    Write-Output "BitLocker recovery key successfully backed up to Microsoft Entra ID."
    Exit 0
}

catch {
    Write-Output "Failed to back up BitLocker recovery key: $($_.Exception.Message)"
    Exit 1
}
 
