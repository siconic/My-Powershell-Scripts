#Requires -Version 5.1
<#
.SYNOPSIS
Builds a layered GPO consolidation plan (Excel) from Compare-GPOXml.ps1
output: one shared baseline, its firewall rules, one hardening layer, one
small branding GPO per site, and the Intune migration view.

.DESCRIPTION
New-IntunePolicyPlan.ps1 groups settings by where they are present. This
script groups them by GPO ROLE. The role of each GPO cannot be read from the
settings, so it comes from GpoRoles.csv:

    GPOName, Site, Role, Precedence

    Role        Baseline | Hardening | Branding | DomainRoot | Separate | Retire
    Site        Site name, or * for a GPO that applies to every site.
    Precedence  Link order at the site. A lower number wins (like GPMC link
                order 1). Used when two GPOs of one site set the same setting.

ConsolidationRules.json holds the decisions that are not in the data:
ReferenceSite, ValueOverrides, BrandingSettings, IntuneExclusions,
IntuneKeepList, RetireRules and ReviewNotes. GpoRoles.example.csv and
ConsolidationRules.example.json in the Config folder show the format;
copy them to GpoRoles.csv and ConsolidationRules.json in the same folder
and fill in your GPO names.

Steps:
1. Settings are normalized so GPO XML and GPResult HTML names match (qN:
   prefixes removed, Se* and account policy keys to display names, user
   rights sorted, Administrative Template values cleaned to
   "Enabled; Option=value").
2. Branding: settings matching BrandingSettings are taken per site from the
   site's Branding GPO, then its Baseline GPOs, then its DomainRoot GPO.
   Settings that differ between the sites' Branding GPOs are branding too.
3. Baseline: the union of all Role=Baseline GPOs. Same value everywhere =
   Keep; ValueOverrides = Changed; values that differ = ReferenceSite value
   and Review. Other settings of Branding GPOs that are not a duplicate of the
   site's DomainRoot GPO are "Moved in".
4. Baseline firewall rules: rules of the Baseline GPOs, one row per rule,
   with the sites where the rule is present today.
5. Hardening: Role=Hardening settings that are not in the baseline. Settings
   also in the baseline are retired ("Moved to baseline"); different values
   are listed on Decisions. Sites without a Hardening GPO are flagged.
6. Retired & Moved: DeprecatedPoliciesReference.md matches, RetireRules
   matches, Role=Retire GPOs, branding moved out of a domain-root GPO,
   Branding GPO settings that duplicate the domain-root GPO.
7. Intune columns on every plan row. Firewall profile keys are derived to the
   Defender Firewall CSP. Suspect mappings are marked "Yes – fix mapping".
8. Not Migrated to Intune: settings matching IntuneExclusions (except the
   IntuneKeepList) and the settings of Role=Separate GPOs.

GPOs with no XML export are read from Compare-GPOHtml.ps1 output (GPResult
HTML) when it is given, with a warning: a GPResult report shows only the
settings that GPO wins on that computer.

.PARAMETER InputPath
One or more Compare-GPOXml.ps1 or Compare-GPOHtml.ps1 outputs: an .xlsx
workbook or a folder with the CSV files (ParsedSettings,
IntuneMigrationCandidates, FirewallRules). When a GPO is in more than one
XML input, the first one is used.

.PARAMETER RolesPath
GpoRoles.csv. Default: the Config folder.

.PARAMETER RulesPath
ConsolidationRules.json. Default: the Config folder.

.PARAMETER DeprecatedReferencePath
DeprecatedPoliciesReference.md. Default: the Data folder.

.PARAMETER OutputPath
Workbook to write. Default: GpoConsolidationPlan-<timestamp>.xlsx in the
current folder, with -FilePrefix in front of the file name.

.PARAMETER FilePrefix
Text put in front of the default output file name, for example "SiteA-".

.EXAMPLE
.\New-GpoConsolidationPlan.ps1 -InputPath .\All-GPOCompareXml.xlsx, .\HTML

.NOTES
Version 2.0
Requires the ImportExcel module (installed for the current user if missing).
Uses GPOConsolidation.psm1 and GPOCompare.psm1 (deprecated policy matching)
from the Modules folder.

Changelog
2.0  Files moved into Scripts, Modules, Data and Config folders: GpoRoles.csv
     and ConsolidationRules.json are read from Config. Parameters and output
     are unchanged. New launcher Start-GPOToolkit.ps1.
1.0  First version.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$InputPath,

    [string]$RolesPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\GpoRoles.csv'),

    [string]$RulesPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\ConsolidationRules.json'),

    [string]$DeprecatedReferencePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Data\DeprecatedPoliciesReference.md'),

    [string]$OutputPath,

    [string]$FilePrefix = ''
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Modules
# ------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name ImportExcel))
{
    Write-Host "The ImportExcel module is not installed. Installing it for the current user..."

    try
    {
        Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    catch
    {
        throw "ImportExcel could not be installed: $($_.Exception.Message). Install it with: Install-Module ImportExcel -Scope CurrentUser"
    }
}

Import-Module ImportExcel -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\GPOConsolidation.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\GPOCompare.psm1') -Force -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($OutputPath))
{
    $OutputPath = Join-Path (Get-Location) "$($FilePrefix)GpoConsolidationPlan-$(Get-Date -Format 'yyyyMMdd-HHmmss').xlsx"
}

$Warnings = [System.Collections.ArrayList]::new()

function Add-Warning
{
    param([string]$Text)

    Write-Warning $Text
    [void]$Warnings.Add($Text)
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$Roles = @(Import-GcRoles -Path $RolesPath)
$Rules = Import-GcRules -Path $RulesPath

Import-DeprecatedPolicyReference -Path $DeprecatedReferencePath

$RoleByGpo = @{}

foreach ($Role in $Roles)
{
    $RoleByGpo[$Role.GPOName] = $Role
}

# Sites in the order they first appear in GpoRoles.csv.
$Sites = [System.Collections.ArrayList]::new()

foreach ($Role in $Roles)
{
    if (($Role.Site -ne '*') -and ($Sites -notcontains $Role.Site))
    {
        [void]$Sites.Add($Role.Site)
    }
}

if ($Sites.Count -eq 0)
{
    throw "GpoRoles.csv has no site names (every Site is * or empty)."
}

$ReferenceSite = $Rules.ReferenceSite

if ($Sites -notcontains $ReferenceSite)
{
    Add-Warning "ReferenceSite '$ReferenceSite' is not a site in GpoRoles.csv. The first site ('$($Sites[0])') is used."
    $ReferenceSite = $Sites[0]
}

Write-Host "Sites: $($Sites -join ', ') (reference site: $ReferenceSite)"

# ------------------------------------------------------------
# Input
# ------------------------------------------------------------

# GPO name -> GPO object:
#   Name, Role, Site, Precedence, Source (XML/HTML), Sites, Settings
#   (ordered: key -> setting), Candidates (key -> candidate row), Rules
$Gpos = [ordered]@{}
$UnassignedGpos = @{}

function New-GpoEntry
{
    param([string]$Name, [string]$Source)

    $Role = $RoleByGpo[$Name]

    return [PSCustomObject]@{
        Name       = $Name
        Role       = $Role.Role
        Site       = $Role.Site
        Precedence = $Role.Precedence
        Source     = $Source
        Sites      = [System.Collections.ArrayList]::new()
        Settings   = [ordered]@{}
        Candidates = @{}
        Rules      = [System.Collections.ArrayList]::new()
    }
}

$Inputs = @(foreach ($Path in $InputPath) { Import-GcCompareOutput -Path (Resolve-Path -LiteralPath $Path).Path })

# XML inputs first, so HTML is used only for GPOs without an XML export.
foreach ($Input in @($Inputs | Where-Object { $_.Type -eq 'XML' }))
{
    Write-Host "XML input: $($Input.Path) ($($Input.Parsed.Count) settings)"
    $LoadedHere = @{}

    foreach ($Row in $Input.Parsed)
    {
        $Name = "$($Row.GPOName)"

        if (-not $RoleByGpo.ContainsKey($Name))
        {
            $UnassignedGpos[$Name] = 'XML'
            continue
        }

        if ($Gpos.Contains($Name) -and -not $LoadedHere.ContainsKey($Name))
        {
            continue
        }

        if (-not $Gpos.Contains($Name))
        {
            $Gpos[$Name] = New-GpoEntry -Name $Name -Source 'XML'
            $LoadedHere[$Name] = $true
        }

        $Setting = ConvertTo-GcSetting -Row $Row -GpoName $Name -Source 'XML'

        if (-not $Gpos[$Name].Settings.Contains($Setting.Key))
        {
            $Gpos[$Name].Settings[$Setting.Key] = $Setting
        }
    }

    foreach ($Row in $Input.Candidates)
    {
        $Name = "$($Row.GPOName)"

        if ($LoadedHere.ContainsKey($Name))
        {
            $Setting = ConvertTo-GcSetting -Row ([PSCustomObject]@{ Class = $Row.Class; Extension = $Row.Extension; Category = $Row.Category; SettingName = $Row.SettingName; Value = $Row.GPOValue }) -GpoName $Name -Source 'XML'

            if (-not $Gpos[$Name].Candidates.ContainsKey($Setting.Key))
            {
                $Gpos[$Name].Candidates[$Setting.Key] = $Row
            }
        }
    }

    foreach ($Rule in $Input.FirewallRules)
    {
        $Name = "$($Rule.GPOName)"

        if ($LoadedHere.ContainsKey($Name))
        {
            [void]$Gpos[$Name].Rules.Add(
                [PSCustomObject]@{
                    Name       = "$($Rule.Name)"
                    Direction  = "$($Rule.Direction)"
                    Profile    = "$($Rule.Profile)"
                    Action     = "$($Rule.Action)"
                    Program    = "$($Rule.Application)"
                    Protocol   = "$($Rule.Protocol)"
                    LocalPort  = "$($Rule.LocalPort)"
                    RemotePort = "$($Rule.RemotePort)"
                    Service    = "$($Rule.Service)"
                    Enabled    = "$($Rule.Active)"
                }
            )
        }
    }
}

# Mappings of the XML GPOs by setting key. A setting read from GPResult HTML
# uses the XML mapping of the same setting when there is one, so one setting
# gets one mapping.
$XmlCandidates = @{}

foreach ($Gpo in @($Gpos.Values | Where-Object { $_.Source -eq 'XML' }))
{
    foreach ($Key in $Gpo.Candidates.Keys)
    {
        if (-not $XmlCandidates.ContainsKey($Key))
        {
            $XmlCandidates[$Key] = $Gpo.Candidates[$Key]
        }
    }
}

# Report name -> site, from the sites of the GPOs that win in the report.
$ReportSites = @{}

foreach ($Input in @($Inputs | Where-Object { $_.Type -eq 'HTML' }))
{
    Write-Host "HTML input: $($Input.Path) ($($Input.Parsed.Count) settings)"

    $Resolved = @(Resolve-GcHtmlWinningGpo -Rows $Input.Parsed)
    $Votes = @{}

    foreach ($Item in $Resolved)
    {
        $Role = $RoleByGpo[$Item.Gpo]

        if (($null -ne $Role) -and ($Role.Site -ne '*'))
        {
            $VoteKey = "$($Item.Row.ReportName)|$($Role.Site)"

            if ($Votes.ContainsKey($VoteKey)) { $Votes[$VoteKey]++ } else { $Votes[$VoteKey] = 1 }
        }
    }

    foreach ($Report in @($Resolved | ForEach-Object { "$($_.Row.ReportName)" } | Select-Object -Unique))
    {
        $Best = ''
        $BestCount = 0

        foreach ($Site in $Sites)
        {
            $VoteKey = "$($Report)|$($Site)"

            if ($Votes.ContainsKey($VoteKey) -and ($Votes[$VoteKey] -gt $BestCount))
            {
                $Best = $Site
                $BestCount = $Votes[$VoteKey]
            }
        }

        $ReportSites[$Report] = $Best
        Write-Host "  Report '$Report' -> site '$Best'"
    }

    $HtmlGpos = @{}

    foreach ($Item in $Resolved)
    {
        $Name = $Item.Gpo

        if (-not $RoleByGpo.ContainsKey($Name))
        {
            if (-not $UnassignedGpos.ContainsKey($Name))
            {
                $UnassignedGpos[$Name] = 'HTML'
            }

            continue
        }

        if ($Gpos.Contains($Name) -and -not $HtmlGpos.ContainsKey($Name))
        {
            continue
        }

        if (-not $Gpos.Contains($Name))
        {
            $Gpos[$Name] = New-GpoEntry -Name $Name -Source 'HTML'
            $HtmlGpos[$Name] = $true
        }

        $Report = "$($Item.Row.ReportName)"
        $Site = $ReportSites[$Report]

        if ((-not [string]::IsNullOrEmpty($Site)) -and ($Gpos[$Name].Sites -notcontains $Site))
        {
            [void]$Gpos[$Name].Sites.Add($Site)
        }

        $Setting = ConvertTo-GcSetting -Row $Item.Row -GpoName $Name -Source 'HTML' -ReportName $Report

        if (-not $Gpos[$Name].Settings.Contains($Setting.Key))
        {
            $Gpos[$Name].Settings[$Setting.Key] = $Setting
        }
    }

    foreach ($Row in $Input.Candidates)
    {
        $Name = "$($Row.WinningGPO)"

        if ($HtmlGpos.ContainsKey($Name))
        {
            $Setting = ConvertTo-GcSetting -Row $Row -GpoName $Name -Source 'HTML'

            if (-not $Gpos[$Name].Candidates.ContainsKey($Setting.Key))
            {
                $Gpos[$Name].Candidates[$Setting.Key] = $Row
            }
        }
    }

    foreach ($Rule in $Input.FirewallRules)
    {
        $Name = "$($Rule.WinningGPO)"

        if ($HtmlGpos.ContainsKey($Name))
        {
            [void]$Gpos[$Name].Rules.Add(
                [PSCustomObject]@{
                    Name       = "$($Rule.Name)"
                    Direction  = "$($Rule.Direction)"
                    Profile    = "$($Rule.Profile)"
                    Action     = "$($Rule.Action)"
                    Program    = "$($Rule.Program)"
                    Protocol   = "$($Rule.Protocol)"
                    LocalPort  = "$($Rule.LocalPort)"
                    RemotePort = "$($Rule.RemotePort)"
                    Service    = "$($Rule.Service)"
                    Enabled    = "$($Rule.Enabled)"
                }
            )
        }
    }
}

# Sites of each GPO: its Site; for Site * the report sites (HTML) or all
# sites (XML).
foreach ($Gpo in $Gpos.Values)
{
    if ($Gpo.Site -ne '*')
    {
        $Gpo.Sites.Clear()
        [void]$Gpo.Sites.Add($Gpo.Site)
    }
    elseif (($Gpo.Source -eq 'XML') -or ($Gpo.Sites.Count -eq 0))
    {
        $Gpo.Sites.Clear()

        foreach ($Site in $Sites)
        {
            [void]$Gpo.Sites.Add($Site)
        }
    }

    if ($Gpo.Source -eq 'HTML')
    {
        $Text = "'$($Gpo.Name)' (role $($Gpo.Role)) has no XML export. Its settings come from GPResult HTML, which shows only the settings this GPO wins, and Administrative Template options are not shown."

        if ($Gpo.Role -eq 'Baseline')
        {
            Add-Warning $Text
        }
        else
        {
            Write-Host "Note: $Text"
        }
    }
}

foreach ($Role in $Roles)
{
    if (-not $Gpos.Contains($Role.GPOName))
    {
        Add-Warning "GPO '$($Role.GPOName)' from GpoRoles.csv was not found in the input."
    }
}

if ($UnassignedGpos.Count -gt 0)
{
    Add-Warning "GPOs in the input but not in GpoRoles.csv (ignored): $(@($UnassignedGpos.Keys | Sort-Object) -join '; ')"
}

function Get-GposByRole
{
    param([string]$Role, [string]$Site = '')

    $Found = @($Gpos.Values | Where-Object { $_.Role -eq $Role })

    if ($Site -ne '')
    {
        $Found = @($Found | Where-Object { $_.Sites -contains $Site })
    }

    return @($Found | Sort-Object Precedence)
}

# ------------------------------------------------------------
# Deprecated policy matches
# ------------------------------------------------------------

# Setting (GPO name + key) -> deprecated match.
$DeprecatedIndex = @{}
$AllSettings = [System.Collections.ArrayList]::new()

foreach ($Gpo in $Gpos.Values)
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        [void]$AllSettings.Add(
            [PSCustomObject]@{
                GPOName     = "$($AllSettings.Count)"
                Class       = $Setting.Class
                Extension   = $Setting.Extension
                Category    = $Setting.RawCategory
                SettingName = $Setting.RawName
                Value       = $Setting.Value
                Setting     = $Setting
            }
        )
    }
}

foreach ($Match in @(Get-DeprecatedPolicyMatches -Settings $AllSettings))
{
    $Setting = $AllSettings[[int]$Match.GPOName].Setting
    $DeprecatedIndex["$($Setting.GPOName)|$($Setting.Key)"] = $Match
}

# ------------------------------------------------------------
# Collections for the output
# ------------------------------------------------------------

$RetiredEntries = [System.Collections.ArrayList]::new()
$NotMigrated    = [System.Collections.ArrayList]::new()
$Decisions      = [System.Collections.ArrayList]::new()
$Handled        = @{}   # "GPO|key" -> $true for settings already placed

function Add-Retired
{
    param(
        [object]$Setting,
        [string]$Reason,
        [string]$Replacement,
        [string]$Notes
    )

    [void]$RetiredEntries.Add(
        [PSCustomObject]@{
            Setting     = $Setting
            Reason      = $Reason
            Replacement = $Replacement
            Notes       = $Notes
        }
    )

    $Handled["$($Setting.GPOName)|$($Setting.Key)"] = $true
}

function Add-Decision
{
    param([string]$Where, [string]$Setting, [string]$Today, [string]$Chosen, [string]$Reason)

    [void]$Decisions.Add(
        [PSCustomObject]@{
            Where   = $Where
            Setting = $Setting
            Today   = $Today
            Chosen  = $Chosen
            Reason  = $Reason
        }
    )
}

function Test-Retire
{
    # Retires the setting when it matches DeprecatedPoliciesReference.md or
    # a RetireRules entry. Returns $true when retired.
    param([object]$Setting, [string]$Role)

    $Match = $DeprecatedIndex["$($Setting.GPOName)|$($Setting.Key)"]

    if ($null -ne $Match)
    {
        Add-Retired -Setting $Setting -Reason $Match.Reason -Replacement $Match.RecommendedReplacement -Notes $Match.Status
        return $true
    }

    $Rule = Get-GcRetireRule -Setting $Setting -Role $Role -Rules $Rules.RetireRules

    if ($null -ne $Rule)
    {
        $Replacement = if ($Rule.Replacement) { "$($Rule.Replacement)" } else { '—' }
        Add-Retired -Setting $Setting -Reason "$($Rule.Reason)" -Replacement $Replacement -Notes "$($Rule.Notes)"
        return $true
    }

    return $false
}

function Get-IntuneRowValues
{
    # Intune columns plus exclusion handling for one plan row.
    param([object]$Setting, [object]$Gpo)

    $Candidate = $null

    if ($null -ne $Gpo)
    {
        $Candidate = $Gpo.Candidates[$Setting.Key]

        if (($Gpo.Source -eq 'HTML') -and $XmlCandidates.ContainsKey($Setting.Key))
        {
            $Candidate = $XmlCandidates[$Setting.Key]
        }
    }

    return (Get-GcIntuneInfo -Setting $Setting -Candidate $Candidate)
}

function Test-KeepListed
{
    param([object]$Setting)

    return (Test-GcNameMatch -Setting $Setting -Patterns $Rules.IntuneKeepList)
}

function Get-TodayText
{
    # "SiteA=1 | SiteB=1 | SiteC=0"
    param([hashtable]$Values)

    return (@($Sites | ForEach-Object { if ($Values.ContainsKey($_)) { "$($_)=$($Values[$_].Setting.Value)" } else { "$($_)=(not set)" } }) -join ' | ')
}

$AccountCategories = @('Password', 'Account Lockout', 'Kerberos')

# ------------------------------------------------------------
# Role = Retire and Role = Separate
# ------------------------------------------------------------

foreach ($Gpo in @($Gpos.Values | Where-Object { $_.Role -eq 'Retire' }))
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        Add-Retired -Setting $Setting -Reason 'Not needed' -Replacement '—' -Notes "Role Retire in GpoRoles.csv. Unlink the GPO from $($Gpo.Sites -join ', '), then delete it."
    }

    Add-Decision -Where $Gpo.Name -Setting "All settings ($($Gpo.Settings.Count))" -Today "Linked at: $($Gpo.Sites -join ', ')" -Chosen 'Retire' `
        -Reason "Role Retire in GpoRoles.csv. Unlink the GPO, then delete it. Settings listed on Retired & Moved."
}

foreach ($Gpo in @($Gpos.Values | Where-Object { $_.Role -eq 'Separate' }))
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        $Area = Get-GcExclusionArea -Setting $Setting -Exclusions $Rules.IntuneExclusions
        $Reason = if ($null -ne $Area) { "No – excluded ($Area)" } else { 'No – separate GPO' }

        [void]$NotMigrated.Add(
            [PSCustomObject]@{
                Source   = $Gpo.Name
                Scope    = $Setting.Class
                Category = $Setting.Category
                Setting  = $Setting.Name
                Value    = $Setting.Value
                Reason   = $Reason
            }
        )
    }

    Add-Decision -Where $Gpo.Name -Setting "All settings ($($Gpo.Settings.Count))" -Today "Linked at: $($Gpo.Sites -join ', ')" -Chosen 'Keep as a separate GPO' `
        -Reason "Role Separate in GpoRoles.csv. Not part of the layered design. Settings listed on Not Migrated to Intune."
}

# ------------------------------------------------------------
# Branding
# ------------------------------------------------------------

# Branding key -> first setting seen (for Scope, Area, Category, Name).
$BrandingKeys = [ordered]@{}
# Site -> (key -> @{ Setting; Gpo })
$BrandingBySite = @{}

foreach ($Site in $Sites)
{
    $BrandingBySite[$Site] = @{}

    $Sources = @()
    $Sources += @(Get-GposByRole -Role 'Branding' -Site $Site)
    $Sources += @(Get-GposByRole -Role 'Baseline' -Site $Site)
    $Sources += @(Get-GposByRole -Role 'DomainRoot' -Site $Site)

    foreach ($Gpo in $Sources)
    {
        foreach ($Setting in $Gpo.Settings.Values)
        {
            if (-not (Test-GcNameMatch -Setting $Setting -Patterns $Rules.BrandingSettings))
            {
                continue
            }

            if (-not $BrandingKeys.Contains($Setting.Key))
            {
                $BrandingKeys[$Setting.Key] = $Setting
            }

            if (-not $BrandingBySite[$Site].ContainsKey($Setting.Key))
            {
                $BrandingBySite[$Site][$Setting.Key] = @{ Setting = $Setting; Gpo = $Gpo }
            }
        }
    }
}

# Settings of the Branding GPOs whose value differs between sites.
$BrandingValues = @{}

foreach ($Gpo in @(Get-GposByRole -Role 'Branding'))
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        if (-not $BrandingValues.ContainsKey($Setting.Key))
        {
            $BrandingValues[$Setting.Key] = @{}
        }

        foreach ($Site in $Gpo.Sites)
        {
            if (-not $BrandingValues[$Setting.Key].ContainsKey($Site))
            {
                $BrandingValues[$Setting.Key][$Site] = @{ Setting = $Setting; Gpo = $Gpo }
            }
        }
    }
}

foreach ($Key in $BrandingValues.Keys)
{
    $PerSite = $BrandingValues[$Key]
    $Distinct = @($PerSite.Values | ForEach-Object { $_.Setting.Value } | Select-Object -Unique)

    if (($PerSite.Count -ge 2) -and ($Distinct.Count -ge 2) -and -not $BrandingKeys.Contains($Key))
    {
        $First = @($PerSite.Values)[0].Setting

        # Settings retired by a rule stay retired.
        if (($null -ne $DeprecatedIndex["$($First.GPOName)|$($First.Key)"]) -or ($null -ne (Get-GcRetireRule -Setting $First -Role 'Branding' -Rules $Rules.RetireRules)))
        {
            continue
        }

        $BrandingKeys[$Key] = $First

        foreach ($Site in $PerSite.Keys)
        {
            $BrandingBySite[$Site][$Key] = $PerSite[$Site]
        }
    }
}

$BrandingRows = @{}

foreach ($Site in $Sites)
{
    $SheetName = "$($Rules.BrandingPrefix)$($Site)"
    $BrandingRows[$Site] = [System.Collections.ArrayList]::new()

    foreach ($Key in $BrandingKeys.Keys)
    {
        if (-not $BrandingBySite[$Site].ContainsKey($Key))
        {
            continue
        }

        $Item    = $BrandingBySite[$Site][$Key]
        $Setting = $Item.Setting
        $Gpo     = $Item.Gpo
        $Handled["$($Setting.GPOName)|$($Setting.Key)"] = $true

        $Notes = ''

        if ($Gpo.Role -eq 'Baseline')
        {
            $Notes = "From $Site `"$($Gpo.Name)`"."
        }
        elseif ($Gpo.Role -eq 'DomainRoot')
        {
            $Notes = "Today in the domain-root `"$($Gpo.Name)`". Moved here so it applies only to $Site."
            Add-Retired -Setting $Setting -Reason 'Moved to branding' -Replacement $SheetName -Notes "Leaving it in the domain-root GPO applies it to every site."
        }

        if ($Setting.Class -eq 'User')
        {
            $Notes = ("User setting. $Notes").Trim()
        }

        $Area = Get-GcExclusionArea -Setting $Setting -Exclusions $Rules.IntuneExclusions

        if (($null -ne $Area) -and -not (Test-KeepListed $Setting))
        {
            [void]$NotMigrated.Add(
                [PSCustomObject]@{
                    Source   = $SheetName
                    Scope    = $Setting.Class
                    Category = $Setting.Category
                    Setting  = $Setting.Name
                    Value    = $Setting.Value
                    Reason   = "No – excluded ($Area)"
                }
            )

            continue
        }

        $Intune = Get-IntuneRowValues -Setting $Setting -Gpo $Gpo
        $Check = $Intune.MappingCheck

        if ($null -ne $Area)
        {
            $Check = ("$Check " + $Rules.IntuneKeepListNote.Replace('{Area}', $Area)).Trim()
        }

        [void]$BrandingRows[$Site].Add(
            [PSCustomObject]@{
                Scope         = $Setting.Class
                Area          = $Setting.Area
                Category      = $Setting.Category
                Setting       = $Setting.Name
                Value         = $Setting.Value
                Action        = 'Keep'
                Notes         = $Notes
                IntunePolicy  = $Intune.IntunePolicy
                IntuneSetting = $Intune.IntuneSetting
                MappingStatus = $Intune.MappingStatus
                Migrate       = (Get-GcMigrateValue -Status $Intune.MappingStatus)
                MappingCheck  = $Check
            }
        )
    }
}

# ------------------------------------------------------------
# Branding GPOs: other settings; DomainRoot GPOs: retire rules
# ------------------------------------------------------------

$MovedIn = [ordered]@{}   # key -> hashtable site -> @{ Setting; Gpo }

foreach ($Gpo in @(Get-GposByRole -Role 'Branding'))
{
    $RootKeys = @{}
    $RootNames = [System.Collections.ArrayList]::new()

    foreach ($Site in $Gpo.Sites)
    {
        foreach ($Root in @(Get-GposByRole -Role 'DomainRoot' -Site $Site))
        {
            if ($RootNames -notcontains $Root.Name)
            {
                [void]$RootNames.Add($Root.Name)
            }

            foreach ($Key in $Root.Settings.Keys)
            {
                $RootKeys[$Key] = $true
            }
        }
    }

    foreach ($Setting in $Gpo.Settings.Values)
    {
        if ($BrandingKeys.Contains($Setting.Key))
        {
            continue
        }

        if (Test-Retire -Setting $Setting -Role 'Branding')
        {
            continue
        }

        if ($RootKeys.ContainsKey($Setting.Key))
        {
            $Notes = 'Also set in the domain-root GPO.'

            if ($AccountCategories -contains $Setting.Category)
            {
                $Notes = 'Account/Kerberos policy in an OU-linked GPO only affects LOCAL accounts. Domain account policy comes from the domain-root GPO.'
            }

            Add-Retired -Setting $Setting -Reason 'Duplicate of domain-root GPO' -Replacement ($RootNames -join '; ') -Notes $Notes
            continue
        }

        if (-not $MovedIn.Contains($Setting.Key))
        {
            $MovedIn[$Setting.Key] = @{}
        }

        foreach ($Site in $Gpo.Sites)
        {
            $MovedIn[$Setting.Key][$Site] = @{ Setting = $Setting; Gpo = $Gpo }
        }
    }
}

foreach ($Gpo in @(Get-GposByRole -Role 'DomainRoot'))
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        if ($Handled.ContainsKey("$($Setting.GPOName)|$($Setting.Key)"))
        {
            continue
        }

        [void](Test-Retire -Setting $Setting -Role 'DomainRoot')
    }
}

# ------------------------------------------------------------
# Baseline
# ------------------------------------------------------------

# key -> @{ First = setting; Values = site -> @{ Setting; Gpo }; MovedIn = bool }
$Baseline = [ordered]@{}
$BaselineGpos = @(Get-GposByRole -Role 'Baseline')

foreach ($Gpo in $BaselineGpos)
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        if ($BrandingKeys.Contains($Setting.Key))
        {
            continue
        }

        if (Test-Retire -Setting $Setting -Role 'Baseline')
        {
            continue
        }

        if (-not $Baseline.Contains($Setting.Key))
        {
            $Baseline[$Setting.Key] = @{ First = $Setting; BySite = @{}; MovedIn = $false }
        }

        $Entry = $Baseline[$Setting.Key]

        foreach ($Site in $Gpo.Sites)
        {
            if ((-not $Entry.BySite.ContainsKey($Site)) -or ($Gpo.Precedence -lt $Entry.BySite[$Site].Gpo.Precedence))
            {
                $Entry.BySite[$Site] = @{ Setting = $Setting; Gpo = $Gpo }
            }
        }
    }
}

foreach ($Key in $MovedIn.Keys)
{
    $PerSite = $MovedIn[$Key]
    $First = @($PerSite.Values)[0].Setting

    if ($Baseline.Contains($Key))
    {
        # Already in the baseline: the Branding GPO copy is retired.
        foreach ($Item in $PerSite.Values)
        {
            $BaseValue = @($Baseline[$Key].BySite.Values)[0].Setting.Value
            $Notes = if ($Item.Setting.Value -ceq $BaseValue) { 'Duplicate of baseline (same value).' } else { "Conflicts with baseline. The baseline value is used in the new design: $BaseValue" }
            Add-Retired -Setting $Item.Setting -Reason 'Moved to baseline' -Replacement $Rules.BaselineName -Notes $Notes
        }

        continue
    }

    $Baseline[$Key] = @{ First = $First; BySite = $PerSite; MovedIn = $true }
}

function Get-OverrideRule
{
    param([object]$Setting)

    foreach ($Override in $Rules.ValueOverrides)
    {
        if (Test-GcNameMatch -Setting $Setting -Patterns @("$($Override.Setting)"))
        {
            return $Override
        }
    }

    return $null
}

function Get-ReviewNote
{
    param([object]$Setting)

    foreach ($Note in $Rules.ReviewNotes)
    {
        if (Test-GcNameMatch -Setting $Setting -Patterns @("$($Note.Setting)"))
        {
            return "$($Note.Note)"
        }
    }

    return $null
}

function New-PlanRow
{
    <#
    Builds one Baseline or Hardening row from per-site values.
    Returns @{ Row; Chosen; Setting; Gpo; Excluded (area or $null) }.
    #>
    param(
        [object]$First,
        [hashtable]$Values,
        [string]$Layer,
        [string]$Action,
        [string]$Notes
    )

    $Present = @($Sites | Where-Object { $Values.ContainsKey($_) })
    $Missing = @($Sites | Where-Object { -not $Values.ContainsKey($_) })
    $Distinct = @($Present | ForEach-Object { $Values[$_].Setting.Value } | Select-Object -Unique)

    # PowerShell -eq is not case-sensitive; compare values exactly.
    $DistinctExact = [System.Collections.ArrayList]::new()

    foreach ($Site in $Present)
    {
        $Value = $Values[$Site].Setting.Value
        $Seen = $false

        foreach ($Known in $DistinctExact)
        {
            if ($Known -ceq $Value) { $Seen = $true }
        }

        if (-not $Seen) { [void]$DistinctExact.Add($Value) }
    }

    $SourceSite = if ($Values.ContainsKey($ReferenceSite)) { $ReferenceSite } else { $Present[0] }
    $Source = $Values[$SourceSite]
    $Proposed = $Source.Setting.Value

    if ($DistinctExact.Count -gt 1)
    {
        $Same = 'No'
    }
    elseif ($Missing.Count -gt 0)
    {
        $Same = "No (not at $($Missing -join ', '))"
    }
    else
    {
        $Same = 'Yes'
    }

    $Today = Get-TodayText -Values $Values
    $DecisionReason = $null

    $Override = Get-OverrideRule -Setting $First

    if (($null -ne $Override) -and ("$($Override.Value)" -cne $Proposed))
    {
        $Proposed = "$($Override.Value)"
        $Action = 'Changed'
        $DecisionReason = "$($Override.Reason)"
    }
    elseif ($DistinctExact.Count -gt 1)
    {
        $Action = 'Review'
        $DecisionReason = "Values differ between sites. Proposed the $SourceSite value; confirm before rollout."
    }
    elseif (($Missing.Count -gt 0) -and ($Layer -eq $Rules.BaselineName) -and ($Action -ne 'Moved in'))
    {
        $DecisionReason = "Only set at $($Present -join ', ') today. The baseline applies it to $($Missing -join ', ') too."
    }

    $ReviewNote = Get-ReviewNote -Setting $First

    if ($null -ne $ReviewNote)
    {
        $Action = 'Review'
        $Notes = ("$ReviewNote $Notes").Trim()
    }

    $Excluded = Get-GcExclusionArea -Setting $First -Exclusions $Rules.IntuneExclusions
    $Kept = $false

    if (($null -ne $Excluded) -and (Test-KeepListed $First))
    {
        $Kept = $true
    }

    $Intune = Get-IntuneRowValues -Setting $Source.Setting -Gpo $Source.Gpo
    $Check = $Intune.MappingCheck

    if ($Kept)
    {
        $Check = ("$Check " + $Rules.IntuneKeepListNote.Replace('{Area}', $Excluded)).Trim()
        $Excluded = $null
    }

    $Row = [ordered]@{
        Scope         = $First.Class
        Area          = $First.Area
        Category      = $First.Category
        Setting       = $First.Name
        Proposed      = $Proposed
        Action        = $Action
        Same          = $Same
    }

    foreach ($Site in $Sites)
    {
        $Row["Today: $Site"] = if ($Values.ContainsKey($Site)) { $Values[$Site].Setting.Value } else { '(not set)' }
    }

    $Row.Notes         = $Notes
    $Row.IntunePolicy  = $Intune.IntunePolicy
    $Row.IntuneSetting = $Intune.IntuneSetting
    $Row.MappingStatus = $Intune.MappingStatus
    $Row.Migrate       = (Get-GcMigrateValue -Status $Intune.MappingStatus)
    $Row.MappingCheck  = $Check

    if (($null -ne $DecisionReason) -and ($null -eq $Excluded))
    {
        Add-Decision -Where $Layer -Setting $First.Name -Today $Today -Chosen $Proposed -Reason $DecisionReason
    }

    return @{
        Row      = [PSCustomObject]$Row
        Proposed = $Proposed
        Source   = $Source
        Excluded = $Excluded
    }
}

$BaselineRows = [System.Collections.ArrayList]::new()
$BaselineValue = @{}   # key -> proposed value (includes excluded settings)

foreach ($Key in $Baseline.Keys)
{
    $Entry = $Baseline[$Key]
    $Action = 'Keep'
    $Notes = ''

    if ($Entry.MovedIn)
    {
        $Action = 'Moved in'
        $From = @($Entry.BySite.Values | ForEach-Object { $_.Gpo.Name } | Select-Object -Unique)
        $Notes = "Moved in from $(@($From | ForEach-Object { '"' + $_ + '"' }) -join ', ')."
    }

    $Result = New-PlanRow -First $Entry.First -Values $Entry.BySite -Layer $Rules.BaselineName -Action $Action -Notes $Notes
    $BaselineValue[$Key] = $Result.Proposed

    if ($null -ne $Result.Excluded)
    {
        [void]$NotMigrated.Add(
            [PSCustomObject]@{
                Source   = $Rules.BaselineName
                Scope    = $Entry.First.Class
                Category = $Entry.First.Category
                Setting  = $Entry.First.Name
                Value    = $Result.Proposed
                Reason   = "No – excluded ($($Result.Excluded))"
            }
        )

        continue
    }

    [void]$BaselineRows.Add($Result.Row)
}

# Baseline GPOs whose settings are all set by another baseline GPO of the
# same site: the GPO is redundant.
foreach ($Gpo in $BaselineGpos)
{
    $Others = [System.Collections.ArrayList]::new()
    $AllCovered = $true
    $Count = 0

    foreach ($Setting in $Gpo.Settings.Values)
    {
        if ($BrandingKeys.Contains($Setting.Key))
        {
            continue
        }

        $Count++
        $Covered = $false

        foreach ($Other in $BaselineGpos)
        {
            if (($Other.Name -eq $Gpo.Name) -or -not $Other.Settings.Contains($Setting.Key))
            {
                continue
            }

            if (@($Other.Sites | Where-Object { $Gpo.Sites -contains $_ }).Count -gt 0)
            {
                $Covered = $true

                if ($Others -notcontains $Other.Name)
                {
                    [void]$Others.Add($Other.Name)
                }
            }
        }

        if (-not $Covered)
        {
            $AllCovered = $false
        }
    }

    if ($AllCovered -and ($Count -gt 0))
    {
        Add-Decision -Where $Gpo.Name -Setting "All settings ($Count)" -Today "Also set by $(@($Others | ForEach-Object { '"' + $_ + '"' }) -join ', ')" -Chosen 'Remove GPO' `
            -Reason "Every setting of this GPO is also set by another baseline GPO at the same site. The baseline keeps them. Check the values, then unlink and delete this GPO."
    }
}

# Account policy in Branding and domain-root GPOs that differs from the
# baseline value.
foreach ($Key in $Baseline.Keys)
{
    $First = $Baseline[$Key].First

    if ($First.Area -ne 'Security')
    {
        continue
    }

    $Differences = [System.Collections.ArrayList]::new()

    foreach ($Gpo in @(@(Get-GposByRole -Role 'Branding') + @(Get-GposByRole -Role 'DomainRoot')))
    {
        if ($Gpo.Settings.Contains($Key) -and ($Gpo.Settings[$Key].Value -cne $BaselineValue[$Key]))
        {
            [void]$Differences.Add("$($Gpo.Name)=$($Gpo.Settings[$Key].Value)")
        }
    }

    if ($Differences.Count -gt 0)
    {
        $Where = if ($AccountCategories -contains $First.Category) { 'Domain account policy' } else { 'Branding / domain root vs baseline' }
        $Reason = if ($AccountCategories -contains $First.Category) {
            'OU-linked GPOs only affect local accounts. Set the domain account policy in the domain-root GPO; the baseline value applies to local accounts.'
        } else {
            'A Branding or domain-root GPO sets a different value than the baseline. The baseline value is used.'
        }

        Add-Decision -Where $Where -Setting $First.Name -Today "$($Differences -join ' | ') | Baseline=$($BaselineValue[$Key])" -Chosen $BaselineValue[$Key] -Reason $Reason
    }
}

# ------------------------------------------------------------
# Baseline firewall rules
# ------------------------------------------------------------

function Get-RuleKey
{
    param([object]$Rule)

    return (@($Rule.Name, $Rule.Direction, $Rule.Profile, $Rule.Action, $Rule.Program, $Rule.Protocol, $Rule.LocalPort, $Rule.RemotePort, $Rule.Service, $Rule.Enabled) -join '|').ToLowerInvariant()
}

$FirewallRows = [ordered]@{}

foreach ($Gpo in $BaselineGpos)
{
    foreach ($Rule in $Gpo.Rules)
    {
        $RuleKey = Get-RuleKey $Rule

        if (-not $FirewallRows.Contains($RuleKey))
        {
            $FirewallRows[$RuleKey] = @{ Rule = $Rule; Sites = [System.Collections.ArrayList]::new() }
        }

        foreach ($Site in $Gpo.Sites)
        {
            if ($FirewallRows[$RuleKey].Sites -notcontains $Site)
            {
                [void]$FirewallRows[$RuleKey].Sites.Add($Site)
            }
        }
    }
}

$FirewallOutput = @(foreach ($Item in $FirewallRows.Values)
{
    $Rule = $Item.Rule

    [PSCustomObject]@{
        'Name'               = $Rule.Name
        'Direction'          = $Rule.Direction
        'Profile'            = $Rule.Profile
        'Action'             = $Rule.Action
        'Program'            = $Rule.Program
        'Protocol'           = $Rule.Protocol
        'Local port'         = $Rule.LocalPort
        'Remote port'        = $Rule.RemotePort
        'Service'            = $Rule.Service
        'Enabled'            = $Rule.Enabled
        'Present today in'   = (@($Sites | Where-Object { $Item.Sites -contains $_ }) -join ', ')
        'Intune policy'      = 'Endpoint security: Firewall rules'
        'Migrate to Intune?' = 'Yes'
    }
})

# ------------------------------------------------------------
# Hardening
# ------------------------------------------------------------

$HardeningGpos = @(Get-GposByRole -Role 'Hardening')
$HardeningSites = @($Sites | Where-Object { $Site = $_; @($HardeningGpos | Where-Object { $_.Sites -contains $Site }).Count -gt 0 })
$NoHardeningSites = @($Sites | Where-Object { $HardeningSites -notcontains $_ })

$NewSiteNote = ''

if (($HardeningGpos.Count -gt 0) -and ($NoHardeningSites.Count -gt 0))
{
    $SiteList = $NoHardeningSites -join ', '
    $NewSiteNote = "New for $SiteList ($SiteList has no Hardening GPO today). Pilot before broad rollout."
}

$Hardening = [ordered]@{}
$HardeningDecisions = @{}

foreach ($Gpo in $HardeningGpos)
{
    foreach ($Setting in $Gpo.Settings.Values)
    {
        if ($BrandingKeys.Contains($Setting.Key))
        {
            Add-Retired -Setting $Setting -Reason 'Moved to branding' -Replacement "$($Rules.BrandingPrefix)$($Gpo.Sites -join ', ')" -Notes ''
            continue
        }

        if (Test-Retire -Setting $Setting -Role 'Hardening')
        {
            continue
        }

        if ($BaselineValue.ContainsKey($Setting.Key))
        {
            $Chosen = $BaselineValue[$Setting.Key]

            if ($Setting.Value -ceq $Chosen)
            {
                Add-Retired -Setting $Setting -Reason 'Moved to baseline' -Replacement $Rules.BaselineName -Notes 'Duplicate of baseline (same value).'
                continue
            }

            # Does a baseline GPO win today at the Hardening GPO's sites?
            $BaselineWins = $true

            foreach ($Site in $Gpo.Sites)
            {
                $Item = $Baseline[$Setting.Key].BySite[$Site]

                if (($null -eq $Item) -or ($Item.Gpo.Precedence -gt $Gpo.Precedence))
                {
                    $BaselineWins = $false
                }
            }

            if ($BaselineWins)
            {
                $Notes = "Conflicts with baseline. Baseline value wins today and in the new design: $Chosen"
                $Reason = 'Baseline value already wins today (link order). Removed from Hardening so a link-order change cannot flip it.'
            }
            else
            {
                $Notes = "Conflicts with baseline. Hardening value wins today; the new design uses the baseline value: $Chosen"
                $Reason = 'Hardening value wins today (link order). The new design uses the baseline value; confirm before rollout.'
            }

            Add-Retired -Setting $Setting -Reason 'Moved to baseline' -Replacement $Rules.BaselineName -Notes $Notes

            $DecisionKey = "$($Setting.Key)|$($Setting.Value)"

            if (-not $HardeningDecisions.ContainsKey($DecisionKey))
            {
                $HardeningDecisions[$DecisionKey] = $true
                Add-Decision -Where "$($Rules.HardeningName) → Baseline" -Setting $Setting.Name -Today "$($Rules.HardeningName)=$($Setting.Value) | Baseline=$Chosen" -Chosen $Chosen -Reason $Reason
            }

            continue
        }

        if (-not $Hardening.Contains($Setting.Key))
        {
            $Hardening[$Setting.Key] = @{ First = $Setting; BySite = @{} }
        }

        foreach ($Site in $Gpo.Sites)
        {
            if ((-not $Hardening[$Setting.Key].BySite.ContainsKey($Site)) -or ($Gpo.Precedence -lt $Hardening[$Setting.Key].BySite[$Site].Gpo.Precedence))
            {
                $Hardening[$Setting.Key].BySite[$Site] = @{ Setting = $Setting; Gpo = $Gpo }
            }
        }
    }
}

$HardeningRows = [System.Collections.ArrayList]::new()

foreach ($Key in $Hardening.Keys)
{
    $Entry = $Hardening[$Key]
    $Result = New-PlanRow -First $Entry.First -Values $Entry.BySite -Layer $Rules.HardeningName -Action 'Keep' -Notes $NewSiteNote

    if ($null -ne $Result.Excluded)
    {
        [void]$NotMigrated.Add(
            [PSCustomObject]@{
                Source   = $Rules.HardeningName
                Scope    = $Entry.First.Class
                Category = $Entry.First.Category
                Setting  = $Entry.First.Name
                Value    = $Result.Proposed
                Reason   = "No – excluded ($($Result.Excluded))"
            }
        )

        continue
    }

    [void]$HardeningRows.Add($Result.Row)
}

# Hardening firewall rules that are not baseline rules.
$HardeningRules = [ordered]@{}
$RetiredRuleCount = 0

foreach ($Gpo in $HardeningGpos)
{
    foreach ($Rule in $Gpo.Rules)
    {
        $RuleKey = Get-RuleKey $Rule

        if ($FirewallRows.Contains($RuleKey))
        {
            $RetiredRuleCount++
            continue
        }

        if (-not $HardeningRules.Contains($RuleKey))
        {
            $HardeningRules[$RuleKey] = @{ Rule = $Rule; Sites = [System.Collections.ArrayList]::new() }
        }

        foreach ($Site in $Gpo.Sites)
        {
            if ($HardeningRules[$RuleKey].Sites -notcontains $Site)
            {
                [void]$HardeningRules[$RuleKey].Sites.Add($Site)
            }
        }
    }
}

foreach ($Item in $HardeningRules.Values)
{
    $Rule = $Item.Rule
    $Parts = [System.Collections.ArrayList]::new()
    [void]$Parts.Add($Rule.Action)

    if ($Rule.Protocol)   { [void]$Parts.Add("Protocol=$($Rule.Protocol)") }
    if ($Rule.LocalPort)  { [void]$Parts.Add("LocalPort=$($Rule.LocalPort)") }
    if ($Rule.RemotePort) { [void]$Parts.Add("RemotePort=$($Rule.RemotePort)") }
    if ($Rule.Program)    { [void]$Parts.Add("Program=$($Rule.Program)") }
    if ($Rule.Service)    { [void]$Parts.Add("Service=$($Rule.Service)") }

    $Value = @($Parts) -join '; '
    $Action = 'Keep'
    $Notes = $NewSiteNote

    if ($Rule.Action -eq 'Allow')
    {
        $Action = 'Review'
        $Notes = ("Allow rule, not a hardening control. Consider moving it to the baseline firewall rules. $NewSiteNote").Trim()
    }

    $Missing = @($Sites | Where-Object { $Item.Sites -notcontains $_ })

    $Row = [ordered]@{
        Scope    = 'Computer'
        Area     = 'Windows Firewall rule'
        Category = "$($Rule.Direction) / $($Rule.Profile)"
        Setting  = $Rule.Name
        Proposed = $Value
        Action   = $Action
        Same     = if ($Missing.Count -eq 0) { 'Yes' } else { "No (not at $($Missing -join ', '))" }
    }

    foreach ($Site in $Sites)
    {
        $Row["Today: $Site"] = if ($Item.Sites -contains $Site) { $Value } else { '(not set)' }
    }

    $Row.Notes         = $Notes
    $Row.IntunePolicy  = 'Endpoint security: Firewall rules'
    $Row.IntuneSetting = ''
    $Row.MappingStatus = 'Mapped'
    $Row.Migrate       = 'Yes'
    $Row.MappingCheck  = ''

    [void]$HardeningRows.Add([PSCustomObject]$Row)
}

# ------------------------------------------------------------
# Suspect mappings (across Baseline, Hardening and Branding)
# ------------------------------------------------------------

$PlanRows = @()
$PlanRows += @($BaselineRows)
$PlanRows += @($HardeningRows | Where-Object { $_.Area -ne 'Windows Firewall rule' })

foreach ($Site in $Sites)
{
    $PlanRows += @($BrandingRows[$Site])
}

if ($PlanRows.Count -gt 0)
{
    Set-GcSuspectMappings -Rows $PlanRows
}

# ------------------------------------------------------------
# Retired & Moved (one row per setting, value and reason across sites)
# ------------------------------------------------------------

$RetiredGroups = [ordered]@{}

foreach ($Entry in $RetiredEntries)
{
    $Setting = $Entry.Setting

    # Baseline and Hardening GPOs of different sites are one layer in the
    # new design, so their rows are combined across sites ("Windows 11
    # Workstation Policy (all 3 sites)"). Other GPOs keep one row each.
    $Base = $Setting.GPOName

    if (@('Baseline', 'Hardening') -contains $Gpos[$Setting.GPOName].Role)
    {
        $Base = "$($Gpos[$Setting.GPOName].Role)|$(Get-GcBaseGpoName $Setting.GPOName)"
    }

    $GroupKey = "$($Base)|$($Setting.Key)|$($Setting.Value)|$($Entry.Reason)|$($Entry.Notes)"

    if (-not $RetiredGroups.Contains($GroupKey))
    {
        $RetiredGroups[$GroupKey] = @{ Entry = $Entry; Gpos = [System.Collections.ArrayList]::new(); Base = (Get-GcBaseGpoName $Setting.GPOName) }
    }

    if ($RetiredGroups[$GroupKey].Gpos -notcontains $Setting.GPOName)
    {
        [void]$RetiredGroups[$GroupKey].Gpos.Add($Setting.GPOName)
    }
}

$RetiredRows = [System.Collections.ArrayList]::new()

foreach ($Group in $RetiredGroups.Values)
{
    $Entry = $Group.Entry
    $Setting = $Entry.Setting
    $GroupSites = [System.Collections.ArrayList]::new()

    foreach ($Name in $Group.Gpos)
    {
        foreach ($Site in $Gpos[$Name].Sites)
        {
            if ($GroupSites -notcontains $Site) { [void]$GroupSites.Add($Site) }
        }
    }

    $SiteText = @($Sites | Where-Object { $GroupSites -contains $_ }) -join ', '

    if ($Group.Gpos.Count -gt 1)
    {
        if ($GroupSites.Count -eq $Sites.Count)
        {
            $Label = "$($Group.Base) (all $($Sites.Count) sites)"
        }
        else
        {
            $Label = "$($Group.Base) ($SiteText)"
        }
    }
    elseif ($GroupSites.Count -gt 1)
    {
        $Label = "$($Group.Gpos[0]) ($SiteText)"
    }
    else
    {
        $Label = $Group.Gpos[0]
    }

    [void]$RetiredRows.Add(
        [PSCustomObject]@{
            'Source GPO'             = $Label
            'Scope'                  = $Setting.Class
            'Area'                   = $Setting.Area
            'Category'               = $Setting.Category
            'Setting'                = $Setting.Name
            'Value today'            = $Setting.Value
            'Reason'                 = $Entry.Reason
            'Replacement / new home' = $Entry.Replacement
            'Notes'                  = $Entry.Notes
        }
    )
}

# ------------------------------------------------------------
# Intune Plan data (counted in PowerShell for the console; the workbook
# uses formulas)
# ------------------------------------------------------------

$PolicyCounts = @{}

function Add-PolicyCount
{
    param([string]$Policy, [string]$Migrate)

    if ($Migrate -notlike 'Yes*')
    {
        return
    }

    if (-not $PolicyCounts.ContainsKey($Policy))
    {
        $PolicyCounts[$Policy] = @{ Total = 0; Ready = 0 }
    }

    $PolicyCounts[$Policy].Total++

    if ($Migrate -eq 'Yes')
    {
        $PolicyCounts[$Policy].Ready++
    }
}

foreach ($Row in @($BaselineRows) + @($HardeningRows))
{
    Add-PolicyCount -Policy $Row.IntunePolicy -Migrate $Row.Migrate
}

foreach ($Site in $Sites)
{
    foreach ($Row in $BrandingRows[$Site])
    {
        Add-PolicyCount -Policy $Row.IntunePolicy -Migrate $Row.Migrate
    }
}

foreach ($Row in $FirewallOutput)
{
    Add-PolicyCount -Policy $Row.'Intune policy' -Migrate $Row.'Migrate to Intune?'
}

$Policies = @($PolicyCounts.Keys | Sort-Object @{ Expression = { $PolicyCounts[$_].Total }; Descending = $true }, @{ Expression = { $_ } })

# ------------------------------------------------------------
# Workbook
# ------------------------------------------------------------

function ConvertTo-SheetRow
{
    # Internal Baseline/Hardening/Branding row -> output column names.
    param([object]$Row, [switch]$Branding)

    $Out = [ordered]@{
        'Scope'    = $Row.Scope
        'Area'     = $Row.Area
        'Category' = $Row.Category
        'Setting'  = $Row.Setting
    }

    if ($Branding)
    {
        $Out['Value']  = $Row.Value
        $Out['Action'] = $Row.Action
    }
    else
    {
        $Out['Proposed value'] = $Row.Proposed
        $Out['Action'] = $Row.Action
        $Out['Same at all sites today?'] = $Row.Same

        foreach ($Site in $Sites)
        {
            $Out["Today: $Site"] = $Row."Today: $Site"
        }
    }

    $Out['Notes']              = $Row.Notes
    $Out['Intune policy']      = $Row.IntunePolicy
    $Out['Intune setting']     = $Row.IntuneSetting
    $Out['Mapping status']     = $Row.MappingStatus
    $Out['Migrate to Intune?'] = $Row.Migrate
    $Out['Mapping check']      = $Row.MappingCheck

    return [PSCustomObject]$Out
}

$PlanColumns = @('Scope', 'Area', 'Category', 'Setting', 'Proposed value', 'Action', 'Same at all sites today?')
$PlanColumns += @($Sites | ForEach-Object { "Today: $_" })
$PlanColumns += @('Notes', 'Intune policy', 'Intune setting', 'Mapping status', 'Migrate to Intune?', 'Mapping check')

$BrandingColumns = @('Scope', 'Area', 'Category', 'Setting', 'Value', 'Action', 'Notes', 'Intune policy', 'Intune setting', 'Mapping status', 'Migrate to Intune?', 'Mapping check')
$FirewallColumns = @('Name', 'Direction', 'Profile', 'Action', 'Program', 'Protocol', 'Local port', 'Remote port', 'Service', 'Enabled', 'Present today in', 'Intune policy', 'Migrate to Intune?')
$DecisionColumns = @('Where', 'Setting', 'Today', 'Chosen', 'Reason')
$RetiredColumns  = @('Source GPO', 'Scope', 'Area', 'Category', 'Setting', 'Value today', 'Reason', 'Replacement / new home', 'Notes')
$NotMigratedColumns = @('Source', 'Scope', 'Category', 'Setting', 'Value', 'Reason')

# Sheet name, table name, rows, columns.
$Sheets = [System.Collections.ArrayList]::new()
[void]$Sheets.Add(@{ Name = 'Baseline'; Table = 'Baseline'; Rows = @($BaselineRows | ForEach-Object { ConvertTo-SheetRow $_ }); Columns = $PlanColumns })
[void]$Sheets.Add(@{ Name = 'Baseline FW Rules'; Table = 'BaselineFWRules'; Rows = $FirewallOutput; Columns = $FirewallColumns })
[void]$Sheets.Add(@{ Name = 'Hardening'; Table = 'Hardening'; Rows = @($HardeningRows | ForEach-Object { ConvertTo-SheetRow $_ }); Columns = $PlanColumns })

$SiteNumber = 0

foreach ($Site in $Sites)
{
    $SiteNumber++
    $SheetName = "$($Rules.BrandingPrefix)$($Site)"

    foreach ($Bad in @('[', ']', ':', '*', '?', '/', '\'))
    {
        $SheetName = $SheetName.Replace($Bad, '_')
    }

    if ($SheetName.Length -gt 31)
    {
        $SheetName = $SheetName.Substring(0, 31)
    }

    [void]$Sheets.Add(@{ Name = $SheetName; Table = "Branding$($SiteNumber)"; Rows = @($BrandingRows[$Site] | ForEach-Object { ConvertTo-SheetRow $_ -Branding }); Columns = $BrandingColumns; Site = $Site })
}

[void]$Sheets.Add(@{ Name = 'Decisions'; Table = 'Decisions'; Rows = @($Decisions); Columns = $DecisionColumns })
[void]$Sheets.Add(@{ Name = 'Retired & Moved'; Table = 'RetiredMoved'; Rows = @($RetiredRows); Columns = $RetiredColumns })
[void]$Sheets.Add(@{ Name = 'Not Migrated to Intune'; Table = 'NotMigrated'; Rows = @($NotMigrated); Columns = $NotMigratedColumns })

# Sheets whose rows count toward the Intune Plan.
$IntuneSheets = @($Sheets | Where-Object { $_.Columns -contains 'Intune policy' })

function Get-ColumnRange
{
    # 'Sheet'!$X:$X for a column name of a sheet.
    param([hashtable]$Sheet, [string]$Column)

    $Index = [array]::IndexOf([string[]]$Sheet.Columns, $Column) + 1
    $Letter = Get-GcColumnLetter $Index

    return "'$($Sheet.Name)'!`$$($Letter):`$$($Letter)"
}

# Summary rows (Count is a formula).
$SummaryItems = [System.Collections.ArrayList]::new()

function Add-SummaryItem
{
    param([string]$Item, [string]$Formula, [string]$Notes, [string]$Link = '')

    [void]$SummaryItems.Add(@{ Item = $Item; Formula = $Formula; Notes = $Notes; Link = $Link })
}

function Get-CountFormula
{
    # Rows of a sheet's table (the "(none)" placeholder row is not counted).
    param([hashtable]$Sheet, [string]$Extra = '')

    $Range = Get-ColumnRange -Sheet $Sheet -Column $Sheet.Columns[0]
    return "COUNTA($Range)-1-COUNTIF($Range,`"(none)`")$Extra"
}

$SheetByName = @{}

foreach ($Sheet in $Sheets)
{
    $SheetByName[$Sheet.Name] = $Sheet
}

$HardeningSheet = $SheetByName['Hardening']
$HardeningArea = Get-ColumnRange -Sheet $HardeningSheet -Column 'Area'

Add-SummaryItem 'Baseline settings' (Get-CountFormula $SheetByName['Baseline']) "Role=Baseline GPOs merged; branding and excluded settings are not on this sheet." 'Baseline'
Add-SummaryItem 'Baseline firewall rules' (Get-CountFormula $SheetByName['Baseline FW Rules']) 'One row per rule; "Present today in" lists the sites.' 'Baseline FW Rules'
Add-SummaryItem 'Hardening settings' ((Get-CountFormula $HardeningSheet) + "-COUNTIF($HardeningArea,`"Windows Firewall rule`")") 'Settings of the Hardening GPOs that are not in the baseline.' 'Hardening'
Add-SummaryItem 'Hardening firewall rules' "COUNTIF($HardeningArea,`"Windows Firewall rule`")" 'Hardening GPO firewall rules that are not baseline rules.' 'Hardening'

foreach ($Sheet in @($Sheets | Where-Object { $_.ContainsKey('Site') }))
{
    Add-SummaryItem "$($Sheet.Name) settings" (Get-CountFormula $Sheet) "Branding GPO for $($Sheet.Site)." $Sheet.Name
}

Add-SummaryItem 'Decisions' (Get-CountFormula $SheetByName['Decisions']) 'Choices the plan made; confirm each one.' 'Decisions'
Add-SummaryItem 'Retired & moved' (Get-CountFormula $SheetByName['Retired & Moved']) 'Settings removed from their GPO, with the reason and new home.' 'Retired & Moved'
Add-SummaryItem 'Not migrated to Intune' (Get-CountFormula $SheetByName['Not Migrated to Intune']) 'IntuneExclusions areas and Role=Separate GPOs.' 'Not Migrated to Intune'
Add-SummaryItem 'Intune: settings to migrate' "SUM('Intune Plan'!`$B:`$B)" 'Rows with "Migrate to Intune?" starting with Yes (firewall rules counted once).' 'Intune Plan'
Add-SummaryItem 'Intune: ready' "SUM('Intune Plan'!`$C:`$C)" '"Migrate to Intune?" = Yes.' 'Intune Plan'
Add-SummaryItem 'Intune: to do' "SUM('Intune Plan'!`$D:`$D)" 'Find the setting or fix the mapping first.' 'Intune Plan'

if (Test-Path -LiteralPath $OutputPath)
{
    throw "Output file already exists: $OutputPath"
}

# Summary: written with placeholder counts, formulas set afterwards.
$SummaryData = @(foreach ($Item in $SummaryItems)
{
    [PSCustomObject]@{ Item = $Item.Item; Count = 0; Notes = $Item.Notes }
})

foreach ($Warning in $Warnings)
{
    $SummaryData += [PSCustomObject]@{ Item = 'Warning'; Count = $null; Notes = $Warning }
}

$Package = $SummaryData | Export-Excel -Path $OutputPath -WorksheetName 'Summary' -TableName 'Summary' -TableStyle Medium2 `
    -Title 'GPO Consolidation Plan' -TitleBold -TitleSize 14 -PassThru

# Intune Plan: policy rows with COUNTIFS over the plan sheets.
$PlanData = @(foreach ($Policy in $Policies)
{
    [PSCustomObject]@{ 'Intune policy' = $Policy; 'Settings to migrate' = 0; 'Ready' = 0; 'To do' = 0 }
})

if ($PlanData.Count -eq 0)
{
    $PlanData = @([PSCustomObject]@{ 'Intune policy' = '(none)'; 'Settings to migrate' = 0; 'Ready' = 0; 'To do' = 0 })
}

$Package = $PlanData | Export-Excel -ExcelPackage $Package -WorksheetName 'Intune Plan' -TableName 'IntunePlan' -TableStyle Medium2 -PassThru

foreach ($Sheet in $Sheets)
{
    $Package = Add-GcWorksheet -Package $Package -Name $Sheet.Name -TableName $Sheet.Table -Rows $Sheet.Rows -Columns $Sheet.Columns
}

# Intune Plan formulas.
$PlanSheet = $Package.Workbook.Worksheets['Intune Plan']

for ($i = 0; $i -lt $PlanData.Count; $i++)
{
    $RowNumber = $i + 2
    $Total = [System.Collections.ArrayList]::new()
    $Ready = [System.Collections.ArrayList]::new()

    foreach ($Sheet in $IntuneSheets)
    {
        $PolicyRange  = Get-ColumnRange -Sheet $Sheet -Column 'Intune policy'
        $MigrateRange = Get-ColumnRange -Sheet $Sheet -Column 'Migrate to Intune?'
        [void]$Total.Add("COUNTIFS($PolicyRange,`$A$RowNumber,$MigrateRange,`"Yes*`")")
        [void]$Ready.Add("COUNTIFS($PolicyRange,`$A$RowNumber,$MigrateRange,`"Yes`")")
    }

    $PlanSheet.Cells[$RowNumber, 2].Formula = ($Total -join '+')
    $PlanSheet.Cells[$RowNumber, 3].Formula = ($Ready -join '+')
    $PlanSheet.Cells[$RowNumber, 4].Formula = "B$($RowNumber)-C$($RowNumber)"
}

$PlanSheet.Column(1).Width = 50
$PlanSheet.Column(2).Width = 20
$PlanSheet.Column(3).Width = 10
$PlanSheet.Column(4).Width = 10
$PlanSheet.View.FreezePanes(2, 1)

# Summary formulas and links (row 1 = title, row 2 = header).
$SummarySheet = $Package.Workbook.Worksheets['Summary']

for ($i = 0; $i -lt $SummaryItems.Count; $i++)
{
    $RowNumber = $i + 3
    $Item = $SummaryItems[$i]
    $SummarySheet.Cells[$RowNumber, 2].Formula = $Item.Formula

    if ($Item.Link -ne '')
    {
        $Cell = $SummarySheet.Cells[$RowNumber, 1]
        $Cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$($Item.Link)'!A1", $Item.Item)
        $Cell.Style.Font.UnderLine = $true
        $Cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(5, 99, 193))
    }
}

$SummarySheet.Column(1).Width = 32
$SummarySheet.Column(2).Width = 10
$SummarySheet.Column(3).Width = 100
$SummarySheet.Column(3).Style.WrapText = $true

# Colours.
$ActionColors  = @{ 'Changed' = 'FFF2CC'; 'Review' = 'F8CBAD'; 'Moved in' = 'DDEBF7' }
$MigrateColors = @{ 'Yes' = 'E2EFDA'; 'Yes – find setting' = 'FFF2CC'; 'Yes – fix mapping' = 'F8CBAD'; 'No*' = 'EDEDED' }

foreach ($Sheet in $Sheets)
{
    $Worksheet = $Package.Workbook.Worksheets[$Sheet.Name]
    Set-GcCellColors -Sheet $Worksheet -Column 'Action' -Colors $ActionColors
    Set-GcCellColors -Sheet $Worksheet -Column 'Migrate to Intune?' -Colors $MigrateColors
}

try
{
    [OfficeOpenXml.CalculationExtension]::Calculate($Package.Workbook)
}
catch
{
    Write-Verbose "Formulas not calculated before saving: $($_.Exception.Message)"
}
Close-ExcelPackage $Package

# ------------------------------------------------------------
# Console summary
# ------------------------------------------------------------

$TotalMigrate = 0
$TotalReady = 0

foreach ($Policy in $Policies)
{
    $TotalMigrate += $PolicyCounts[$Policy].Total
    $TotalReady += $PolicyCounts[$Policy].Ready
}

$HardeningSettingCount = @($HardeningRows | Where-Object { $_.Area -ne 'Windows Firewall rule' }).Count
$HardeningRuleCount = $HardeningRows.Count - $HardeningSettingCount

Write-Host ""
Write-Host "Baseline settings:        $($BaselineRows.Count)"
Write-Host "Baseline firewall rules:  $($FirewallOutput.Count)"
Write-Host "Hardening settings:       $HardeningSettingCount (+ $HardeningRuleCount firewall rules; $RetiredRuleCount hardening rules are baseline rules)"

foreach ($Site in $Sites)
{
    Write-Host "Branding $($Site):$(' ' * [math]::Max(1, (16 - $Site.Length)))$(@($BrandingRows[$Site]).Count)"
}

Write-Host "Decisions:                $($Decisions.Count)"
Write-Host "Retired & moved:          $($RetiredRows.Count)"
Write-Host "Not migrated to Intune:   $($NotMigrated.Count)"
Write-Host "Intune: to migrate $TotalMigrate, ready $TotalReady, to do $($TotalMigrate - $TotalReady)"

if ($Warnings.Count -gt 0)
{
    Write-Host "$($Warnings.Count) warning(s); see the Summary sheet."
}

Write-Host "Workbook written to: $OutputPath"
