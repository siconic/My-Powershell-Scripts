#-------------------------------------------------
#  $success is the share of all machines in a list of whatever the success metric is
#
#-------------------------------------------------

$names = Get-Content "<computerList.txt>"
$ExportCSV = "<exportListName.csv>"
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Continue

$results = ForEach (name in $names) {
  $NSName = $null
  $NSIPArr = $null
  $NSLookup = $null
  $NSLookupIP = $null
  $RNSLookupName = $null
  $nsName = @()
  $nsIPArr = @()
  $TestCon = TestConnection -ComputerName $name -count 1 -ErrorAction SilentlyContinue
  $ADComp = Get-ADComputer $name -Properties * | Select-Object *
  $Success = Get-Content "\\<sharelocation>"
  $NetView = Invoke-Expression "net view $name" -ErrorVariable errorCode

  $nsLookup = [System.Net.DNS]::GetHostAddresses($name)
  If ($nsLookup -ne $null) {
      Foreach ($nslookupIP in $nslookup.IPAddressToString) {
          Try {$rnslookup = [System.Net.DNS]::GetHostEntry($NSLookupIP)
              $RNSLookupName = $rnsLookup.HostName
              $nsname += $RNSLookupName
              $nsIPArr += $nslookupIP
            }
          Catch {$rnslookup = "No Such Host"
              $nsname += $RNSLookupName
              $nsIPArr += $nslookupIP
            }
      }
  }
  Else {$NSName += "No IP"}

  If ($netview -like "*There are no entries*") {$SMBPing = "No Entries"}
  Elseif ($ErrorCode -like "*Access is denied*") {$SMBPing = "Access Denied"}
  Elseif ($ErrorCode -like "*error 53*") {$SMBPing = "No Network Path"}

  If ($success) {$migrated = "yes"}
  else {$migrated = "no"}

  If ($TestCon) {$Status = "Online"}
  else {$Status = "Offline"}

  [pscustomobject]@{
      "Name" = $ADComp.Name
      "LastLogon" = $ADComp.LastLogonDate
      "When Changed" = $ADComp.whenChanged
      "IP" = $TestCon.IPV4Address
      "Time(ms)" = $TestCon.ResponseTime
      "Status" = $Status
      "Migrated" = $Migrated
      "Net View Results" = $SMBPing
      "NSLookup IP" = NSIPArr | Out-String
      "NSLookup Machine Name" = $NSName | Out-String
  }
}

$Results | Export-CSV $ExportCSV -NoTypeInformation
