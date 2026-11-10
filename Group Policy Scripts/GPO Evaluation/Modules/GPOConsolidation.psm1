#Requires -Version 5.1
<#
GPOConsolidation.psm1
Version 2.0

Helper functions for New-GpoConsolidationPlan.ps1:
- reading Compare-GPOXml.ps1 and Compare-GPOHtml.ps1 output (workbook or
  CSV folder),
- turning settings into comparable keys and values (GPO XML and GPResult
  HTML name the same setting differently),
- the Intune columns (policy name, "Migrate to Intune?", derived firewall
  mappings, suspect mappings),
- the configuration files (GpoRoles.csv, ConsolidationRules.json),
- writing the Excel workbook.

Changelog
2.0  No changes to this module. Moved into the Modules folder; version
     kept in lockstep with New-GpoConsolidationPlan.ps1.
1.0  First version.
#>

Set-StrictMode -Off

#=====================================================
# Name tables
#=====================================================

# Security setting names. GPO XML exports use internal names
# (MinimumPasswordAge, SeNetworkLogonRight); gpresult /h reports use display
# names. Both are turned into the names below.
$script:SecurityNames = @{
    # Account policies (XML names)
    MinimumPasswordAge                       = 'Minimum password age (days)'
    MaximumPasswordAge                       = 'Maximum password age (days)'
    MinimumPasswordLength                    = 'Minimum password length'
    PasswordHistorySize                      = 'Enforce password history'
    PasswordComplexity                       = 'Password must meet complexity requirements'
    ClearTextPassword                        = 'Store passwords using reversible encryption'
    LockoutBadCount                          = 'Account lockout threshold (attempts)'
    LockoutDuration                          = 'Account lockout duration (minutes)'
    ResetLockoutCount                        = 'Reset account lockout counter after (minutes)'
    AllowAdministratorLockout                = 'Allow Administrator account lockout'
    MaxClockSkew                             = 'Kerberos: Max tolerance for clock sync (minutes)'
    MaxRenewAge                              = 'Kerberos: Max lifetime for ticket renewal (days)'
    MaxServiceAge                            = 'Kerberos: Max lifetime for service ticket (minutes)'
    MaxTicketAge                             = 'Kerberos: Max lifetime for user ticket (hours)'
    TicketValidateClient                     = 'Kerberos: Enforce user logon restrictions'
    RelaxMinimumPasswordLengthLimits         = 'Relax minimum password length limits'

    # Account policies (gpresult /h names)
    'Minimum password age'                   = 'Minimum password age (days)'
    'Maximum password age'                   = 'Maximum password age (days)'
    'Account lockout threshold'              = 'Account lockout threshold (attempts)'
    'Account lockout duration'               = 'Account lockout duration (minutes)'
    'Reset account lockout counter after'    = 'Reset account lockout counter after (minutes)'
    'Maximum tolerance for computer clock synchronization' = 'Kerberos: Max tolerance for clock sync (minutes)'
    'Maximum lifetime for user ticket renewal' = 'Kerberos: Max lifetime for ticket renewal (days)'
    'Maximum lifetime for service ticket'    = 'Kerberos: Max lifetime for service ticket (minutes)'
    'Maximum lifetime for user ticket'       = 'Kerberos: Max lifetime for user ticket (hours)'
    'Enforce user logon restrictions'        = 'Kerberos: Enforce user logon restrictions'

    # Security options (XML names)
    EnableGuestAccount                       = 'Accounts: Guest account status'
    EnableAdminAccount                       = 'Accounts: Administrator account status'
    ForceLogoffWhenHourExpire                = 'Network security: Force logoff when logon hours expire'
    LSAAnonymousNameLookup                   = 'Network access: Allow anonymous SID/Name translation'
    NewAdministratorName                     = 'Accounts: Rename administrator account'
    NewGuestName                             = 'Accounts: Rename guest account'

    # User rights assignment
    SeTrustedCredManAccessPrivilege          = 'Access Credential Manager as a trusted caller'
    SeNetworkLogonRight                      = 'Access this computer from the network'
    SeTcbPrivilege                           = 'Act as part of the operating system'
    SeMachineAccountPrivilege                = 'Add workstations to domain'
    SeIncreaseQuotaPrivilege                 = 'Adjust memory quotas for a process'
    SeInteractiveLogonRight                  = 'Allow log on locally'
    SeRemoteInteractiveLogonRight            = 'Allow log on through Terminal Services'
    SeBackupPrivilege                        = 'Back up files and directories'
    SeChangeNotifyPrivilege                  = 'Bypass traverse checking'
    SeSystemtimePrivilege                    = 'Change the system time'
    SeTimeZonePrivilege                      = 'Change the time zone'
    SeCreatePagefilePrivilege                = 'Create a pagefile'
    SeCreateTokenPrivilege                   = 'Create a token object'
    SeCreateGlobalPrivilege                  = 'Create global objects'
    SeCreatePermanentPrivilege               = 'Create permanent shared objects'
    SeCreateSymbolicLinkPrivilege            = 'Create symbolic links'
    SeDebugPrivilege                         = 'Debug programs'
    SeDenyNetworkLogonRight                  = 'Deny access to this computer from the network'
    SeDenyBatchLogonRight                    = 'Deny log on as a batch job'
    SeDenyServiceLogonRight                  = 'Deny log on as a service'
    SeDenyInteractiveLogonRight              = 'Deny log on locally'
    SeDenyRemoteInteractiveLogonRight        = 'Deny log on through Terminal Services'
    SeEnableDelegationPrivilege              = 'Enable computer and user accounts to be trusted for delegation'
    SeRemoteShutdownPrivilege                = 'Force shutdown from a remote system'
    SeAuditPrivilege                         = 'Generate security audits'
    SeImpersonatePrivilege                   = 'Impersonate a client after authentication'
    SeIncreaseWorkingSetPrivilege            = 'Increase a process working set'
    SeIncreaseBasePriorityPrivilege          = 'Increase scheduling priority'
    SeLoadDriverPrivilege                    = 'Load and unload device drivers'
    SeLockMemoryPrivilege                    = 'Lock pages in memory'
    SeBatchLogonRight                        = 'Log on as a batch job'
    SeServiceLogonRight                      = 'Log on as a service'
    SeSecurityPrivilege                      = 'Manage auditing and security log'
    SeRelabelPrivilege                       = 'Modify an object label'
    SeSystemEnvironmentPrivilege             = 'Modify firmware environment values'
    SeDelegateSessionUserImpersonatePrivilege = 'Obtain an impersonation token for another user in the same session'
    SeManageVolumePrivilege                  = 'Perform volume maintenance tasks'
    SeProfileSingleProcessPrivilege          = 'Profile single process'
    SeSystemProfilePrivilege                 = 'Profile system performance'
    SeUndockPrivilege                        = 'Remove computer from docking station'
    SeAssignPrimaryTokenPrivilege            = 'Replace a process level token'
    SeRestorePrivilege                       = 'Restore files and directories'
    SeShutdownPrivilege                      = 'Shut down the system'
    SeSyncAgentPrivilege                     = 'Synchronize directory service data'
    SeTakeOwnershipPrivilege                 = 'Take ownership of files or other objects'

    # gpresult /h spelling of two rights
    'Allow log on through Remote Desktop Services' = 'Allow log on through Terminal Services'
    'Deny log on through Remote Desktop Services'  = 'Deny log on through Terminal Services'
}

# Windows Defender Firewall CSP setting per firewall profile key. {P} is
# replaced by the profile name (Domain, Private, Public).
$script:FirewallCspNames = @{
    AllowLocalIPsecPolicyMerge                  = 'Allow Local Ipsec Policy Merge'
    AllowLocalPolicyMerge                       = 'Allow Local Policy Merge'
    DefaultInboundAction                        = 'Default Inbound Action for {P} Profile'
    DefaultOutboundAction                       = 'Default Outbound Action'
    DisableNotifications                        = 'Disable Inbound Notifications'
    DisableUnicastResponsesToMulticastBroadcast = 'Disable Unicast Responses To Multicast Broadcast'
    EnableFirewall                              = 'Enable {P} Network Firewall'
    LogDroppedPackets                           = 'Enable Log Dropped Packets'
    LogFilePath                                 = 'Log File Path'
    LogFileSize                                 = 'Log Max File Size'
    LogSuccessfulConnections                    = 'Enable Log Success Connections'
}

# Advanced audit policy: subcategory -> category.
$script:AuditCategories = @{
    'Credential Validation'                  = 'Account Logon'
    'Kerberos Authentication Service'        = 'Account Logon'
    'Kerberos Service Ticket Operations'     = 'Account Logon'
    'Other Account Logon Events'             = 'Account Logon'
    'Application Group Management'           = 'Account Management'
    'Computer Account Management'            = 'Account Management'
    'Distribution Group Management'          = 'Account Management'
    'Other Account Management Events'        = 'Account Management'
    'Security Group Management'              = 'Account Management'
    'User Account Management'                = 'Account Management'
    'DPAPI Activity'                         = 'Detailed Tracking'
    'PNP Activity'                           = 'Detailed Tracking'
    'Process Creation'                       = 'Detailed Tracking'
    'Process Termination'                    = 'Detailed Tracking'
    'RPC Events'                             = 'Detailed Tracking'
    'Token Right Adjusted Events'            = 'Detailed Tracking'
    'Detailed Directory Service Replication' = 'DS Access'
    'Directory Service Access'               = 'DS Access'
    'Directory Service Changes'              = 'DS Access'
    'Directory Service Replication'          = 'DS Access'
    'Account Lockout'                        = 'Logon/Logoff'
    'User / Device Claims'                   = 'Logon/Logoff'
    'Group Membership'                       = 'Logon/Logoff'
    'IPsec Extended Mode'                    = 'Logon/Logoff'
    'IPsec Main Mode'                        = 'Logon/Logoff'
    'IPsec Quick Mode'                       = 'Logon/Logoff'
    'Logoff'                                 = 'Logon/Logoff'
    'Logon'                                  = 'Logon/Logoff'
    'Network Policy Server'                  = 'Logon/Logoff'
    'Other Logon/Logoff Events'              = 'Logon/Logoff'
    'Special Logon'                          = 'Logon/Logoff'
    'Application Generated'                  = 'Object Access'
    'Certification Services'                 = 'Object Access'
    'Detailed File Share'                    = 'Object Access'
    'File Share'                             = 'Object Access'
    'File System'                            = 'Object Access'
    'Filtering Platform Connection'          = 'Object Access'
    'Filtering Platform Packet Drop'         = 'Object Access'
    'Handle Manipulation'                    = 'Object Access'
    'Kernel Object'                          = 'Object Access'
    'Other Object Access Events'             = 'Object Access'
    'Registry'                               = 'Object Access'
    'Removable Storage'                      = 'Object Access'
    'SAM'                                    = 'Object Access'
    'Central Policy Staging'                 = 'Object Access'
    'Audit Policy Change'                    = 'Policy Change'
    'Authentication Policy Change'           = 'Policy Change'
    'Authorization Policy Change'            = 'Policy Change'
    'Filtering Platform Policy Change'       = 'Policy Change'
    'MPSSVC Rule-Level Policy Change'        = 'Policy Change'
    'Other Policy Change Events'             = 'Policy Change'
    'Non Sensitive Privilege Use'            = 'Privilege Use'
    'Other Privilege Use Events'             = 'Privilege Use'
    'Sensitive Privilege Use'                = 'Privilege Use'
    'IPsec Driver'                           = 'System'
    'Other System Events'                    = 'System'
    'Security State Change'                  = 'System'
    'Security System Extension'              = 'System'
    'System Integrity'                       = 'System'
}

#=====================================================
# Small helpers
#=====================================================

function Test-GcWildcard
{
    # True when Text matches any of the wildcard patterns (case ignored).
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][object[]]$Patterns
    )

    foreach ($Pattern in @($Patterns))
    {
        if ([string]::IsNullOrWhiteSpace("$Pattern"))
        {
            continue
        }

        if ("$Text" -like "$Pattern")
        {
            return $true
        }
    }

    return $false
}

function Get-GcBaseGpoName
{
    # "SITEA- Windows 11 Workstation Policy" -> "Windows 11 Workstation Policy".
    # A leading word ending in "-" followed by a space is treated as a site
    # prefix. Other names are returned unchanged.
    param([string]$Name)

    return ($Name -replace '^\S+-\s+', '')
}

function Get-GcLetters
{
    # Lower-case letters and digits only (used to compare names loosely).
    param([string]$Text)

    return (("$Text").ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Get-GcSimilarity
{
    # Dice coefficient of the letter pairs of two strings (0 to 1).
    param([string]$A, [string]$B)

    $A = Get-GcLetters $A
    $B = Get-GcLetters $B

    if (($A.Length -lt 2) -or ($B.Length -lt 2))
    {
        if ($A -eq $B) { return 1.0 } else { return 0.0 }
    }

    $Pairs = @{}

    for ($i = 0; $i -lt ($A.Length - 1); $i++)
    {
        $Pair = $A.Substring($i, 2)

        if ($Pairs.ContainsKey($Pair)) { $Pairs[$Pair]++ } else { $Pairs[$Pair] = 1 }
    }

    $Shared = 0

    for ($i = 0; $i -lt ($B.Length - 1); $i++)
    {
        $Pair = $B.Substring($i, 2)

        if ($Pairs.ContainsKey($Pair) -and ($Pairs[$Pair] -gt 0))
        {
            $Shared++
            $Pairs[$Pair]--
        }
    }

    return ((2.0 * $Shared) / (($A.Length - 1) + ($B.Length - 1)))
}

#=====================================================
# Setting normalization
#=====================================================

function Get-GcAdminTemplateValue
{
    # Cleans the Administrative Template value blob of a GPO XML export:
    #   "Opt:=x | Text=... | q4:Name=.. | q4:State=Enabled | q4:Explain=.. | .."
    # becomes "Enabled; Opt:=x". Values without a qN:State part are returned
    # unchanged.
    param([string]$Value)

    if ($Value -notmatch '(^|\|\s*)q\d+:State=')
    {
        return $Value
    }

    $State   = ''
    $Options = [System.Collections.ArrayList]::new()
    $InOptions = $true

    foreach ($Part in ($Value -split '\s\|\s'))
    {
        $Trimmed = $Part.Trim()

        if ($Trimmed -match '^q\d+:State=(.*)$')
        {
            $State = $Matches[1].Trim()
        }

        if ($Trimmed -match '^q\d+:')
        {
            $InOptions = $false
            continue
        }

        if ($InOptions -and ($Trimmed -ne '') -and ($Trimmed -notmatch '^Text='))
        {
            [void]$Options.Add($Trimmed)
        }
    }

    if ($Options.Count -eq 0)
    {
        return $State
    }

    return "$($State); $(@($Options) -join '; ')"
}

function Get-GcSortedList
{
    # "b; a; c" -> "a; b; c" (user rights and other account lists).
    param([string]$Value)

    $Items = @($Value -split ';\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    if ($Items.Count -lt 2)
    {
        return $Value
    }

    return (@($Items | Sort-Object) -join '; ')
}

function ConvertTo-GcSetting
{
    <#
    Turns one ParsedSettings row (Compare-GPOXml.ps1 or Compare-GPOHtml.ps1
    output) into a setting record with a comparison key:

        Key = Class | Area | Category | Name

    Category is left out of the key for Security and Advanced Audit Policy
    settings, because GPO XML and gpresult /h group them differently.
    #>
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string]$GpoName,
        [Parameter(Mandatory)][ValidateSet('XML', 'HTML')][string]$Source,
        [string]$ReportName = ''
    )

    $Class     = "$($Row.Class)"
    $Extension = "$($Row.Extension)"
    $Category  = "$($Row.Category)"
    $RawName   = "$($Row.SettingName)"
    $Value     = "$($Row.Value)"
    $Area      = $Extension

    if ($Source -eq 'HTML')
    {
        $Value = [System.Net.WebUtility]::HtmlDecode($Value)
        $RawName = [System.Net.WebUtility]::HtmlDecode($RawName)

        if ($Extension -eq 'Security Settings')
        {
            $First = ($Category -split '\s+/\s+')[0]

            if ($First -like 'Advanced Audit Configuration*')
            {
                $Area = 'Advanced Audit Policy'
                $Category = ($Category -replace '^Advanced Audit Configuration\s*/?\s*', '')
                $Value = ($Value -replace '^\s*Success,\s*Failure\s*$', 'Success and Failure')
            }
            elseif ($First -like 'Public Key Policies*')
            {
                $Area = 'Public Key Policies'
            }
            elseif ($First -like 'Wireless Network*')
            {
                $Area = 'Wireless Network Policies'
            }
            elseif ($First -like 'Windows Firewall*')
            {
                $Area = 'Windows Firewall'
            }
            else
            {
                $Area = 'Security'
                $Category = (($Category -split '\s*/\s*') | Select-Object -Last 1)
                $Category = ($Category -replace ' Policy$', '' -replace ' Assignment$', ' Assignment')
            }
        }
    }

    # Name: strip "qN:" prefixes; security names to display names.
    $Name = ($RawName -replace '^q\d+:', '')

    if (($Area -eq 'Security') -and $script:SecurityNames.ContainsKey($Name))
    {
        $Name = $script:SecurityNames[$Name]
    }

    # Value
    if ($Area -eq 'Administrative Templates')
    {
        $Value = Get-GcAdminTemplateValue -Value $Value
    }

    if (($Area -eq 'Security') -and (($Category -eq 'User Rights Assignment') -or ($RawName -like 'Se*Privilege') -or ($RawName -like 'Se*Right')))
    {
        $Value = Get-GcSortedList -Value $Value
    }

    $Value = $Value.Trim()

    # Category (spaces around "/" removed so XML and HTML paths match).
    $Category = ($Category -replace '\s*/\s*', '/').Trim()

    $KeyCategory = $Category

    if (($Area -eq 'Security') -or ($Area -eq 'Advanced Audit Policy'))
    {
        $KeyCategory = ''
    }

    return [PSCustomObject]@{
        GPOName    = $GpoName
        Source     = $Source
        ReportName = $ReportName
        Class      = $Class
        Extension  = $Extension
        Area       = $Area
        Category   = $Category
        RawCategory = "$($Row.Category)"
        Name       = $Name
        RawName    = $RawName
        Value      = $Value
        Key        = "$($Class)|$($Area)|$($KeyCategory)|$($Name)".ToLowerInvariant()
    }
}

#=====================================================
# Input files
#=====================================================

function Get-GcSheetRows
{
    # Rows of one worksheet of a workbook, or of "<prefix><Name>.csv" in a
    # folder. Returns nothing when the sheet or file does not exist.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (Test-Path -LiteralPath $Path -PathType Container)
    {
        $File = @(Get-ChildItem -LiteralPath $Path -File -Filter "*$($Name).csv" | Sort-Object { $_.Name.Length }) | Select-Object -First 1

        if ($null -eq $File)
        {
            return @()
        }

        return @(Import-Csv -LiteralPath $File.FullName -Encoding UTF8)
    }

    $Sheets = @(Get-ExcelSheetInfo -Path $Path | ForEach-Object { $_.Name })

    if ($Sheets -notcontains $Name)
    {
        return @()
    }

    return @(Import-Excel -Path $Path -WorksheetName $Name)
}

function Import-GcCompareOutput
{
    <#
    Reads one Compare-GPOXml.ps1 or Compare-GPOHtml.ps1 output (an .xlsx
    workbook or a folder of CSV files). Returns:
        Path, Type (XML or HTML), Parsed, Candidates, FirewallRules
    #>
    param([Parameter(Mandatory)][string]$Path)

    $Parsed = @(Get-GcSheetRows -Path $Path -Name 'ParsedSettings')

    if ($Parsed.Count -eq 0)
    {
        throw "No ParsedSettings found in '$Path'."
    }

    $Columns = @($Parsed[0].PSObject.Properties.Name)

    if ($Columns -contains 'GPOName')
    {
        $Type = 'XML'
    }
    elseif (($Columns -contains 'ReportName') -and ($Columns -contains 'WinningGPO'))
    {
        $Type = 'HTML'
    }
    else
    {
        throw "ParsedSettings in '$Path' has neither a GPOName column (XML) nor ReportName and WinningGPO columns (HTML)."
    }

    return [PSCustomObject]@{
        Path          = $Path
        Type          = $Type
        Parsed        = $Parsed
        Candidates    = @(Get-GcSheetRows -Path $Path -Name 'IntuneMigrationCandidates')
        FirewallRules = @(Get-GcSheetRows -Path $Path -Name 'FirewallRules')
    }
}

function Resolve-GcHtmlWinningGpo
{
    <#
    gpresult /h shows some sections (wireless, file system, registry) with a
    "Winning GPO" row inside the section instead of a Winning GPO column.
    Compare-GPOHtml.ps1 records those settings with WinningGPO "<Unknown>".
    This fills in the GPO name from the nearest "Winning GPO" row of the same
    report whose category contains the setting's category, and leaves out the
    "Winning GPO" rows and the "Data collected on" row.
    #>
    param([Parameter(Mandatory)][object[]]$Rows)

    $Winners = @{}

    foreach ($Row in $Rows)
    {
        if ("$($Row.SettingName)" -eq 'Winning GPO')
        {
            $ReportKey = "$($Row.ReportName)"

            if (-not $Winners.ContainsKey($ReportKey))
            {
                $Winners[$ReportKey] = [System.Collections.ArrayList]::new()
            }

            [void]$Winners[$ReportKey].Add(
                [PSCustomObject]@{
                    Category = "$($Row.Category)"
                    Gpo      = "$($Row.Value)"
                }
            )
        }
    }

    foreach ($Row in $Rows)
    {
        $SettingName = "$($Row.SettingName)"

        if (($SettingName -eq 'Winning GPO') -or ($SettingName -like 'Data collected on*'))
        {
            continue
        }

        $Gpo = "$($Row.WinningGPO)"

        if (($Gpo -eq '<Unknown>') -and $Winners.ContainsKey("$($Row.ReportName)"))
        {
            $Best = $null

            foreach ($Winner in $Winners["$($Row.ReportName)"])
            {
                $Category = "$($Row.Category)"

                if (($Category -eq $Winner.Category) -or $Category.StartsWith("$($Winner.Category) /"))
                {
                    if (($null -eq $Best) -or ($Winner.Category.Length -gt $Best.Category.Length))
                    {
                        $Best = $Winner
                    }
                }
            }

            if ($null -ne $Best)
            {
                $Gpo = $Best.Gpo
            }
        }

        [PSCustomObject]@{
            Row = $Row
            Gpo = $Gpo
        }
    }
}

#=====================================================
# Configuration files
#=====================================================

function Import-GcRoles
{
    # Reads GpoRoles.csv (GPOName, Site, Role, Precedence).
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "GPO role file not found: $Path"
    }

    $Valid = @('Baseline', 'Hardening', 'Branding', 'DomainRoot', 'Separate', 'Retire')
    $Roles = [System.Collections.ArrayList]::new()
    $Line  = 1

    foreach ($Row in @(Import-Csv -LiteralPath $Path -Encoding UTF8))
    {
        $Line++
        $Name = "$($Row.GPOName)".Trim()

        if ($Name -eq '')
        {
            continue
        }

        $Role = "$($Row.Role)".Trim()
        $Match = @($Valid | Where-Object { $_ -ieq $Role })

        if ($Match.Count -eq 0)
        {
            throw "GpoRoles.csv line $($Line): role '$Role' for '$Name' is not one of: $($Valid -join ', ')."
        }

        $Site = "$($Row.Site)".Trim()

        if ($Site -eq '')
        {
            $Site = '*'
        }

        $Precedence = 999

        if ("$($Row.Precedence)".Trim() -ne '')
        {
            $Precedence = [int]"$($Row.Precedence)".Trim()
        }

        [void]$Roles.Add(
            [PSCustomObject]@{
                GPOName    = $Name
                Site       = $Site
                Role       = $Match[0]
                Precedence = $Precedence
            }
        )
    }

    return $Roles
}

function Import-GcRules
{
    # Reads ConsolidationRules.json and fills in defaults for missing parts.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "Rules file not found: $Path"
    }

    try
    {
        $Rules = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        throw "Failed to read rules file '$Path': $($_.Exception.Message)"
    }

    $Names = $Rules.LayerNames

    $Result = [PSCustomObject]@{
        ReferenceSite     = "$($Rules.ReferenceSite)"
        BaselineName      = if ($Names -and $Names.Baseline) { "$($Names.Baseline)" } else { 'Windows 11 Baseline' }
        HardeningName     = if ($Names -and $Names.Hardening) { "$($Names.Hardening)" } else { 'Hardening' }
        BrandingPrefix    = if ($Names -and $Names.BrandingPrefix) { "$($Names.BrandingPrefix)" } else { 'Branding - ' }
        ValueOverrides    = @($Rules.ValueOverrides | Where-Object { $_ })
        BrandingSettings  = @($Rules.BrandingSettings | Where-Object { $_ })
        IntuneExclusions  = @($Rules.IntuneExclusions | Where-Object { $_ })
        IntuneKeepList    = @($Rules.IntuneKeepList | Where-Object { $_ })
        IntuneKeepListNote = if ($Rules.IntuneKeepListNote) { "$($Rules.IntuneKeepListNote)" } else { 'Kept although {Area} is excluded (IntuneKeepList).' }
        RetireRules       = @($Rules.RetireRules | Where-Object { $_ })
        ReviewNotes       = @($Rules.ReviewNotes | Where-Object { $_ })
    }

    return $Result
}

function Test-GcNameMatch
{
    # True when the setting's display name or raw name matches a name or
    # wildcard pattern (case ignored).
    param(
        [Parameter(Mandatory)][object]$Setting,
        [AllowNull()][object[]]$Patterns
    )

    return ((Test-GcWildcard -Text $Setting.Name -Patterns $Patterns) -or
            (Test-GcWildcard -Text $Setting.RawName -Patterns $Patterns))
}

function Get-GcExclusionArea
{
    # Name (Area) of the first IntuneExclusions entry that matches the
    # setting, or $null. An entry matches when any of its Category, Name or
    # Extension patterns matches.
    param(
        [Parameter(Mandatory)][object]$Setting,
        [AllowNull()][object[]]$Exclusions
    )

    foreach ($Entry in @($Exclusions))
    {
        if ((Test-GcWildcard -Text $Setting.Category -Patterns @($Entry.CategoryPatterns)) -or
            (Test-GcWildcard -Text $Setting.RawCategory -Patterns @($Entry.CategoryPatterns)) -or
            (Test-GcNameMatch -Setting $Setting -Patterns @($Entry.NamePatterns)) -or
            (Test-GcWildcard -Text $Setting.Extension -Patterns @($Entry.ExtensionPatterns)) -or
            (Test-GcWildcard -Text $Setting.Area -Patterns @($Entry.ExtensionPatterns)))
        {
            return "$($Entry.Area)"
        }
    }

    return $null
}

function Get-GcRetireRule
{
    # First RetireRules entry that matches the setting of a GPO with the
    # given role, or $null. Roles and GpoPatterns are optional filters; the
    # setting must match at least one of Area/Category/Name patterns.
    param(
        [Parameter(Mandatory)][object]$Setting,
        [Parameter(Mandatory)][string]$Role,
        [AllowNull()][object[]]$Rules
    )

    foreach ($Rule in @($Rules))
    {
        $RuleRoles = @($Rule.Roles | Where-Object { $_ })

        if (($RuleRoles.Count -gt 0) -and ($RuleRoles -notcontains $Role))
        {
            continue
        }

        $GpoPatterns = @($Rule.GpoPatterns | Where-Object { $_ })

        if (($GpoPatterns.Count -gt 0) -and -not (Test-GcWildcard -Text $Setting.GPOName -Patterns $GpoPatterns))
        {
            continue
        }

        if ((Test-GcWildcard -Text $Setting.Area -Patterns @($Rule.AreaPatterns)) -or
            (Test-GcWildcard -Text $Setting.Category -Patterns @($Rule.CategoryPatterns)) -or
            (Test-GcNameMatch -Setting $Setting -Patterns @($Rule.NamePatterns)))
        {
            return $Rule
        }
    }

    return $null
}

#=====================================================
# Intune columns
#=====================================================

function Get-GcTitleCase
{
    param([string]$Text)

    return (Get-Culture).TextInfo.ToTitleCase($Text.ToLowerInvariant())
}

function Get-GcIntunePolicyName
{
    <#
    Turns the IntuneType of a mapping (free text from the mapping workbooks)
    into one policy name:
        Settings Catalog: <X>     Endpoint security: <X>
        Custom OMA-URI / Remediation, Settings Catalog (find setting), None
    #>
    param(
        [AllowEmptyString()][string]$IntuneType,
        [AllowEmptyString()][string]$Category = ''
    )

    $Type = "$IntuneType".Trim()

    if ($Type -eq '')
    {
        return ''
    }

    if ($Type -like 'No direct*')
    {
        return 'None'
    }

    if ($Type -match '^Endpoint security\s*>\s*(.+)$')
    {
        $Rest = ($Matches[1] -split '\s*>\s*')[0].Trim()
        return "Endpoint security: $Rest"
    }

    if ($Type -like 'Settings Catalog / Custom*')
    {
        return 'Custom OMA-URI / Remediation'
    }

    if ($Type -eq 'Settings Catalog / Endpoint security')
    {
        return 'Settings Catalog (find setting)'
    }

    if ($Type -like 'Settings Catalog / Administrative Templates*')
    {
        return 'Settings Catalog: Administrative Templates'
    }

    if (($Type -match '(?i)defender|antivirus') -and ($Type -match '(?i)^ad.?min'))
    {
        return 'Endpoint security: Antivirus'
    }

    if ($Type -match '(?i)^ad.?mi?n?istrative\s*templ|^adminstrative|^administrative')
    {
        return 'Settings Catalog: Administrative Templates'
    }

    if ($Type -eq 'Defender')
    {
        return 'Endpoint security: Antivirus'
    }

    # "Wireless display>> Require PIN for pairing" -> "Wireless Display".
    $Type = ($Type -split '>')[0].Trim()

    return "Settings Catalog: $(Get-GcTitleCase $Type)"
}

function Get-GcMigrateValue
{
    # "Migrate to Intune?" from the mapping status.
    param(
        [AllowEmptyString()][string]$Status,
        [bool]$Suspect = $false
    )

    switch -Regex ("$Status")
    {
        '^Mapped$'               { if ($Suspect) { return 'Yes – fix mapping' } else { return 'Yes' } }
        '^Mapped \(derived\)$'   { return 'Yes' }
        '^(NoIntuneEquivalent|NoDirectReplacement)$' { return 'No – no Intune equivalent' }
        default                  { return 'Yes – find setting' }
    }
}

function Get-GcIntuneInfo
{
    <#
    Intune columns for one setting from its IntuneMigrationCandidates row:
        IntunePolicy, IntuneSetting, MappingStatus, MappingCheck
    Windows Firewall profile keys are derived to the Defender Firewall CSP
    when the mapping is not "Mapped".
    #>
    param(
        [Parameter(Mandatory)][object]$Setting,
        [AllowNull()][object]$Candidate
    )

    $Type    = ''
    $Target  = ''
    $Status  = 'Unmapped'
    $Check   = ''

    if ($null -ne $Candidate)
    {
        $Type   = "$($Candidate.IntuneType)"
        $Target = "$($Candidate.IntuneSetting)"
        $Status = "$($Candidate.MappingStatus)"
    }

    $Policy = Get-GcIntunePolicyName -IntuneType $Type -Category $Setting.Category

    if (($Setting.Area -eq 'Windows Firewall') -and ($Status -ne 'Mapped') -and
        ($Setting.Category -match '^(Domain|Private|Public) Profile$') -and
        $script:FirewallCspNames.ContainsKey($Setting.Name))
    {
        $Profile = $Matches[1]
        $Policy  = 'Endpoint security: Firewall'
        $Target  = $script:FirewallCspNames[$Setting.Name].Replace('{P}', $Profile)
        $Status  = 'Mapped (derived)'
        $Check   = "Derived: Defender Firewall CSP, $Profile profile."
    }

    return [PSCustomObject]@{
        IntunePolicy  = $Policy
        IntuneSetting = $Target
        MappingStatus = $Status
        MappingCheck  = $Check
    }
}

function Get-GcAuditMappingCheck
{
    # For a mapped Advanced Audit Policy setting: returns a check text when
    # the Intune setting looks like a different audit subcategory, else ''.
    param(
        [Parameter(Mandatory)][string]$SettingName,
        [Parameter(Mandatory)][string]$IntuneSetting
    )

    $Own = ($SettingName -replace '^Audit\s+', '')

    if (-not $script:AuditCategories.ContainsKey($Own))
    {
        return ''
    }

    # Remove a leading category name and the word "audit" before comparing.
    $Target = $IntuneSetting

    foreach ($Category in @($script:AuditCategories.Values | Select-Object -Unique))
    {
        $Pattern = '^(?i)' + [regex]::Escape($Category).Replace('/', '\W*').Replace('\ ', '\W*') + '\W+'
        $Target = $Target -replace $Pattern, ''
    }

    $Target = ($Target -replace '(?i)\baudit\b', ' ')

    $Best      = ''
    $BestScore = -1.0

    foreach ($Sub in $script:AuditCategories.Keys)
    {
        $Score = Get-GcSimilarity -A $Target -B $Sub

        if ($Score -gt $BestScore)
        {
            $BestScore = $Score
            $Best = $Sub
        }
    }

    $OwnScore = Get-GcSimilarity -A $Target -B $Own

    # An Intune setting that contains the subcategory name is accepted.
    $Contains = (Get-GcLetters $IntuneSetting).Contains((Get-GcLetters $Own))

    if ((-not $Contains) -and ($Best -ne $Own) -and ($BestScore -gt $OwnScore))
    {
        return "Mapped to `"$IntuneSetting`"; expected $($script:AuditCategories[$Own]) > $SettingName."
    }

    return ''
}

function Set-GcSuspectMappings
{
    <#
    Marks suspect mappings on plan rows (objects with Setting, Area,
    Category, IntunePolicy, IntuneSetting, MappingStatus, MappingCheck and
    Migrate properties):

    1. One Intune setting used for several settings, where one of those
       settings has the same name as the Intune setting: the others are
       copy-paste errors.
    2. Advanced Audit Policy mapped to a different subcategory.
    3. A Private or Public profile firewall setting mapped to a Domain
       profile Intune setting (or the other way round).
    #>
    param([Parameter(Mandatory)][object[]]$Rows)

    $Groups = @{}

    foreach ($Row in $Rows)
    {
        if (($Row.MappingStatus -ne 'Mapped') -or ([string]::IsNullOrWhiteSpace($Row.IntuneSetting)))
        {
            continue
        }

        $GroupKey = "$($Row.IntunePolicy)|$(Get-GcLetters $Row.IntuneSetting)"

        if (-not $Groups.ContainsKey($GroupKey))
        {
            $Groups[$GroupKey] = [System.Collections.ArrayList]::new()
        }

        [void]$Groups[$GroupKey].Add($Row)
    }

    foreach ($GroupKey in $Groups.Keys)
    {
        $Group = @($Groups[$GroupKey])
        $Names = @($Group | ForEach-Object { Get-GcLetters $_.Setting } | Select-Object -Unique)

        if ($Names.Count -lt 2)
        {
            continue
        }

        $TargetLetters = Get-GcLetters $Group[0].IntuneSetting
        $HasOwner = @($Names | Where-Object { $_ -eq $TargetLetters }).Count -gt 0

        if (-not $HasOwner)
        {
            continue
        }

        foreach ($Row in $Group)
        {
            if ((Get-GcLetters $Row.Setting) -eq $TargetLetters)
            {
                continue
            }

            $Word = 'setting'
            $Where = 'setting'

            if ($Row.Category -eq 'User Rights Assignment')
            {
                $Word = 'right'
                $Where = 'User Rights setting'
            }

            $Row.MappingCheck = "Source workbook maps this $Word to `"$($Row.IntuneSetting)`" (copy-paste error). Use the matching $Where."
            $Row.Migrate = 'Yes – fix mapping'
        }
    }

    foreach ($Row in $Rows)
    {
        if ($Row.MappingStatus -ne 'Mapped')
        {
            continue
        }

        $Check = ''

        if ($Row.Area -eq 'Advanced Audit Policy')
        {
            $Check = Get-GcAuditMappingCheck -SettingName $Row.Setting -IntuneSetting $Row.IntuneSetting
        }
        elseif (($Row.Area -eq 'Windows Firewall') -or ($Row.Category -like '*Windows Defender Firewall/*Profile'))
        {
            $Text = "$($Row.Category) $($Row.Setting)"

            foreach ($Profile in @('Domain', 'Private', 'Public'))
            {
                $Others = @(@('Domain', 'Private', 'Public') | Where-Object { $_ -ne $Profile })

                if (($Text -match "\b$Profile Profile\b") -and ($Row.IntuneSetting -match "\b($($Others -join '|'))\b"))
                {
                    $Check = "Mapped to `"$($Row.IntuneSetting)`"; expected the $Profile profile setting."
                }
            }
        }

        if ($Check -ne '')
        {
            $Row.MappingCheck = $Check
            $Row.Migrate = 'Yes – fix mapping'
        }
    }
}

#=====================================================
# Excel output
#=====================================================

function Get-GcColumnLetter
{
    param([int]$Number)

    $Letters = ''

    while ($Number -gt 0)
    {
        $Rest = ($Number - 1) % 26
        $Letters = [char](65 + $Rest) + $Letters
        $Number = [int][math]::Floor(($Number - 1) / 26)
    }

    return $Letters
}

function Add-GcWorksheet
{
    <#
    Adds one worksheet with the rows as a Medium2 (blue) Excel table.
    Empty sheets get one "(none)" row so the table exists. Text that starts
    with "=" is written back as text (Export-Excel writes it as a formula).
    Returns the package.
    #>
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TableName,
        [AllowNull()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns
    )

    $Data = @($Rows)

    if ($Data.Count -eq 0)
    {
        $Empty = [ordered]@{}

        foreach ($Column in $Columns)
        {
            $Empty[$Column] = ''
        }

        $Empty[$Columns[0]] = '(none)'
        $Data = @([PSCustomObject]$Empty)
    }

    $Data = @($Data | Select-Object -Property $Columns)

    $Package = $Data | Export-Excel -ExcelPackage $Package -WorksheetName $Name -TableName $TableName -TableStyle Medium2 `
        -FreezeTopRow -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    $Sheet = $Package.Workbook.Worksheets[$Name]
    $LastRow = $Data.Count + 1

    for ($Row = 2; $Row -le $LastRow; $Row++)
    {
        for ($Col = 1; $Col -le $Columns.Count; $Col++)
        {
            $Cell = $Sheet.Cells[$Row, $Col]

            if (-not [string]::IsNullOrEmpty($Cell.Formula))
            {
                $Text = '=' + $Cell.Formula
                $Cell.Formula = ''
                $Cell.Value = $Text
            }
        }
    }

    # Column widths: fit, but no wider than 60 characters; long text wraps.
    for ($Col = 1; $Col -le $Columns.Count; $Col++)
    {
        $Sheet.Column($Col).AutoFit()

        if ($Sheet.Column($Col).Width -gt 60)
        {
            $Sheet.Column($Col).Width = 60
            $Sheet.Column($Col).Style.WrapText = $true
        }
    }

    $Sheet.Cells[1, 1, $LastRow, $Columns.Count].Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Top

    return $Package
}

function Set-GcCellColors
{
    # Colours the cells of one column by value. Colors: hashtable of
    # value (wildcard) -> hex RGB.
    param(
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Column,
        [Parameter(Mandatory)][hashtable]$Colors
    )

    $Dimension = $Sheet.Dimension

    if ($null -eq $Dimension)
    {
        return
    }

    $ColIndex = 0

    for ($Col = 1; $Col -le $Dimension.End.Column; $Col++)
    {
        if ("$($Sheet.Cells[1, $Col].Value)" -eq $Column)
        {
            $ColIndex = $Col
        }
    }

    if ($ColIndex -eq 0)
    {
        return
    }

    for ($Row = 2; $Row -le $Dimension.End.Row; $Row++)
    {
        $Cell = $Sheet.Cells[$Row, $ColIndex]
        $Text = "$($Cell.Value)"

        foreach ($Pattern in $Colors.Keys)
        {
            if ($Text -like $Pattern)
            {
                $Cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $Cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$($Colors[$Pattern])"))
                break
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Test-GcWildcard',
    'Get-GcBaseGpoName',
    'Get-GcLetters',
    'Get-GcSimilarity',
    'Get-GcAdminTemplateValue',
    'Get-GcSortedList',
    'ConvertTo-GcSetting',
    'Get-GcSheetRows',
    'Import-GcCompareOutput',
    'Resolve-GcHtmlWinningGpo',
    'Import-GcRoles',
    'Import-GcRules',
    'Test-GcNameMatch',
    'Get-GcExclusionArea',
    'Get-GcRetireRule',
    'Get-GcIntunePolicyName',
    'Get-GcMigrateValue',
    'Get-GcIntuneInfo',
    'Get-GcAuditMappingCheck',
    'Set-GcSuspectMappings',
    'Get-GcColumnLetter',
    'Add-GcWorksheet',
    'Set-GcCellColors'
)
