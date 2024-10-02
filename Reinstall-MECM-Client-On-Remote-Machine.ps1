#Requires PSAPPDeployToolkit, PSEXEC and MECM Client on share
#
#
#
#
#
#
#
#
#
#

cls

#Set Target Host
$Target = Read-Host -Prompt "Enter thw name of the remote computer"

#Set the version CB2303 or CB2211
$Version = "CB2211"

Write-Output "Checking Network Connectivity to $Target..."

If (Test-Connection -ComputerName $target -count 2 -Quiet) {
  Write-Output "$target responded to ICMP ping."
  }
Else { 
  Write-Output "$Target did not respond to ICMP Ping. Aborting MECM Client Install."
  Exit 1}

Write-Output "Atetmpting to confirm DNS reverse lookup is accurate..."

#REG Query Method - more reliable method
$Computername = Reg query "\\$target\HKLM\System\CurrentControlSet\Control\ComputerName\ComputerName" /v "ComputerName"

#Only proceed if response is as expected
if ($lastExitCode -eq "0") {
  if ($computername -like "*$target*") {
    Write-Output "Confirmed DNS Reverse Lookup is accurate."

    #Location to cache the install content
    $TargetDir = "C:\ProgramData\SoftwareCache\Microsoft_EndpointConfigManClient_" + $version + "_EN_01"

    #Run PSEXEC to cache the content
    Write-Output "Attempting to pre-stage the content on $Target..."
    Try {
      $ArgumentList = "-accepteula -nobanner -s \\" + $Target + " " + "C:\Windows\Systems32\robocopy.exe" + " " + "$PSScriptRoot" + " " + "$TargetDir" + " " + "/mir /XD SupportFiles /XF Reinstall-MECM-Client-On-Remote-Machine.ps1"
      Start-Process -FilePath "$PSScriptRoot\SupportFiles\PSexec.exe" -ArgumentList $ArgumentList -NoNewWindow -Wait
      }
    Catch {
      Write-Output "Unable to use PSEXEC to copy the MECM Client Install files with error:"
      Write-Output _$
      Write-Output "Aborting MECM client reinstall."
      Exit 4
      }

    #Final Chance to abort install
    cls
    Write-Output "MECM client files have been staged on $Target at $TargetDir."
    Write-Host "When the installation finishes, this Powershell winodw will CLOSE AUTOMATICALLY!" -Foregroundcolor "Red"
    Write-Output "Press and key to continue with re-installing the MECM client on $Target"
    Read-host -Prompt "Press CTRL+C to Abort!" | Out-Null

    #Run Psexec to do the re-install
    Try { 
      $ArgumentList = "-acceptEULA -nobanner \\" + $Target + " " + "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe -ExeccutionPolicy Bypass -File " + $TargetDir + "\Deploy-Application.ps1 -DeploymentType Repair"
      
