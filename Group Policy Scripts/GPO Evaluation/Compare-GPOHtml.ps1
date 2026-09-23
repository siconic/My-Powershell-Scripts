<#
.SYNOPSIS
Compare gpresult /h (RSoP) HTML reports.

.DESCRIPTION
Processes one or more HTML reports produced by "gpresult /h" or the GPMC
"Group Policy Results" wizard, and generates comparison, deprecated-policy,
and Intune migration reports.

DIFFERENT FROM Compare-GPOXml.ps1:
An HTML report is the RESOLVED (RSoP) policy for one computer/user at the
time it was captured, not the raw contents of one GPO. Each setting is
tagged with the GPO that actually won it (WinningGPO). Because of this,
each input HTML file is called a "report" here, not a "GPO" - in practice
this script is for comparing the same computer/user under different
conditions (a different OU, before/after a change, different sites), not
for comparing unlinked GPOs against each other.

Settings are compared case-insensitively. HTML parsing is performed by
GPOCompareHtml.psm1 using the Windows HTMLFile COM object (mshtml) - see
the comment at the top of that file if reports fail to load.

Reports written to OutputFolder:

ParsedSettings.csv
    Every parsed setting, including which GPO won it (WinningGPO).

CommonSettings.csv
    Exact match: identical Class, Extension, Category, SettingName and
    Value in every report.

CommonSettingsByName.csv
    Setting present in every report regardless of value.
    SameValueEverywhere = False means the values differ between reports.

UniqueSettings.csv
    Setting present in some reports but not all.

ConflictingSettings.csv
    Setting present in more than one report with different values.

DuplicateSettings.csv
    Setting present identically in more than one report.

DeprecatedPolicies.csv
    Settings that match DeprecatedPoliciesReference.md.

MissingSettingsMatrix.csv
    Present / Missing per report for every setting name.

FirewallRules.csv
    Raw inventory of every firewall rule (Inbound and Outbound) parsed from
    every report, with its resolved detail fields (Enabled, Program,
    Action, Protocol, ports, scopes, Profile) and WinningGPO. One row per
    rule per report.

FirewallRulesCommon.csv
    A rule (matched by Name + Direction) present in every report with the
    same configuration (WinningGPO excluded from the comparison, since it
    can differ across reports even for an identical effective rule).

FirewallRulesUnique.csv
    A rule present in only some reports, or present in every report but
    with a different configuration in at least one. PresentIn lists the
    reports; ConfigurationDiffers is True when the reports that do have the
    rule disagree on its configuration.

FirewallSettingsCommon.csv
    Firewall profile settings (Domain / Private / Public), firewall global
    settings, and Windows Defender Firewall Administrative Template
    policies present in every report with the same value. These settings
    are not included in CommonSettings.csv or the other settings
    comparison files.

FirewallSettingsUnique.csv
    The same firewall settings, present in only some reports or with a
    different value in at least one. ValueDiffers is True when the reports
    that have the setting disagree on its value.

IntuneMigrationCandidates.csv
    Every setting with its Intune mapping from the mapping file, plus a
    Deprecated flag.

UnclassifiedSettings.csv
    Table shapes this parser does not recognize, and rows with no setting
    name. Anything listed here is NOT part of the comparison reports. This
    is expected to be non-zero more often than the XML tool's equivalent:
    RSoP HTML has a long tail of report-only formats (Preferences items,
    certain summary tables) this version does not parse.

ParserFailures.csv
    HTML files that could not be parsed at all.

FirewallDiagnostics.csv
    One row per firewall rule table found in each report: its direction,
    how many rule rows it had, how many detail tables were found, and how
    many rules were added to FirewallRules.csv. A report where no firewall
    rule table was recognized gets one row saying so. Use this when the
    firewall files are empty to see which step failed.

RunStatistics.csv
    Counts for the run.

.PARAMETER HtmlFolder
Folder containing gpresult /h HTML reports.

.PARAMETER OutputFolder
Folder where generated reports are written. Created if it does not exist.

.PARAMETER ModulePath
Path to GPOCompareHtml.psm1. Default: next to this script.

.PARAMETER IntuneMappingPath
Path to the Intune mapping file (same format/file as Compare-GPOXml.ps1
uses). Default: intunemapping.json next to this script. Optional: if
missing, a warning is shown and the run continues.

.PARAMETER DeprecatedReferencePath
Path to DeprecatedPoliciesReference.md (same file the XML tool uses).
Default: next to this script. Optional: if missing, a warning is shown and
no deprecated matches are reported.

.PARAMETER FilePrefix
Text added to the start of every output file name, followed by a hyphen.
For example, LS writes LS-CommonSettings.csv instead of CommonSettings.csv.
If this parameter is not given, the script asks for the prefix; press Enter
for no prefix. Pass -FilePrefix "" to skip the question and use no prefix.
In a session that cannot ask (for example -NonInteractive), no prefix is
used.

.EXAMPLE
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output-Html"

.EXAMPLE
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output-Html" -FilePrefix LS

.NOTES
Author:  Siconic
Version: 1.10

Versioning: MAJOR bumps mean restructured logic or a changed CSV/report
schema (something that could break a workflow built on the old output).
MINOR bumps are bug fixes and additions that don't change existing columns
or behavior. GPOCompareHtml.psm1 is versioned in lockstep with this script.

Changelog:
  1.10 - New -FilePrefix parameter. The prefix and a hyphen are added to
         the start of every output file name (LS-CommonSettings.csv). If
         the parameter is not given, the script asks for it; an empty
         answer keeps the original file names. No module changes; the
         module version is kept in lockstep.
  1.9 - GPOCompareHtml.psm1: the report title table is skipped. Its
        "Data collected on: <date/time>" row was recorded as a setting, so
        reports taken at different times always showed it as a unique or
        conflicting setting. No changes to this script; the version is
        kept in lockstep.
  1.8 - Firewall profile settings (Domain / Private / Public), firewall
        global settings, and Windows Defender Firewall Administrative
        Template policies are removed from the settings comparison files
        (CommonSettings, CommonSettingsByName, UniqueSettings,
        ConflictingSettings, DuplicateSettings, MissingSettingsMatrix) and
        compared in two new files: FirewallSettingsCommon.csv and
        FirewallSettingsUnique.csv. They remain in ParsedSettings.csv and
        IntuneMigrationCandidates.csv. No module changes; the module
        version is kept in lockstep.
  1.7 - GPOCompareHtml.psm1: firewall rules can no longer appear in the
        settings files (ParsedSettings, CommonSettings and the other
        comparisons). A rule whose detail table is not found is still
        written to the firewall files, with its detail columns blank.
        Firewall profile and global settings (Firewall state, logging and
        so on) are not rules and still appear in the settings files.
  1.6 - Firewall rules still were not reaching the firewall files in 1.5.
        Rule tables are now recognized by their column headers (Name |
        Description | Winning GPO) rather than by finding the Inbound Rules
        heading, and direction comes from the nearest Inbound/Outbound
        heading earlier in the document. Rows, cells and detail rows are now
        read through .children and the table's own row list instead of
        nextSibling, .rows and .cells, which may not behave the same in the
        Windows HTMLFile object. New FirewallDiagnostics.csv shows, per
        report, which step fails if rules are still missing.
  1.5 - GPOCompareHtml.psm1: row and cell lookups now read only a table's
        own rows and a row's own cells. The old lookup searched every depth,
        so no firewall rule's detail table was ever found and rules landed
        in CommonSettings.csv instead of the firewall files. Also fixes
        list-style ADMX values not being folded into Value. Expect
        ParsedSettings.csv and the comparison files to change slightly.
  1.4 - Firewall rules split into their own comparison, matching the
        pattern used for regular settings: FirewallRulesCommon.csv (a rule
        - matched by Name + Direction - present in every report with the
        same configuration) and FirewallRulesUnique.csv (present in only
        some reports, or with a differing configuration). FirewallRules.csv
        remains the raw per-report inventory. Also fixed
        GPOCompareHtml.psm1's Get-Attribute, which is why FirewallRules.csv
        was coming back empty: it used getAttributeNode(name), case-
        sensitive in the HTMLFile COM document mode, querying 'colSpan'
        against gpresult's lowercase 'colspan' attribute - silently
        returning null instead of throwing, which broke every nested-
        detail-table lookup. Switched to the case-insensitive getAttribute.
  1.3 - GPOCompareHtml.psm1: replaced all 4 uses of the "{0}={1}" -f
        composite-format operator with plain string interpolation,
        matching the same fix already applied to GPOCompare.psm1 for the
        same reported error.
  1.2 - GPOCompareHtml.psm1: fixed the actual reported source of "The
        property 'Count' cannot be found on this object" - Get-AllTags (26
        call sites) and Get-HeadingAncestors (4 call sites) both return an
        ArrayList that PowerShell's pipeline silently unwraps to a bare
        scalar when exactly one item is found, and every call site now
        forces array context with @(...) so a later .Count check can't
        break. This is common: single-<td> rows and single-<th> header
        tables both occur throughout a typical report.
  1.1 - GPOCompareHtml.psm1: guarded three unguarded sibling-walk .tagName
        accesses (Get-NestedDetailRows, System Services parsing) behind a
        new Get-NodeTagName helper, matching the one walk that was already
        guarded; parser-error Reason text now includes the module line
        number that threw.
  1.0 - Initial version. Not yet run against a live PowerShell session at
        time of writing; validated by re-implementing the same DOM-walk
        algorithm in Python against three real gpresult /h reports.

Requires Windows PowerShell with the HTMLFile COM object available
(standard on Windows with the IE engine present). Not tested on PowerShell 7.

After a run, check Unclassified and ParseFailures in RunStatistics.csv
before trusting the comparison reports.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HtmlFolder,

    [Parameter(Mandatory)]
    [string]$OutputFolder,

    [string]$ModulePath = (Join-Path $PSScriptRoot "GPOCompareHtml.psm1"),

    [string]$IntuneMappingPath = (Join-Path $PSScriptRoot "intunemapping.json"),

    [string]$DeprecatedReferencePath = (Join-Path $PSScriptRoot "DeprecatedPoliciesReference.md"),

    [string]$FilePrefix
)

$ErrorActionPreference = "Stop"

$Sep = [string][char]0x1F

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $HtmlFolder -PathType Container))
{
    throw "HTML folder not found: $HtmlFolder"
}

if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf))
{
    throw "Module not found: $ModulePath"
}

if (-not (Test-Path -LiteralPath $OutputFolder))
{
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).ProviderPath

# ------------------------------------------------------------
# Output file name prefix
# ------------------------------------------------------------

# When -FilePrefix is not given, ask for it. An empty answer means no
# prefix. In a non-interactive session Read-Host fails, and no prefix is
# used.
if (-not $PSBoundParameters.ContainsKey('FilePrefix'))
{
    try
    {
        $FilePrefix = Read-Host "Output file name prefix (for example LS). Press Enter for no prefix"
    }
    catch
    {
        $FilePrefix = ""
    }
}

$FilePrefix = "$($FilePrefix)".Trim().TrimEnd('-')

if ($FilePrefix.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0)
{
    throw "FilePrefix contains a character that is not allowed in a file name: $FilePrefix"
}

# Added to the start of every output file name, for example "LS-".
$FileNamePrefix = ""

if ($FilePrefix -ne "")
{
    $FileNamePrefix = "$($FilePrefix)-"
    Write-Host "Output file prefix: $FileNamePrefix"
}
else
{
    Write-Host "Output file prefix: (none)"
}

# ------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------

function Export-Report
{
    param(
        [AllowNull()]
        [object]$Data,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Path = Join-Path $OutputFolder "$($FileNamePrefix)$($Name)"

    $Rows = @()

    if ($null -ne $Data)
    {
        $Rows = @($Data)
    }

    if ($Rows.Count -eq 0)
    {
        [System.IO.File]::WriteAllText($Path, "")
        return
    }

    $Rows |
    Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Import-IntuneMapping
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Warning "Intune mapping file not found: $Path - continuing without Intune mapping (MappingStatus will be MappingFileMissing)."
        return $null
    }

    try
    {
        $Catalog =
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        throw "Failed to load Intune mapping file '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $Catalog -or $null -eq $Catalog.mappings)
    {
        throw "Invalid Intune mapping file '$Path': missing 'mappings' array."
    }

    return $Catalog
}

function Test-IntuneMappingField
{
    param(
        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    if (
        $null -eq $Expected -or
        [string]::IsNullOrWhiteSpace([string]$Expected) -or
        [string]$Expected -eq '*'
    )
    {
        return $true
    }

    return ([string]$Expected -ieq [string]$Actual)
}

$script:IntuneMappingCache = @{}

function Get-IntuneMapping
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Setting,

        [AllowNull()]
        [object]$Catalog
    )

    if ($null -eq $Catalog)
    {
        return $null
    }

    $CacheKey =
        @($Setting.Class, $Setting.Extension, $Setting.Category, $Setting.SettingName) -join $Sep

    if ($script:IntuneMappingCache.ContainsKey($CacheKey))
    {
        return $script:IntuneMappingCache[$CacheKey]
    }

    $Best            = $null
    $BestSpecificity = -1

    foreach ($Map in @($Catalog.mappings))
    {
        if (
            (Test-IntuneMappingField $Map.class $Setting.Class) -and
            (Test-IntuneMappingField $Map.extension $Setting.Extension) -and
            (Test-IntuneMappingField $Map.category $Setting.Category) -and
            (Test-IntuneMappingField $Map.settingName $Setting.SettingName)
        )
        {
            $Specificity = 0

            foreach ($Field in @('class', 'extension', 'category', 'settingName'))
            {
                $FieldValue = [string]$Map.$Field

                if (-not [string]::IsNullOrWhiteSpace($FieldValue) -and $FieldValue -ne '*')
                {
                    $Specificity++
                }
            }

            if ($Specificity -gt $BestSpecificity)
            {
                $Best            = $Map
                $BestSpecificity = $Specificity
            }
        }
    }

    $script:IntuneMappingCache[$CacheKey] = $Best

    return $Best
}

# ------------------------------------------------------------
# Load Module and Reference Data
# ------------------------------------------------------------

Import-Module -Name $ModulePath -Force

Import-DeprecatedPolicyReference `
    -Path $DeprecatedReferencePath

$IntuneMappingCatalog =
    Import-IntuneMapping `
        -Path $IntuneMappingPath

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

$AllSettings     = [System.Collections.ArrayList]::new()
$AllFirewall     = [System.Collections.ArrayList]::new()
$AllUnclassified = [System.Collections.ArrayList]::new()
$FirewallDiagnostics = [System.Collections.ArrayList]::new()
$Failures        = [System.Collections.ArrayList]::new()
$ParsedReports   = [System.Collections.Generic.List[string]]::new()

# ------------------------------------------------------------
# Load HTML Files
# ------------------------------------------------------------

$HtmlFiles =
    @(
        Get-ChildItem `
            -LiteralPath $HtmlFolder `
            -Include *.html, *.htm `
            -File `
            -Recurse:$false
    )

if ($HtmlFiles.Count -lt 1)
{
    throw "No HTML files found in: $HtmlFolder"
}

Write-Host ""
Write-Host "HTML Files Found: $($HtmlFiles.Count)"
Write-Host ""

# ------------------------------------------------------------
# Parse Files
# ------------------------------------------------------------

foreach ($HtmlFile in $HtmlFiles)
{
    Write-Host ""
    Write-Host "================================"
    Write-Host "Processing: $($HtmlFile.Name)"
    Write-Host "================================"
    Write-Host ""

    try
    {
        $Result =
            Get-GPOSettingsFromHtml `
                -Path $HtmlFile.FullName `
                -ReportName $HtmlFile.BaseName

        foreach ($Item in $Result.Settings)
        {
            [void]$AllSettings.Add($Item)
        }

        foreach ($Item in $Result.FirewallRules)
        {
            [void]$AllFirewall.Add($Item)
        }

        foreach ($Item in $Result.Unclassified)
        {
            [void]$AllUnclassified.Add($Item)
        }

        foreach ($Item in $Result.Diagnostics.FirewallTableInfo)
        {
            [void]$FirewallDiagnostics.Add($Item)
        }

        if ($Result.Diagnostics.FirewallTablesFound -eq 0)
        {
            [void]$FirewallDiagnostics.Add(
                [PSCustomObject]@{
                    ReportName        = $HtmlFile.BaseName
                    Headers           = '(no firewall rule table recognized)'
                    Direction         = ''
                    DirectionSource   = ''
                    TableRows         = 0
                    RuleRows          = 0
                    DetailTablesFound = 0
                    RulesAdded        = 0
                }
            )
        }

        $ParsedReports.Add($HtmlFile.BaseName)

        Write-Host "Settings      : $($Result.Settings.Count)"
        Write-Host "FirewallRules : $($Result.FirewallRules.Count)"
        Write-Host "Unclassified  : $($Result.Unclassified.Count)"

        if ($Result.Unclassified.Count -gt 0)
        {
            Write-Warning "$($HtmlFile.BaseName): $($Result.Unclassified.Count) unclassified entries (see $($FileNamePrefix)UnclassifiedSettings.csv)."
        }
    }
    catch
    {
        Write-Warning $_.Exception.Message

        [void]$Failures.Add(
            [PSCustomObject]@{
                ReportName = $HtmlFile.BaseName
                Error      = $_.Exception.Message
            }
        )
    }
}

# ------------------------------------------------------------
# Export Raw Parser Output
# ------------------------------------------------------------

$FirewallOutput = @($AllFirewall)

if (
    $null -ne $IntuneMappingCatalog -and
    $null -ne $IntuneMappingCatalog.firewallRuleMapping
)
{
    $FirewallIntuneType = $IntuneMappingCatalog.firewallRuleMapping.intuneType

    $FirewallOutput =
        @(
            $AllFirewall |
            Select-Object *, @{ Name = 'IntuneType'; Expression = { $FirewallIntuneType } }
        )
}

Export-Report $AllSettings     "ParsedSettings.csv"
Export-Report $FirewallOutput  "FirewallRules.csv"
Export-Report $AllUnclassified "UnclassifiedSettings.csv"
Export-Report $Failures        "ParserFailures.csv"
Export-Report $FirewallDiagnostics "FirewallDiagnostics.csv"

if ($AllSettings.Count -eq 0)
{
    throw "No settings were parsed from any HTML file. See $($FileNamePrefix)ParserFailures.csv and $($FileNamePrefix)UnclassifiedSettings.csv in $OutputFolder"
}

# ------------------------------------------------------------
# Build Report List
# ------------------------------------------------------------

$AllReports   = @($ParsedReports | Sort-Object -Unique)
$TotalReports = $AllReports.Count

$ReportsWithSettings = @($AllSettings.ReportName | Sort-Object -Unique)

foreach ($ReportName in $AllReports)
{
    if ($ReportsWithSettings -notcontains $ReportName)
    {
        Write-Warning "$ReportName parsed but produced no settings."
    }
}

# ------------------------------------------------------------
# Firewall Rules: Common vs Unique
# ------------------------------------------------------------
# A rule's identity is Name + Direction. Everything else (Enabled, Profile,
# Action, Program, Protocol, ports, scopes, Security, Service, Group,
# Description) is its configuration, compared across reports the same way
# regular settings are - WinningGPO is excluded from the comparison, same
# as the settings comparison above, since it can differ across reports even
# when the effective rule is identical.

$FirewallConfigFields = @(
    'Enabled', 'Profile', 'Action', 'Program', 'Protocol',
    'LocalPort', 'RemotePort', 'LocalScope', 'RemoteScope',
    'Security', 'Service', 'Group', 'Description'
)

function Get-FirewallConfigValue
{
    param($Rule)

    (
        $FirewallConfigFields |
        ForEach-Object { "$_=$($Rule.$_)" }
    ) -join $Sep
}

$FirewallByIdentity = @{}

foreach ($Rule in $AllFirewall)
{
    $IdentityKey = @($Rule.Name, $Rule.Direction) -join $Sep

    if (-not $FirewallByIdentity.ContainsKey($IdentityKey))
    {
        $FirewallByIdentity[$IdentityKey] = [System.Collections.ArrayList]::new()
    }

    [void]$FirewallByIdentity[$IdentityKey].Add($Rule)
}

$FirewallCommon = [System.Collections.ArrayList]::new()
$FirewallUnique = [System.Collections.ArrayList]::new()

foreach ($IdentityKey in ($FirewallByIdentity.Keys | Sort-Object))
{
    $Rules = $FirewallByIdentity[$IdentityKey]

    $ByReport = @{}

    foreach ($Rule in $Rules)
    {
        if (-not $ByReport.ContainsKey($Rule.ReportName))
        {
            $ByReport[$Rule.ReportName] = [System.Collections.Generic.List[string]]::new()
        }

        $ByReport[$Rule.ReportName].Add((Get-FirewallConfigValue $Rule))
    }

    $ReportCount = $ByReport.Count

    $Signatures =
        @(
            foreach ($ReportName in $ByReport.Keys)
            {
                (@($ByReport[$ReportName] | Sort-Object -Unique)) -join $Sep
            }
        )

    $SignatureCount = @($Signatures | Sort-Object -Unique).Count

    if ($ReportCount -eq $TotalReports -and $SignatureCount -eq 1)
    {
        $First = $Rules[0]

        $Row = [ordered]@{
            Name      = $First.Name
            Direction = $First.Direction
        }

        foreach ($Field in $FirewallConfigFields)
        {
            $Row[$Field] = $First.$Field
        }

        $Row['PresentIn'] = (@($Rules.ReportName | Sort-Object -Unique) -join "; ")

        [void]$FirewallCommon.Add([PSCustomObject]$Row)
    }
    else
    {
        $ConfigMap = @{}

        foreach ($Rule in $Rules)
        {
            $ConfigKey = Get-FirewallConfigValue $Rule

            if (-not $ConfigMap.ContainsKey($ConfigKey))
            {
                $ConfigMap[$ConfigKey] = @{
                    Item    = $Rule
                    Reports = [System.Collections.Generic.HashSet[string]]::new()
                }
            }

            [void]$ConfigMap[$ConfigKey].Reports.Add($Rule.ReportName)
        }

        foreach ($ConfigKey in ($ConfigMap.Keys | Sort-Object))
        {
            $Entry = $ConfigMap[$ConfigKey]

            $Row = [ordered]@{
                Name      = $Entry.Item.Name
                Direction = $Entry.Item.Direction
            }

            foreach ($Field in $FirewallConfigFields)
            {
                $Row[$Field] = $Entry.Item.$Field
            }

            $Row['PresentIn']          = (@($Entry.Reports | Sort-Object) -join "; ")
            $Row['PresentInCount']     = $ReportCount
            $Row['ConfigurationDiffers'] = ($SignatureCount -gt 1)

            [void]$FirewallUnique.Add([PSCustomObject]$Row)
        }
    }
}


# ------------------------------------------------------------
# Firewall Profile and Global Settings: Common vs Unique
# ------------------------------------------------------------
# Firewall profile settings (Domain / Private / Public), global settings,
# and Windows Defender Firewall Administrative Template policies are taken
# out of the regular settings comparison and compared on their own, the
# same way firewall rules are. They stay in ParsedSettings.csv (the full
# raw list) and in IntuneMigrationCandidates.csv.
#
# Common = present in every report with the same value.
# Unique = present in only some reports, or with a different value in at
#          least one report (ValueDiffers = True).

function Test-IsFirewallSetting
{
    param($Setting)

    $Text = "$($Setting.Extension) / $($Setting.Category)"

    return (
        $Text -match '(?i)Windows Firewall with Advanced Security' -or
        $Text -match '(?i)Windows Defender Firewall' -or
        $Text -match '(?i)(^| / )Windows Firewall( / |$)'
    )
}

$FirewallSettingsAll = [System.Collections.ArrayList]::new()
$CompareSettings     = [System.Collections.ArrayList]::new()

foreach ($Setting in $AllSettings)
{
    if (Test-IsFirewallSetting $Setting)
    {
        [void]$FirewallSettingsAll.Add($Setting)
    }
    else
    {
        [void]$CompareSettings.Add($Setting)
    }
}

$FirewallSettingsByName = @{}

foreach ($Setting in $FirewallSettingsAll)
{
    $NameKey =
        @(
            $Setting.Class
            $Setting.Extension
            $Setting.Category
            $Setting.SettingName
        ) -join $Sep

    if (-not $FirewallSettingsByName.ContainsKey($NameKey))
    {
        $FirewallSettingsByName[$NameKey] = [System.Collections.ArrayList]::new()
    }

    [void]$FirewallSettingsByName[$NameKey].Add($Setting)
}

$FirewallSettingsCommon = [System.Collections.ArrayList]::new()
$FirewallSettingsUnique = [System.Collections.ArrayList]::new()

foreach ($NameKey in ($FirewallSettingsByName.Keys | Sort-Object))
{
    $Items = $FirewallSettingsByName[$NameKey]

    $ByReport = @{}

    foreach ($Item in $Items)
    {
        if (-not $ByReport.ContainsKey($Item.ReportName))
        {
            $ByReport[$Item.ReportName] = [System.Collections.Generic.List[string]]::new()
        }

        $ByReport[$Item.ReportName].Add($Item.Value)
    }

    $Signatures =
        @(
            foreach ($ReportName in $ByReport.Keys)
            {
                (@($ByReport[$ReportName] | Sort-Object -Unique)) -join $Sep
            }
        )

    $ReportCount    = $ByReport.Count
    $SignatureCount = @($Signatures | Sort-Object -Unique).Count

    if ($ReportCount -eq $TotalReports -and $SignatureCount -eq 1)
    {
        $First = $Items[0]

        [void]$FirewallSettingsCommon.Add(
            [PSCustomObject]@{
                Class       = $First.Class
                Extension   = $First.Extension
                Category    = $First.Category
                SettingName = $First.SettingName
                Value       = $First.Value
                PresentIn   = (@($Items.ReportName | Sort-Object -Unique) -join "; ")
            }
        )

        continue
    }

    $ValueMap = @{}

    foreach ($Item in $Items)
    {
        if (-not $ValueMap.ContainsKey($Item.Value))
        {
            $ValueMap[$Item.Value] = @{
                Item    = $Item
                Reports = [System.Collections.Generic.HashSet[string]]::new()
            }
        }

        [void]$ValueMap[$Item.Value].Reports.Add($Item.ReportName)
    }

    foreach ($ValueKey in ($ValueMap.Keys | Sort-Object))
    {
        $Entry = $ValueMap[$ValueKey]

        [void]$FirewallSettingsUnique.Add(
            [PSCustomObject]@{
                Class          = $Entry.Item.Class
                Extension      = $Entry.Item.Extension
                Category       = $Entry.Item.Category
                SettingName    = $Entry.Item.SettingName
                Value          = $Entry.Item.Value
                PresentIn      = (@($Entry.Reports | Sort-Object) -join "; ")
                PresentInCount = $ReportCount
                ValueDiffers   = ($SignatureCount -gt 1)
            }
        )
    }
}

# ------------------------------------------------------------
# Build Comparison Maps
# ------------------------------------------------------------
# Note: comparisons intentionally ignore WinningGPO. Two reports can agree
# on a setting's effective value while a different GPO won it in each - the
# comparison surfaces the value difference (or absence of one); WinningGPO
# is carried on every row of ParsedSettings.csv for follow-up.

$ExactMap = @{}
$NameMap  = @{}

# Firewall settings are compared separately above.
foreach ($Setting in $CompareSettings)
{
    $NameKey =
        @(
            $Setting.Class
            $Setting.Extension
            $Setting.Category
            $Setting.SettingName
        ) -join $Sep

    $ExactKey = $NameKey + $Sep + $Setting.Value

    if (-not $ExactMap.ContainsKey($ExactKey))
    {
        $ExactMap[$ExactKey] = @{
            Item    = $Setting
            Reports = [System.Collections.Generic.HashSet[string]]::new()
        }
    }

    [void]$ExactMap[$ExactKey].Reports.Add($Setting.ReportName)

    if (-not $NameMap.ContainsKey($NameKey))
    {
        $NameMap[$NameKey] = [System.Collections.ArrayList]::new()
    }

    [void]$NameMap[$NameKey].Add($Setting)
}

$SortedExactKeys = @($ExactMap.Keys | Sort-Object)
$SortedNameKeys  = @($NameMap.Keys | Sort-Object)

$NameInfo = @{}

foreach ($Key in $SortedNameKeys)
{
    $ByReport = @{}

    foreach ($Item in $NameMap[$Key])
    {
        if (-not $ByReport.ContainsKey($Item.ReportName))
        {
            $ByReport[$Item.ReportName] = [System.Collections.Generic.List[string]]::new()
        }

        $ByReport[$Item.ReportName].Add($Item.Value)
    }

    $Signatures =
        @(
            foreach ($Report in $ByReport.Keys)
            {
                (@($ByReport[$Report] | Sort-Object -Unique)) -join $Sep
            }
        )

    $NameInfo[$Key] = [PSCustomObject]@{
        ReportCount    = $ByReport.Count
        SignatureCount = @($Signatures | Sort-Object -Unique).Count
    }
}

# ------------------------------------------------------------
# Common Exact
# ------------------------------------------------------------

$CommonSettings =
    @(
        foreach ($Key in $SortedExactKeys)
        {
            $Entry = $ExactMap[$Key]

            if ($Entry.Reports.Count -eq $TotalReports)
            {
                $Entry.Item
            }
        }
    )

# ------------------------------------------------------------
# Common By Name
# ------------------------------------------------------------

$CommonSettingsByName =
    @(
        foreach ($Key in $SortedNameKeys)
        {
            $Info = $NameInfo[$Key]

            if ($Info.ReportCount -eq $TotalReports)
            {
                $First = $NameMap[$Key][0]

                [PSCustomObject]@{
                    Class               = $First.Class
                    Extension           = $First.Extension
                    Category            = $First.Category
                    SettingName         = $First.SettingName
                    Value               = $First.Value
                    SameValueEverywhere = ($Info.SignatureCount -eq 1)
                }
            }
        }
    )

# ------------------------------------------------------------
# Unique
# ------------------------------------------------------------

$UniqueSettings =
    @(
        foreach ($Key in $SortedNameKeys)
        {
            $Info = $NameInfo[$Key]

            if ($Info.ReportCount -ge $TotalReports)
            {
                continue
            }

            $ConfigMap = @{}

            foreach ($Item in $NameMap[$Key])
            {
                $ConfigKey = $Item.Value

                if (-not $ConfigMap.ContainsKey($ConfigKey))
                {
                    $ConfigMap[$ConfigKey] = @{
                        Item    = $Item
                        Reports = [System.Collections.Generic.HashSet[string]]::new()
                    }
                }

                [void]$ConfigMap[$ConfigKey].Reports.Add($Item.ReportName)
            }

            foreach ($ConfigKey in @($ConfigMap.Keys | Sort-Object))
            {
                $Entry = $ConfigMap[$ConfigKey]

                [PSCustomObject]@{
                    Class          = $Entry.Item.Class
                    Extension      = $Entry.Item.Extension
                    Category       = $Entry.Item.Category
                    SettingName    = $Entry.Item.SettingName
                    Value          = $Entry.Item.Value
                    PresentIn      = (@($Entry.Reports | Sort-Object) -join "; ")
                    PresentInCount = $Info.ReportCount
                    ValuesDiffer   = ($Info.SignatureCount -gt 1)
                }
            }
        }
    )

# ------------------------------------------------------------
# Conflicts
# ------------------------------------------------------------

$ConflictingSettings =
    @(
        foreach ($Key in $SortedNameKeys)
        {
            $Info = $NameInfo[$Key]

            if ($Info.ReportCount -gt 1 -and $Info.SignatureCount -gt 1)
            {
                $NameMap[$Key] | Sort-Object ReportName
            }
        }
    )

# ------------------------------------------------------------
# Duplicates
# ------------------------------------------------------------

$DuplicateSettings =
    @(
        foreach ($Key in $SortedNameKeys)
        {
            $Info = $NameInfo[$Key]

            if ($Info.ReportCount -gt 1 -and $Info.SignatureCount -eq 1)
            {
                $First   = $NameMap[$Key][0]
                $Reports = @($NameMap[$Key].ReportName | Sort-Object -Unique)

                [PSCustomObject]@{
                    Class       = $First.Class
                    Extension   = $First.Extension
                    Category    = $First.Category
                    SettingName = $First.SettingName
                    Value       = $First.Value
                    PresentIn   = ($Reports -join "; ")
                }
            }
        }
    )

# ------------------------------------------------------------
# Deprecated Policy Detection
# ------------------------------------------------------------

$DeprecatedSettings =
    @(
        Get-DeprecatedPolicyMatches `
            -Settings $AllSettings
    )

$DeprecatedLookup = @{}

foreach ($Deprecated in $DeprecatedSettings)
{
    $DeprecatedKey =
        @(
            $Deprecated.ReportName
            $Deprecated.Class
            $Deprecated.Extension
            $Deprecated.Category
            $Deprecated.SettingName
            $Deprecated.Value
        ) -join $Sep

    $DeprecatedLookup[$DeprecatedKey] = $Deprecated
}

# ------------------------------------------------------------
# Missing Matrix
# ------------------------------------------------------------

$Matrix = [System.Collections.Generic.List[object]]::new()

foreach ($Key in $SortedNameKeys)
{
    $Items = $NameMap[$Key]
    $First = $Items[0]

    $Row = [ordered]@{}

    $Row["Setting"] =
        @($First.Class, $First.Extension, $First.Category, $First.SettingName) -join " | "

    foreach ($ReportName in $AllReports)
    {
        $Row[$ReportName] = "Missing"
    }

    foreach ($Item in $Items)
    {
        $Row[$Item.ReportName] = "Present"
    }

    $Matrix.Add([PSCustomObject]$Row)
}

# ------------------------------------------------------------
# Migration Candidates + Intune Mapping
# ------------------------------------------------------------

$MigrationCandidates =
    foreach ($Setting in $AllSettings)
    {
        $Map = Get-IntuneMapping -Setting $Setting -Catalog $IntuneMappingCatalog

        $DeprecatedKey =
            @(
                $Setting.ReportName
                $Setting.Class
                $Setting.Extension
                $Setting.Category
                $Setting.SettingName
                $Setting.Value
            ) -join $Sep

        $DeprecatedMatch = $DeprecatedLookup[$DeprecatedKey]

        if ($null -eq $IntuneMappingCatalog)
        {
            $MappingStatus = 'MappingFileMissing'
            $Confidence    = 'None'
            $MappingNotes  = 'Intune mapping file was not loaded.'
        }
        elseif ($null -ne $Map)
        {
            $MappingStatus = $Map.mappingStatus
            $Confidence    = $Map.confidence
            $MappingNotes  = $Map.notes
        }
        else
        {
            $MappingStatus = 'Unmapped'
            $Confidence    = 'None'
            $MappingNotes  = 'No matching entry in the Intune mapping file.'
        }

        [PSCustomObject]@{
            ReportName             = $Setting.ReportName
            Class                  = $Setting.Class
            Extension              = $Setting.Extension
            Category               = $Setting.Category
            SettingName            = $Setting.SettingName
            Value                  = $Setting.Value
            WinningGPO             = $Setting.WinningGPO
            Deprecated             = if ($null -ne $DeprecatedMatch) { 'Yes' } else { 'No' }
            RecommendedReplacement = if ($null -ne $DeprecatedMatch) { $DeprecatedMatch.RecommendedReplacement } else { $null }
            IntuneType             = if ($null -ne $Map) { $Map.intuneType } else { $null }
            IntuneSetting          = if ($null -ne $Map) { $Map.intuneSetting } else { $null }
            OMAURI                 = if ($null -ne $Map) { $Map.omaUri } else { $null }
            MappingStatus          = $MappingStatus
            Confidence             = $Confidence
            Notes                  = $MappingNotes
        }
    }

$UnmappedCount =
    @(
        $MigrationCandidates |
        Where-Object { $_.MappingStatus -in @('Unmapped', 'MappingFileMissing') }
    ).Count

# ------------------------------------------------------------
# Statistics
# ------------------------------------------------------------

$Statistics =
    [PSCustomObject]@{
        Timestamp             = Get-Date
        HtmlFiles             = $HtmlFiles.Count
        ReportsParsed         = $TotalReports
        Settings              = $AllSettings.Count
        FirewallRules         = $AllFirewall.Count
        FirewallCommon        = @($FirewallCommon).Count
        FirewallUnique        = @($FirewallUnique).Count
        FirewallSettingsCommon = @($FirewallSettingsCommon).Count
        FirewallSettingsUnique = @($FirewallSettingsUnique).Count
        CommonSettings        = @($CommonSettings).Count
        CommonByName          = @($CommonSettingsByName).Count
        UniqueSettings        = @($UniqueSettings).Count
        Conflicts             = @($ConflictingSettings).Count
        Duplicates            = @($DuplicateSettings).Count
        Deprecated            = $DeprecatedSettings.Count
        UnmappedSettings      = $UnmappedCount
        Unclassified          = $AllUnclassified.Count
        ParseFailures         = $Failures.Count
    }

# ------------------------------------------------------------
# Export Reports
# ------------------------------------------------------------

Export-Report $CommonSettings        "CommonSettings.csv"
Export-Report $CommonSettingsByName  "CommonSettingsByName.csv"
Export-Report $UniqueSettings        "UniqueSettings.csv"
Export-Report $ConflictingSettings   "ConflictingSettings.csv"
Export-Report $DuplicateSettings     "DuplicateSettings.csv"
Export-Report $DeprecatedSettings    "DeprecatedPolicies.csv"
Export-Report $Matrix                "MissingSettingsMatrix.csv"
Export-Report $MigrationCandidates   "IntuneMigrationCandidates.csv"
Export-Report $FirewallCommon        "FirewallRulesCommon.csv"
Export-Report $FirewallUnique        "FirewallRulesUnique.csv"
Export-Report $FirewallSettingsCommon "FirewallSettingsCommon.csv"
Export-Report $FirewallSettingsUnique "FirewallSettingsUnique.csv"
Export-Report $Statistics            "RunStatistics.csv"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

$ExpectedReports = @(
    "ParsedSettings.csv"
    "CommonSettings.csv"
    "CommonSettingsByName.csv"
    "UniqueSettings.csv"
    "ConflictingSettings.csv"
    "DuplicateSettings.csv"
    "DeprecatedPolicies.csv"
    "MissingSettingsMatrix.csv"
    "FirewallRules.csv"
    "FirewallRulesCommon.csv"
    "FirewallRulesUnique.csv"
    "FirewallSettingsCommon.csv"
    "FirewallSettingsUnique.csv"
    "IntuneMigrationCandidates.csv"
    "UnclassifiedSettings.csv"
    "ParserFailures.csv"
    "FirewallDiagnostics.csv"
    "RunStatistics.csv"
)

Write-Host ""
Write-Host "Generated Reports"
Write-Host "-----------------"

foreach ($Report in $ExpectedReports)
{
    $File = Join-Path $OutputFolder "$($FileNamePrefix)$($Report)"

    if (Test-Path -LiteralPath $File)
    {
        Write-Host "[OK] $($FileNamePrefix)$($Report)"
    }
    else
    {
        Write-Warning "$($FileNamePrefix)$($Report) missing"
    }
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "====================================="
Write-Host "Report Generation Complete"
Write-Host "====================================="
Write-Host ""

if ($Failures.Count -gt 0)
{
    Write-Warning "$($Failures.Count) HTML file(s) failed to parse and are excluded from the comparison ($($FileNamePrefix)ParserFailures.csv)."
}

if ($AllUnclassified.Count -gt 0)
{
    Write-Warning "$($AllUnclassified.Count) unclassified entries are not part of the comparison ($($FileNamePrefix)UnclassifiedSettings.csv). This is normal for RSoP HTML reports - check the Reason and Category columns to see what was skipped."
}

Write-Host "Reports written to:"
Write-Host $OutputFolder
