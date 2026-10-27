# Collect-EntraDeviceDiagnostics.ps1
# Read-only diagnostic collection for Microsoft Entra device registration,
# Primary Refresh Token, cached-token, and Microsoft 365 sign-in issues.
# Run while signed in as the affected user. Elevation is recommended but not required.

[CmdletBinding()]
param(
    [string]$OutputRoot = "\\<NetworkSharePath>",
    [int]$EventLookbackDays = 7,
    [switch]$IncludeGpResult
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerName = $env:COMPUTERNAME
$CollectionFolder = Join-Path $OutputRoot "EntraDiagnostics_${ComputerName}_${TimeStamp}"
$ZipPath = "${CollectionFolder}.zip"

function Save-Output {
    param([string]$Name, [scriptblock]$Command)
    $Path = Join-Path $CollectionFolder $Name
    try {
        & $Command 2>&1 | Out-String -Width 500 | Out-File $Path -Encoding UTF8
    }
    catch {
        "Collection failed: $($_.Exception.Message)" | Out-File $Path -Encoding UTF8
    }
}

function Get-DsregValue {
    param([string]$Name, [string]$Text)
    $Pattern = "(?m)^\s*" + [regex]::Escape($Name) + "\s*:\s*(.+?)\s*$"
    $Match = [regex]::Match($Text, $Pattern)
    if ($Match.Success) { return $Match.Groups[1].Value.Trim() }
    return "Not found"
}

# Verify the user can reach and write to the network share.
try {
    if (-not (Test-Path $OutputRoot)) {
        New-Item -Path $OutputRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $WriteTest = Join-Path $OutputRoot ".EntraWriteTest_$env:COMPUTERNAME_$PID.tmp"
    "Write test" | Out-File $WriteTest -Encoding ASCII -ErrorAction Stop
    Remove-Item $WriteTest -Force -ErrorAction Stop
    New-Item -Path $CollectionFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "Cannot write to $OutputRoot. Verify network connectivity and share/NTFS permissions. $($_.Exception.Message)"
    exit 1
}

$TranscriptStarted = $false
try {
    Start-Transcript -Path (Join-Path $CollectionFolder "CollectionTranscript.txt") -Force | Out-Null
    $TranscriptStarted = $true
}
catch {}

Write-Host "Collecting Entra diagnostics from $ComputerName..." -ForegroundColor Cyan
Write-Host "Output: $CollectionFolder" -ForegroundColor Cyan

Save-Output "01-CollectionContext.txt" {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    [pscustomobject]@{
        CollectionTime     = Get-Date
        ComputerName       = $env:COMPUTERNAME
        UserName           = $Identity.Name
        UserProfile        = $env:USERPROFILE
        PowerShellVersion  = $PSVersionTable.PSVersion.ToString()
        RunningElevated    = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        OutputFolder       = $CollectionFolder
        EventLookbackDays  = $EventLookbackDays
    } | Format-List
}

Save-Output "02-UserIdentity.txt" {
    "WHOAMI"; & whoami.exe
    "`r`nWHOAMI /UPN"; & whoami.exe /upn
    "`r`nWHOAMI /USER"; & whoami.exe /user
    "`r`nLOGON SERVER"; $env:LOGONSERVER
}

Save-Output "03-dsregcmd-status.txt" { & dsregcmd.exe /status }
Save-Output "04-dsregcmd-debug.txt" { & dsregcmd.exe /status /debug }

Save-Output "05-SystemInformation.txt" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, InstallDate, LastBootUpTime, LocalDateTime |
        Format-List
    Get-CimInstance Win32_ComputerSystem |
        Select-Object Name, Domain, PartOfDomain, DomainRole, Manufacturer, Model, UserName |
        Format-List
    Get-CimInstance Win32_BIOS |
        Select-Object Manufacturer, SMBIOSBIOSVersion, SerialNumber, ReleaseDate |
        Format-List
}

Save-Output "06-DomainConnectivity.txt" {
    if ($env:USERDNSDOMAIN) {
        "NLTEST /DSGETDC"; & nltest.exe "/dsgetdc:$env:USERDNSDOMAIN"
        "`r`nNLTEST /SC_VERIFY"; & nltest.exe "/sc_verify:$env:USERDNSDOMAIN"
    } else { "USERDNSDOMAIN is not populated." }
    "`r`nTEST-COMPUTERSECURECHANNEL"
    try { Test-ComputerSecureChannel -Verbose } catch { $_.Exception.Message }
}

Save-Output "07-IPConfig-All.txt" { & ipconfig.exe /all }
Save-Output "08-NetworkAdapters.txt" {
    Get-NetAdapter | Sort-Object InterfaceIndex |
        Format-Table Name, InterfaceDescription, Status, MacAddress, LinkSpeed, InterfaceIndex -AutoSize
}
Save-Output "09-IPConfiguration.txt" { Get-NetIPConfiguration -Detailed | Format-List }
Save-Output "10-DNSConfiguration.txt" { Get-DnsClientServerAddress | Sort-Object InterfaceIndex | Format-List }
Save-Output "11-RouteTable.txt" { & route.exe print }
Save-Output "12-ProxyConfiguration.txt" {
    "WINHTTP PROXY"; & netsh.exe winhttp show proxy
    "`r`nCURRENT USER INTERNET SETTINGS"
    Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue |
        Select-Object ProxyEnable, ProxyServer, AutoConfigURL, AutoDetect | Format-List
}

$Targets = @(
    "login.microsoftonline.com",
    "device.login.microsoftonline.com",
    "enterpriseregistration.windows.net",
    "autologon.microsoftazuread-sso.com",
    "enrollment.manage.microsoft.com"
)
$Connectivity = foreach ($Target in $Targets) {
    try {
        $Dns = Resolve-DnsName $Target -ErrorAction Stop | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress
        $Test = Test-NetConnection $Target -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
        [pscustomobject]@{
            Target=$Target; ResolvedAddresses=($Dns -join ", "); RemoteAddress=$Test.RemoteAddress
            Tcp443=$Test.TcpTestSucceeded; Interface=$Test.InterfaceAlias; SourceAddress=$Test.SourceAddress; Error=$null
        }
    }
    catch {
        [pscustomobject]@{
            Target=$Target; ResolvedAddresses=$null; RemoteAddress=$null
            Tcp443=$false; Interface=$null; SourceAddress=$null; Error=$_.Exception.Message
        }
    }
}
$Connectivity | Export-Csv (Join-Path $CollectionFolder "13-EntraEndpointConnectivity.csv") -NoTypeInformation -Encoding UTF8
$Connectivity | Format-Table -AutoSize | Out-String -Width 500 |
    Out-File (Join-Path $CollectionFolder "13-EntraEndpointConnectivity.txt") -Encoding UTF8

Save-Output "14-TimeSynchronization.txt" {
    "CURRENT TIME"; Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff K"
    "`r`nW32TM STATUS"; & w32tm.exe /query /status
    "`r`nW32TM SOURCE"; & w32tm.exe /query /source
    "`r`nW32TM CONFIGURATION"; & w32tm.exe /query /configuration
}

$RegistryTargets = @(
    @{Name="15-HKCU-AAD.txt"; Path="HKCU:\Software\Microsoft\Windows\CurrentVersion\AAD"},
    @{Name="16-IdentityStore.txt"; Path="HKLM:\SOFTWARE\Microsoft\IdentityStore"},
    @{Name="17-CloudDomainJoin.txt"; Path="HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin"},
    @{Name="18-WorkplaceJoin.txt"; Path="HKLM:\SYSTEM\CurrentControlSet\Control\WorkplaceJoin"},
    @{Name="19-WorkplaceJoinPolicy.txt"; Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin"}
)
foreach ($Item in $RegistryTargets) {
    $CurrentName = $Item.Name
    $CurrentPath = $Item.Path
    Save-Output $CurrentName {
        if (Test-Path $CurrentPath) {
            "ROOT: $CurrentPath"
            Get-ItemProperty $CurrentPath -ErrorAction SilentlyContinue | Format-List *
            Get-ChildItem $CurrentPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                "`r`nKEY: $($_.Name)"
                Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue | Format-List *
            }
        } else { "Path not found or inaccessible: $CurrentPath" }
    }.GetNewClosure()
}

Save-Output "20-CertificateMetadata.txt" {
    "LOCAL COMPUTER PERSONAL CERTIFICATES"
    Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey, EnhancedKeyUsageList | Format-List
    "`r`nCURRENT USER PERSONAL CERTIFICATES"
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter, HasPrivateKey, EnhancedKeyUsageList | Format-List
}

Save-Output "21-CredentialManagerTargets.txt" {
    "Target names and metadata only. Passwords and secrets are not collected."
    & cmdkey.exe /list
}

Save-Output "22-WorkplaceJoinScheduledTasks.txt" {
    Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -ErrorAction Stop | ForEach-Object {
        $Task = $_
        $Info = Get-ScheduledTaskInfo -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            TaskName=$Task.TaskName; State=$Task.State; LastRunTime=$Info.LastRunTime
            LastTaskResult=$Info.LastTaskResult; NextRunTime=$Info.NextRunTime
        }
    } | Format-Table -AutoSize
}

$StartTime = (Get-Date).AddDays(-$EventLookbackDays)
$Logs = @(
    @{Log="Microsoft-Windows-User Device Registration/Admin"; Name="Event-UserDeviceRegistration-Admin"},
    @{Log="Microsoft-Windows-AAD/Operational"; Name="Event-AAD-Operational"},
    @{Log="Microsoft-Windows-Workplace Join/Admin"; Name="Event-WorkplaceJoin-Admin"},
    @{Log="Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"; Name="Event-DeviceManagement-Admin"}
)
foreach ($Entry in $Logs) {
    $TextPath = Join-Path $CollectionFolder ($Entry.Name + ".txt")
    $CsvPath = Join-Path $CollectionFolder ($Entry.Name + ".csv")
    try {
        $Events = Get-WinEvent -FilterHashtable @{LogName=$Entry.Log; StartTime=$StartTime} -ErrorAction Stop
        $Events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, MachineName, Message |
            Format-List | Out-String -Width 500 | Out-File $TextPath -Encoding UTF8
        $Events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, MachineName, Message |
            Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
    }
    catch { "Unable to collect $($Entry.Log): $($_.Exception.Message)" | Out-File $TextPath -Encoding UTF8 }
}

if ($IncludeGpResult) {
    Save-Output "23-GPResult-Summary.txt" {
        & gpresult.exe /r /scope user
        & gpresult.exe /r /scope computer
    }
    & gpresult.exe /h (Join-Path $CollectionFolder "23-GPResult.html") /f 2>&1 |
        Out-File (Join-Path $CollectionFolder "23-GPResult-Status.txt") -Encoding UTF8
}

$DsregText = Get-Content (Join-Path $CollectionFolder "03-dsregcmd-status.txt") -Raw
$AzureAdJoined = Get-DsregValue "AzureAdJoined" $DsregText
$DomainJoined = Get-DsregValue "DomainJoined" $DsregText
$WorkplaceJoined = Get-DsregValue "WorkplaceJoined" $DsregText
$DeviceId = Get-DsregValue "DeviceId" $DsregText
$TenantId = Get-DsregValue "TenantId" $DsregText
$TenantName = Get-DsregValue "TenantName" $DsregText
$DeviceAuthStatus = Get-DsregValue "DeviceAuthStatus" $DsregText
$AzureAdPrt = Get-DsregValue "AzureAdPrt" $DsregText
$PrtUpdate = Get-DsregValue "AzureAdPrtUpdateTime" $DsregText
$PrtExpiry = Get-DsregValue "AzureAdPrtExpiryTime" $DsregText
$WamDefaultSet = Get-DsregValue "WamDefaultSet" $DsregText

$Findings = New-Object System.Collections.Generic.List[string]
if ($AzureAdJoined -eq "NO" -and $DomainJoined -eq "YES") { $Findings.Add("WARNING: Domain joined, but AzureAdJoined is NO.") }
if ($AzureAdPrt -eq "NO") { $Findings.Add("WARNING: AzureAdPrt is NO. Microsoft 365 SSO or token renewal may be affected.") }
if ($DeviceAuthStatus -match "FAILED|ERROR") { $Findings.Add("WARNING: DeviceAuthStatus is $DeviceAuthStatus. Verify DeviceId $DeviceId in Entra ID.") }
if ($WorkplaceJoined -eq "YES" -and $AzureAdJoined -eq "YES") { $Findings.Add("REVIEW: WorkplaceJoined and AzureAdJoined both report YES.") }
if ($Connectivity | Where-Object { -not $_.Tcp443 }) { $Findings.Add("WARNING: One or more identity endpoints failed TCP 443 testing.") }
if ($Findings.Count -eq 0) { $Findings.Add("No obvious failure was identified. Review the detailed logs and Entra sign-in event.") }

try { $UserUpn = (& whoami.exe /upn 2>$null | Out-String).Trim() } catch { $UserUpn = "Unavailable" }
@"
MICROSOFT ENTRA DEVICE DIAGNOSTIC SUMMARY
=========================================
Collection time:       $(Get-Date)
Computer:              $env:COMPUTERNAME
Signed-in user:        $env:USERDOMAIN\$env:USERNAME
User UPN:              $UserUpn
Output location:       $CollectionFolder

DEVICE AND USER STATE
---------------------
AzureAdJoined:         $AzureAdJoined
DomainJoined:          $DomainJoined
WorkplaceJoined:       $WorkplaceJoined
DeviceId:              $DeviceId
TenantId:              $TenantId
TenantName:            $TenantName
DeviceAuthStatus:      $DeviceAuthStatus
AzureAdPrt:            $AzureAdPrt
AzureAdPrtUpdateTime:  $PrtUpdate
AzureAdPrtExpiryTime:  $PrtExpiry
WamDefaultSet:         $WamDefaultSet

AUTOMATED FINDINGS
------------------
$($Findings -join "`r`n")

NEXT CHECKS
-----------
1. Search Entra ID Devices for DeviceId: $DeviceId
2. Confirm the device exists, is enabled, and is in the expected tenant.
3. Compare this collection time with the Entra sign-in error, correlation ID, request ID, application, and Conditional Access result.
4. Preserve this collection before disconnecting the work account, clearing credentials, deleting certificates, or running dsregcmd /leave.

DATA HANDLING
-------------
This package can contain usernames, UPNs, hostnames, tenant and device IDs,
IP addresses, certificate metadata, domain information, and event messages.
Handle it according to organizational data-classification requirements.
"@ | Out-File (Join-Path $CollectionFolder "00-READ-ME-Summary.txt") -Encoding UTF8

if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }

try {
    Compress-Archive -Path (Join-Path $CollectionFolder "*") -DestinationPath $ZipPath -CompressionLevel Optimal -Force
    Write-Host "Collection completed successfully." -ForegroundColor Green
    Write-Host "ZIP: $ZipPath" -ForegroundColor Green
}
catch {
    Write-Warning "Collection completed, but ZIP creation failed: $($_.Exception.Message)"
    Write-Host "Folder: $CollectionFolder"
}
