# Detection Script - Automatic Time Zone and Location Services

$LocationValue = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -ErrorAction SilentlyContinue

$TZAutoUpdate = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate" -Name "Start" -ErrorAction SilentlyContinue

if (($LocationValue -eq "Allow") -and ($TZAutoUpdate -eq 3))
{
    Write-Output "Compliant"
    Exit 0
}
else
{
    Write-Output "Non-Compliant"
    Exit 1
}
