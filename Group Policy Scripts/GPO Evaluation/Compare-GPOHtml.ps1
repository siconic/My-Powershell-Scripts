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
    Each setting is first looked up by policy name in IntunePolicyMappings.json
    (mappings imported from manual mapping workbooks by
    Import-IntuneMappingWorkbook.ps1): MappingStatus Mapped or
    NoIntuneEquivalent, IntuneType = the workbook's Intune Setting,
    IntuneSetting = its Intune Sub Setting, Notes = its remarks. Other
    settings use the general rules in the Intune mapping file. MappingSource
    shows which file and workbook each mapping came from. With exclusions
    (-ApplyExclusions or answering Y), settings matched by an enabled entry
    of IntuneMigrationExclusions.json are left out.

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
    Counts for the run. Every other report has a count here that equals its
    number of rows (for example Conflicts for ConflictingSettings.csv).

GPOCompareHtml.xlsx (only with -OutputFormat Excel)
    One workbook, written instead of the CSV files, with one worksheet per
    report in this order: RunStatistics, CommonSettings, UniqueSettings,
    DeprecatedPolicies, FirewallRules, IntuneMigrationCandidates,
    DuplicateSettings, ConflictingSettings, ParsedSettings, then the others.
    Every worksheet is an Excel table with a blue header (table style
    Medium2) and a frozen header row. RunStatistics is shown as a
    Statistic / Value table in the same order as the worksheets; each
    statistic that belongs to a worksheet is a link to it (UnmappedSettings
    links to IntuneMigrationCandidates). Text values are stored exactly as text;
    counts are numbers and True/False values are Excel TRUE/FALSE.

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
.PARAMETER PolicyMappingPath
Path to IntunePolicyMappings.json, the GPO policy to Intune setting
mappings imported from manual mapping workbooks by
Import-IntuneMappingWorkbook.ps1. Default: next to this script. Optional:
if missing, a note is shown and only the general rules in the Intune
mapping file are used. A policy found in this file is mapped from it
first (MappingStatus Mapped or NoIntuneEquivalent, Confidence High); other
settings use the general rules. The default file is scrubbed and has no
remarks; to see remarks and unredacted names internally, import with
-KeepSensitiveData and pass IntunePolicyMappings.Internal.json here.

.PARAMETER ApplyExclusions
Leave the settings matched by the enabled entries of the exclusion file
out of IntuneMigrationCandidates. If this parameter is not given, the
script asks (Y = yes; press Enter for no). -ApplyExclusions:$false skips
the question and uses no exclusions. In a session that cannot ask (for
example -NonInteractive), no exclusions are used. Excluded settings stay
in ParsedSettings and the comparison reports; RunStatistics shows how many
were excluded (ExcludedFromMigration).

.PARAMETER ExclusionPath
Path to the exclusion file. Default: IntuneMigrationExclusions.json next
to this script. Each entry has a name, "enabled" (true or false, to turn
the entry on or off), a class (* = any, Computer, User) and wildcard
patterns matched against "Extension / Category / SettingName" (case
ignored). If the file is missing, a warning is shown and nothing is
excluded.

.PARAMETER FilePrefix
Text added to the start of every output file name, followed by a hyphen.
For example, LS writes LS-CommonSettings.csv instead of CommonSettings.csv.
If this parameter is not given, the script asks for the prefix; press Enter
for no prefix. Pass -FilePrefix "" to skip the question and use no prefix.
In a session that cannot ask (for example -NonInteractive), no prefix is
used.

.PARAMETER OutputFormat
CSV or Excel. CSV writes one CSV file per report. Excel writes one workbook,
GPOCompareHtml.xlsx (with the file name prefix, if one is used), with one worksheet
per report and no CSV files. If this parameter is not given, the script
asks (C or E; press Enter for CSV). In a session that cannot ask (for
example -NonInteractive), CSV is used.

Excel output needs the ImportExcel module; Excel itself is not needed. If
the module is not installed, the script installs it for the current user
from the PowerShell Gallery (Install-Module ImportExcel -Scope CurrentUser,
plus the NuGet package provider if missing). If it cannot be installed, a
warning is shown and the output continues as CSV files. If the workbook
cannot be written (for example, the file is open in Excel), the reports are
written as CSV files instead. A value longer than 32767 characters (the
Excel cell limit) is cut to that length in the workbook, with a warning.

.EXAMPLE
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output-Html"

.EXAMPLE
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output-Html" -FilePrefix LS

.EXAMPLE
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output-Html" -FilePrefix LS -OutputFormat Excel

.NOTES
Author:  Siconic
Version: 2.0

Versioning: MAJOR bumps mean restructured logic, a changed CSV/report
schema (something that could break a workflow built on the old output), or
a major new feature such as a new output format. MINOR bumps are bug fixes
and small additions that don't change existing columns or behavior.
GPOCompareHtml.psm1 is versioned in lockstep with this script.

Changelog:
  2.0 - Excel output. New -OutputFormat parameter (CSV or Excel); if it
        is not given, the script asks. Excel writes one workbook,
        GPOCompareHtml.xlsx, with one worksheet per report and no CSV
        files. Worksheet order: RunStatistics, CommonSettings,
        UniqueSettings, DeprecatedPolicies, FirewallRules,
        IntuneMigrationCandidates, DuplicateSettings, ConflictingSettings,
        ParsedSettings, then the others. Every worksheet is a blue
        (Medium2) Excel table. RunStatistics is a Statistic / Value table
        in worksheet order whose statistics link to their worksheets
        (UnmappedSettings to IntuneMigrationCandidates). RunStatistics.csv
        keeps its column order and has
        new columns at the end (MissingSettingsMatrix,
        IntuneMigrationCandidates, FirewallDiagnostics), so every report has
        a count. If the ImportExcel
        module is missing, the script installs it for the current user;
        if that fails, or the workbook cannot be written, the output is
        CSV files. Settings are first mapped by policy name from
        IntunePolicyMappings.json (-PolicyMappingPath), which
        Import-IntuneMappingWorkbook.ps1 builds from manual mapping
        workbooks; IntuneMigrationCandidates has a new MappingSource
        column and RunStatistics a MappedFromWorkbooks count.
        Optional exclusions (question, or -ApplyExclusions): settings
        matched by an enabled entry of IntuneMigrationExclusions.json
        (firewall, registry, public key policies, ...; each entry can be
        turned on or off) are left out of IntuneMigrationCandidates;
        RunStatistics has an ExcludedFromMigration count.
        No module changes; the module version is kept in lockstep.
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

    [string]$PolicyMappingPath = (Join-Path $PSScriptRoot "IntunePolicyMappings.json"),

    [string]$ExclusionPath = (Join-Path $PSScriptRoot "IntuneMigrationExclusions.json"),

    [string]$FilePrefix,

    [ValidateSet('CSV', 'Excel')]
    [string]$OutputFormat,

    [switch]$ApplyExclusions
)

$ErrorActionPreference = "Stop"

$Sep = [string][char]0x1F

# Every report this script writes. The Excel workbook uses this order for
# its worksheets.
$ExpectedReports = @(
    "RunStatistics.csv"
    "CommonSettings.csv"
    "UniqueSettings.csv"
    "DeprecatedPolicies.csv"
    "FirewallRules.csv"
    "IntuneMigrationCandidates.csv"
    "DuplicateSettings.csv"
    "ConflictingSettings.csv"
    "ParsedSettings.csv"
    "CommonSettingsByName.csv"
    "MissingSettingsMatrix.csv"
    "FirewallRulesCommon.csv"
    "FirewallRulesUnique.csv"
    "FirewallSettingsCommon.csv"
    "FirewallSettingsUnique.csv"
    "FirewallDiagnostics.csv"
    "UnclassifiedSettings.csv"
    "ParserFailures.csv"
)

# RunStatistics value -> the worksheet it belongs to. In the Excel
# workbook, these statistics are links to their worksheet, and the
# RunStatistics rows are shown in this order, which follows the worksheet
# order above. Every worksheet except RunStatistics has a statistic whose
# value is its number of rows. UnmappedSettings is the number of rows on
# IntuneMigrationCandidates with MappingStatus Unmapped; MappedFromWorkbooks
# the number mapped from IntunePolicyMappings.json.
$StatisticWorksheets = [ordered]@{
    CommonSettings            = "CommonSettings"
    UniqueSettings            = "UniqueSettings"
    Deprecated                = "DeprecatedPolicies"
    FirewallRules             = "FirewallRules"
    IntuneMigrationCandidates = "IntuneMigrationCandidates"
    UnmappedSettings          = "IntuneMigrationCandidates"
    MappedFromWorkbooks       = "IntuneMigrationCandidates"
    Duplicates                = "DuplicateSettings"
    Conflicts                 = "ConflictingSettings"
    Settings                  = "ParsedSettings"
    CommonByName              = "CommonSettingsByName"
    MissingSettingsMatrix     = "MissingSettingsMatrix"
    FirewallCommon            = "FirewallRulesCommon"
    FirewallUnique            = "FirewallRulesUnique"
    FirewallSettingsCommon    = "FirewallSettingsCommon"
    FirewallSettingsUnique    = "FirewallSettingsUnique"
    FirewallDiagnostics       = "FirewallDiagnostics"
    Unclassified              = "UnclassifiedSettings"
    ParseFailures             = "ParserFailures"
}

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
# Output format (CSV files or Excel workbook)
# ------------------------------------------------------------

# When -OutputFormat is not given, ask for it. An empty answer means CSV.
# In a non-interactive session Read-Host fails, and CSV is used.
if (-not $PSBoundParameters.ContainsKey('OutputFormat'))
{
    $Answer = ""

    try
    {
        $Answer = Read-Host "Output format: C = CSV files, E = Excel workbook. Press Enter for CSV"
    }
    catch
    {
        $Answer = ""
    }

    $Answer = "$($Answer)".Trim()

    if (($Answer -ieq 'E') -or ($Answer -ieq 'Excel'))
    {
        $OutputFormat = 'Excel'
    }
    elseif (($Answer -eq '') -or ($Answer -ieq 'C') -or ($Answer -ieq 'CSV'))
    {
        $OutputFormat = 'CSV'
    }
    else
    {
        Write-Warning "'$Answer' is not C or E. Output will be CSV files."
        $OutputFormat = 'CSV'
    }
}

# Excel output needs the ImportExcel module. If it is not installed, try to
# install it for the current user from the PowerShell Gallery. If that
# fails, the output continues as CSV files.
if ($OutputFormat -eq 'Excel')
{
    $ImportExcelReady = (@(Get-Module -ListAvailable -Name ImportExcel).Count -gt 0)

    if (-not $ImportExcelReady)
    {
        Write-Host "The ImportExcel module is not installed. Installing it for the current user from the PowerShell Gallery..."

        try
        {
            # The PowerShell Gallery requires TLS 1.2, which Windows
            # PowerShell 5.1 does not always use by default.
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

            # Install-Module needs the NuGet package provider.
            if (@(Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue).Count -eq 0)
            {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
            }

            # -Force skips the question about installing from an untrusted
            # repository (the PowerShell Gallery is untrusted by default).
            Install-Module -Name ImportExcel -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Installing the ImportExcel module failed: $($_.Exception.Message)"
        }

        $ImportExcelReady = (@(Get-Module -ListAvailable -Name ImportExcel).Count -gt 0)

        if ($ImportExcelReady)
        {
            Write-Host "The ImportExcel module is available."
        }
    }

    if ($ImportExcelReady)
    {
        try
        {
            Import-Module ImportExcel -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Loading the ImportExcel module failed: $($_.Exception.Message)"
            $ImportExcelReady = $false
        }
    }

    if (-not $ImportExcelReady)
    {
        Write-Warning "The ImportExcel module could not be installed. Output will continue as CSV files."
        $OutputFormat = 'CSV'
    }
}

$ExcelOutput  = ($OutputFormat -eq 'Excel')
$WorkbookName = "$($FileNamePrefix)GPOCompareHtml.xlsx"
$WorkbookPath = Join-Path $OutputFolder $WorkbookName

if ($ExcelOutput)
{
    Write-Host "Output format: Excel workbook ($WorkbookName)"
}
else
{
    Write-Host "Output format: CSV files"
}

# ------------------------------------------------------------
# Intune migration exclusions (question)
# ------------------------------------------------------------

# When -ApplyExclusions is not given, ask. An empty answer means no. In a
# non-interactive session Read-Host fails, and no exclusions are used. The
# exclusion file is read later, before IntuneMigrationCandidates is built.
if ($PSBoundParameters.ContainsKey('ApplyExclusions'))
{
    $UseExclusions = [bool]$ApplyExclusions
}
else
{
    $Answer = ""

    try
    {
        $Answer = Read-Host "Exclude settings from IntuneMigrationCandidates using $([System.IO.Path]::GetFileName($ExclusionPath))? Y = yes. Press Enter for no"
    }
    catch
    {
        $Answer = ""
    }

    $UseExclusions = "$($Answer)".Trim() -match '^(?i)(y|yes)$'
}

# Reports collected by Export-Report for the Excel workbook.
$ExcelSheets = [System.Collections.ArrayList]::new()

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

    $Rows = @()

    if ($null -ne $Data)
    {
        $Rows = @($Data)
    }

    # Excel output: keep the rows for the workbook, which is written by
    # Save-ExcelOutput. No CSV file is written.
    if ($ExcelOutput)
    {
        [void]$ExcelSheets.Add(
            [PSCustomObject]@{
                Name = [System.IO.Path]::GetFileNameWithoutExtension($Name)
                Rows = $Rows
            }
        )

        return
    }

    Write-CsvReport -Rows $Rows -Name $Name
}

function Write-CsvReport
{
    param(
        [AllowNull()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Path = Join-Path $OutputFolder "$($FileNamePrefix)$($Name)"

    if ($null -eq $Rows)
    {
        $Rows = @()
    }

    # Export-Csv writes nothing for empty input; create an empty file instead
    # so every report exists.
    if ($Rows.Count -eq 0)
    {
        [System.IO.File]::WriteAllText($Path, "")
        return
    }

    $Rows |
    Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-ReportLocation
{
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Where a report can be found, for messages: its CSV file, or its
    # worksheet in the Excel workbook.
    if ($ExcelOutput)
    {
        return "the $([System.IO.Path]::GetFileNameWithoutExtension($Name)) worksheet in $WorkbookName"
    }

    return "$($FileNamePrefix)$($Name)"
}

function Save-ExcelOutput
{
    # Writes the reports collected by Export-Report to the Excel workbook,
    # with the worksheets in $ExpectedReports order. After an early stop,
    # only the reports collected so far are included. If the workbook
    # cannot be written, the same reports are written as CSV files instead.
    $OrderedSheets = [System.Collections.ArrayList]::new()

    foreach ($Report in $ExpectedReports)
    {
        $SheetName = [System.IO.Path]::GetFileNameWithoutExtension($Report)

        foreach ($Sheet in @($ExcelSheets | Where-Object { $_.Name -eq $SheetName }))
        {
            [void]$OrderedSheets.Add($Sheet)
        }
    }

    try
    {
        Export-ExcelWorkbook -Path $WorkbookPath -Sheets @($OrderedSheets)
    }
    catch
    {
        Write-Warning "Writing the Excel workbook failed: $($_.Exception.Message). Writing CSV files instead."

        # Remove a partly written workbook. If it is locked (for example,
        # open in Excel), leave it and continue with the CSV files.
        try
        {
            if (Test-Path -LiteralPath $WorkbookPath)
            {
                Remove-Item -LiteralPath $WorkbookPath -Force -ErrorAction Stop
            }
        }
        catch
        {
        }

        $script:ExcelOutput = $false

        foreach ($Sheet in $OrderedSheets)
        {
            Write-CsvReport -Rows @($Sheet.Rows) -Name "$($Sheet.Name).csv"
            Write-Host "[OK] $($FileNamePrefix)$($Sheet.Name).csv"
        }

        return
    }

    if (Test-Path -LiteralPath $WorkbookPath)
    {
        Write-Host "[OK] $WorkbookName ($($OrderedSheets.Count) worksheets)"
    }
    else
    {
        Write-Warning "$WorkbookName missing"
    }
}

function ConvertTo-ExcelSheetRows
{
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    # An Excel cell holds at most 32767 characters. Longer values are cut to
    # that length in the workbook only; the CSV files keep the full value.
    $MaxCellLength = 32767

    $Output    = [System.Collections.ArrayList]::new()
    $Truncated = 0

    # Export-Excel writes any text that starts with "=" as a formula, and has
    # no option to turn this off. These cells are recorded here so that
    # Export-ExcelWorkbook can write their text back as plain text.
    $TextCells = [System.Collections.ArrayList]::new()

    # Row 1 of the worksheet is the header row.
    $RowNumber = 1

    foreach ($Row in @($Rows))
    {
        $RowNumber++
        $ColumnNumber = 0
        $Copy = [ordered]@{}

        foreach ($Property in $Row.PSObject.Properties)
        {
            $ColumnNumber++
            $Value = $Property.Value

            if (($Value -is [string]) -and ($Value.Length -gt $MaxCellLength))
            {
                $Value = $Value.Substring(0, $MaxCellLength)
                $Truncated++
            }

            if (($Value -is [string]) -and $Value.StartsWith('='))
            {
                [void]$TextCells.Add(
                    [PSCustomObject]@{
                        Row    = $RowNumber
                        Column = $ColumnNumber
                        Value  = $Value
                    }
                )
            }

            $Copy[$Property.Name] = $Value
        }

        [void]$Output.Add([PSCustomObject]$Copy)
    }

    return [PSCustomObject]@{
        Rows      = $Output
        Truncated = $Truncated
        TextCells = $TextCells
    }
}

function Export-RunStatisticsSheet
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [object[]]$Rows,

        # Names of the worksheets in the workbook. A statistic is a link only
        # when its worksheet is one of these.
        [AllowNull()]
        [string[]]$WorksheetNames
    )

    # RunStatistics.csv is one row with one column per count. In the
    # workbook it is shown as a two-column table (Statistic, Value) with a
    # title and a blue table style, which is easier to read. The CSV file
    # keeps the original layout.
    $TableRows = [System.Collections.ArrayList]::new()

    foreach ($Row in @($Rows))
    {
        foreach ($Property in $Row.PSObject.Properties)
        {
            $Value = $Property.Value

            # Same text as in the CSV file.
            if ($Value -is [datetime])
            {
                $Value = $Value.ToString()
            }

            [void]$TableRows.Add(
                [PSCustomObject]@{
                    Statistic = $Property.Name
                    Value     = $Value
                }
            )
        }
    }

    # Row order: statistics without a worksheet (Timestamp, file counts)
    # first, in their original order, then the others in the order of
    # $StatisticWorksheets, which follows the worksheet order.
    $OrderedRows = [System.Collections.ArrayList]::new()

    foreach ($TableRow in $TableRows)
    {
        if (-not $StatisticWorksheets.Contains($TableRow.Statistic))
        {
            [void]$OrderedRows.Add($TableRow)
        }
    }

    foreach ($StatisticName in $StatisticWorksheets.Keys)
    {
        foreach ($TableRow in @($TableRows | Where-Object { $_.Statistic -eq $StatisticName }))
        {
            [void]$OrderedRows.Add($TableRow)
        }
    }

    $TableRows = $OrderedRows

    $Package = $TableRows |
        Export-Excel -Path $Path -WorksheetName 'RunStatistics' -Title 'Run Statistics' -TitleBold -TitleSize 14 -TableName 'RunStatisticsTable' -TableStyle Medium2 -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    # Left-align the Value column so the timestamp and the counts line up.
    $Worksheet = $Package.Workbook.Worksheets['RunStatistics']
    $Worksheet.Column(2).Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Left

    # Make each statistic in $StatisticWorksheets a link to its worksheet.
    # Row 1 is the title, row 2 the table header, so the first statistic is
    # on row 3.
    $RowNumber = 2

    foreach ($TableRow in $TableRows)
    {
        $RowNumber++
        $Target = $StatisticWorksheets[$TableRow.Statistic]

        if (($null -eq $Target) -or (@($WorksheetNames) -notcontains $Target))
        {
            continue
        }

        $Cell           = $Worksheet.Cells[$RowNumber, 1]
        $Cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$($Target)'!A1", $TableRow.Statistic)
        $Cell.Style.Font.UnderLine = $true
        $Cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(5, 99, 193))
    }

    Close-ExcelPackage -ExcelPackage $Package
}

function Export-ExcelWorkbook
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [object[]]$Sheets
    )

    # Export-Excel adds worksheets to an existing workbook, so remove the
    # workbook from any earlier run first.
    if (Test-Path -LiteralPath $Path)
    {
        Remove-Item -LiteralPath $Path -Force
    }

    $TotalTruncated = 0

    foreach ($Sheet in @($Sheets))
    {
        if (($Sheet.Name -eq 'RunStatistics') -and (@($Sheet.Rows).Count -gt 0))
        {
            Export-RunStatisticsSheet -Path $Path -Rows @($Sheet.Rows) -WorksheetNames @(@($Sheets) | ForEach-Object { $_.Name })
            continue
        }

        $SheetRows = @($Sheet.Rows)
        $TextCells = @()

        if ($SheetRows.Count -eq 0)
        {
            $SheetRows = @([PSCustomObject]@{ Result = "No rows" })
        }
        else
        {
            $Converted       = ConvertTo-ExcelSheetRows -Rows $SheetRows
            $SheetRows       = @($Converted.Rows)
            $TextCells       = @($Converted.TextCells)
            $TotalTruncated += $Converted.Truncated
        }

        # Every worksheet is an Excel table with the same blue style as the
        # RunStatistics worksheet. A table has its own filter buttons.
        # -NoNumberConversion and -NoHyperLinkConversion keep every value as
        # text, as in the CSV files.
        $Package = $SheetRows |
            Export-Excel -Path $Path -WorksheetName $Sheet.Name -TableName "$($Sheet.Name)Table" -TableStyle Medium2 -FreezeTopRow -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

        # Write text that starts with "=" back as plain text instead of a
        # formula.
        $Worksheet = $Package.Workbook.Worksheets[$Sheet.Name]

        foreach ($TextCell in $TextCells)
        {
            $Cell         = $Worksheet.Cells[$TextCell.Row, $TextCell.Column]
            $Cell.Formula = ""
            $Cell.Value   = $TextCell.Value
        }

        Close-ExcelPackage -ExcelPackage $Package
    }

    if ($TotalTruncated -gt 0)
    {
        Write-Warning "$TotalTruncated value(s) were longer than 32767 characters and were cut to that length in the Excel workbook. The CSV files have the full values."
    }
}

function Get-CategoryLeaf
{
    param(
        [AllowNull()]
        [string]$CategoryPath
    )

    # The last part of a category path, split on ">", "/" or "\". Same rule
    # as Import-IntuneMappingWorkbook.ps1.
    $Parts = @("$CategoryPath" -split '[>/\\]' | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ -ne '' })

    if ($Parts.Count -eq 0)
    {
        return ""
    }

    return $Parts[-1].ToLowerInvariant()
}

function Get-PolicyNameKey
{
    param(
        [AllowNull()]
        [string]$Class,

        [AllowNull()]
        [string]$Policy
    )

    # Class + policy name, case and spacing ignored. Same rule as
    # Import-IntuneMappingWorkbook.ps1.
    return "$("$Class".ToLowerInvariant())$Sep$(((("$Policy") -replace '\s+', ' ').Trim()).ToLowerInvariant())"
}

function Import-IntunePolicyMapping
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Returns a hashtable: class + policy name -> the mapping entries for
    # that name (one per category), or $null when the file is missing.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Host "Intune policy mappings: not found ($Path). Only the general rules in the Intune mapping file are used."
        return $null
    }

    try
    {
        $Document =
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        throw "Failed to load Intune policy mapping file '$Path': $($_.Exception.Message)"
    }

    $Index = @{}
    $Count = 0

    foreach ($Entry in @($Document.policies))
    {
        if ($null -eq $Entry)
        {
            continue
        }

        $Key = Get-PolicyNameKey -Class $Entry.class -Policy $Entry.policy

        if (-not $Index.ContainsKey($Key))
        {
            $Index[$Key] = [System.Collections.ArrayList]::new()
        }

        [void]$Index[$Key].Add($Entry)
        $Count++
    }

    Write-Host "Intune policy mappings: $Count policies loaded ($Path)"

    return $Index
}

function Get-IntunePolicyMapping
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Setting,

        [AllowNull()]
        [hashtable]$Index,

        [AllowNull()]
        [hashtable]$NameAliases
    )

    # Returns the mapping entry for a setting, and whether the category had
    # to be guessed, or $null when the policy is not in the file.
    if ($null -eq $Index)
    {
        return $null
    }

    $Names = [System.Collections.ArrayList]::new()
    [void]$Names.Add([string]$Setting.SettingName)

    if (($null -ne $NameAliases) -and $NameAliases.ContainsKey([string]$Setting.SettingName))
    {
        [void]$Names.Add($NameAliases[[string]$Setting.SettingName])
    }

    $Candidates = @()

    foreach ($Name in $Names)
    {
        $Key = Get-PolicyNameKey -Class $Setting.Class -Policy $Name

        if ($Index.ContainsKey($Key))
        {
            $Candidates = @($Index[$Key])
            break
        }
    }

    if ($Candidates.Count -eq 0)
    {
        return $null
    }

    if ($Candidates.Count -eq 1)
    {
        return [PSCustomObject]@{
            Entry     = $Candidates[0]
            Ambiguous = $false
        }
    }

    # The policy name has entries in several categories (for example the
    # Application and Security event logs). Use the entry whose last
    # category part is a part of the setting's category.
    $SettingParts = @("$($Setting.Category)" -split '[>/\\]' | ForEach-Object { (($_ -replace '\s+', ' ').Trim()).ToLowerInvariant() } | Where-Object { $_ -ne '' })

    foreach ($Candidate in $Candidates)
    {
        $Leaf = Get-CategoryLeaf -CategoryPath $Candidate.categoryPath

        if (($Leaf -ne '') -and ($SettingParts -contains $Leaf))
        {
            return [PSCustomObject]@{
                Entry     = $Candidate
                Ambiguous = $false
            }
        }
    }

    return [PSCustomObject]@{
        Entry     = $Candidates[0]
        Ambiguous = $true
    }
}

function Import-MigrationExclusions
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Returns the enabled entries of the exclusion file (name, class,
    # patterns), or none when the file is missing.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Warning "Exclusion file not found: $Path - no settings are excluded."
        return @()
    }

    try
    {
        $Document =
            Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        throw "Failed to load exclusion file '$Path': $($_.Exception.Message)"
    }

    $Enabled = [System.Collections.ArrayList]::new()

    foreach ($Entry in @($Document.exclusions))
    {
        if (($null -eq $Entry) -or ("$($Entry.enabled)" -ine 'true'))
        {
            continue
        }

        $Patterns = @($Entry.patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($Patterns.Count -eq 0)
        {
            Write-Warning "Exclusion '$($Entry.name)' has no patterns and is ignored."
            continue
        }

        [void]$Enabled.Add(
            [PSCustomObject]@{
                Name     = "$($Entry.name)"
                Class    = if ([string]::IsNullOrWhiteSpace($Entry.class)) { '*' } else { "$($Entry.class)" }
                Patterns = $Patterns
            }
        )
    }

    return $Enabled
}

function Get-MigrationExclusion
{
    param(
        [Parameter(Mandatory)]
        [object]$Setting,

        [AllowNull()]
        [object[]]$Exclusions
    )

    # The name of the first enabled exclusion that matches the setting, or
    # $null. Patterns are matched with -like (wildcards, case ignored)
    # against "Extension / Category / SettingName".
    $Text = "$($Setting.Extension) / $($Setting.Category) / $($Setting.SettingName)"

    foreach ($Exclusion in @($Exclusions))
    {
        if (($Exclusion.Class -ne '*') -and ("$($Setting.Class)" -ne $Exclusion.Class))
        {
            continue
        }

        foreach ($Pattern in $Exclusion.Patterns)
        {
            if ($Text -like $Pattern)
            {
                return $Exclusion.Name
            }
        }
    }

    return $null
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

# The HTML reports show display names, the same names the mapping
# workbooks use, so no name aliases are needed (Compare-GPOXml.ps1 has a
# table for the internal names in XML exports).
$PolicyNameAliases = $null

$IntuneMappingCatalog =
    Import-IntuneMapping `
        -Path $IntuneMappingPath

# Not wrapped in @(): the function returns one hashtable (or $null), not a
# collection.
# File name shown in MappingSource (IntunePolicyMappings.json, or the
# internal file written with -KeepSensitiveData).
$PolicyMappingFileName = [System.IO.Path]::GetFileName($PolicyMappingPath)

$PolicyMappingIndex =
    Import-IntunePolicyMapping `
        -Path $PolicyMappingPath

$MigrationExclusions = @()

if ($UseExclusions)
{
    $MigrationExclusions = @(Import-MigrationExclusions -Path $ExclusionPath)
    Write-Host "Intune migration exclusions: $($MigrationExclusions.Count) enabled ($(@($MigrationExclusions | ForEach-Object { $_.Name }) -join ', '))"
}
else
{
    Write-Host "Intune migration exclusions: not used"
}

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
            Write-Warning "$($HtmlFile.BaseName): $($Result.Unclassified.Count) unclassified entries (see $(Get-ReportLocation 'UnclassifiedSettings.csv'))."
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
    # Write the reports collected so far, so ParserFailures and
    # UnclassifiedSettings are available to see why nothing was parsed.
    if ($ExcelOutput)
    {
        Save-ExcelOutput
    }

    throw "No settings were parsed from any HTML file. See $(Get-ReportLocation 'ParserFailures.csv') and $(Get-ReportLocation 'UnclassifiedSettings.csv') in $OutputFolder"
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

# Exclusion name -> number of settings it left out.
$ExcludedCounts = @{}

$MigrationCandidates =
    foreach ($Setting in $AllSettings)
    {
        # Settings matched by an enabled exclusion are left out.
        $ExclusionName = Get-MigrationExclusion -Setting $Setting -Exclusions $MigrationExclusions

        if ($null -ne $ExclusionName)
        {
            if ($ExcludedCounts.ContainsKey($ExclusionName))
            {
                $ExcludedCounts[$ExclusionName]++
            }
            else
            {
                $ExcludedCounts[$ExclusionName] = 1
            }

            continue
        }

        $PolicyMatch = Get-IntunePolicyMapping -Setting $Setting -Index $PolicyMappingIndex -NameAliases $PolicyNameAliases
        $Map         = $null

        if ($null -eq $PolicyMatch)
        {
            $Map = Get-IntuneMapping -Setting $Setting -Catalog $IntuneMappingCatalog
        }

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

        if ($null -ne $PolicyMatch)
        {
            # Mapped from the manual mapping workbooks.
            $PolicyEntry   = $PolicyMatch.Entry
            $MappingStatus = $PolicyEntry.status
            $Confidence    = 'High'
            $IntuneType    = $PolicyEntry.intuneSetting
            $IntuneSetting = $PolicyEntry.intuneSubSetting
            $OmaUri        = $null
            # Workbook and worksheet names, when the file has them (files written
            # with -KeepSensitiveData). A scrubbed file's sources are its own file
            # name, so only the file name is shown.
            $EntrySources = @($PolicyEntry.sources | Where-Object { ($null -ne $_) -and ($_ -ne $PolicyMappingFileName) })

            if ($EntrySources.Count -gt 0)
            {
                $MappingSource = "$($PolicyMappingFileName): $($EntrySources -join '; ')"
            }
            else
            {
                $MappingSource = $PolicyMappingFileName
            }

            $NoteParts = [System.Collections.ArrayList]::new()

            if (-not [string]::IsNullOrWhiteSpace($PolicyEntry.remarks))
            {
                [void]$NoteParts.Add($PolicyEntry.remarks)
            }

            $Alternates = @($PolicyEntry.alternates | Where-Object { $null -ne $_ })

            if ($Alternates.Count -gt 0)
            {
                [void]$NoteParts.Add("Other mappings in the workbooks: $(@($Alternates | ForEach-Object { "$($_.intuneSetting) >> $($_.intuneSubSetting)" }) -join '; ')")
            }

            if ($PolicyMatch.Ambiguous)
            {
                [void]$NoteParts.Add("This policy name is mapped in several categories and the category could not be matched; the first mapping was used.")
            }

            if ($NoteParts.Count -eq 0)
            {
                # Scrubbed mapping files have no remarks.
                if ($PolicyEntry.status -eq 'NoIntuneEquivalent')
                {
                    [void]$NoteParts.Add("Reviewed in a mapping workbook: no Intune equivalent.")
                }
                else
                {
                    [void]$NoteParts.Add("Mapped from the manual mapping workbooks.")
                }
            }

            $MappingNotes = @($NoteParts) -join ' | '
        }
        elseif ($null -eq $IntuneMappingCatalog)
        {
            $MappingStatus = 'MappingFileMissing'
            $Confidence    = 'None'
            $MappingNotes  = 'Intune mapping file was not loaded.'
            $IntuneType    = $null
            $IntuneSetting = $null
            $OmaUri        = $null
            $MappingSource = $null
        }
        elseif ($null -ne $Map)
        {
            $MappingStatus = $Map.mappingStatus
            $Confidence    = $Map.confidence
            $MappingNotes  = $Map.notes
            $IntuneType    = $Map.intuneType
            $IntuneSetting = $Map.intuneSetting
            $OmaUri        = $Map.omaUri
            $MappingSource = "intunemapping.json (general rule)"
        }
        else
        {
            $MappingStatus = 'Unmapped'
            $Confidence    = 'None'
            $MappingNotes  = 'No matching entry in the Intune mapping file.'
            $IntuneType    = $null
            $IntuneSetting = $null
            $OmaUri        = $null
            $MappingSource = $null
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
            IntuneType             = $IntuneType
            IntuneSetting          = $IntuneSetting
            OMAURI                 = $OmaUri
            MappingStatus          = $MappingStatus
            Confidence             = $Confidence
            Notes                  = $MappingNotes
            MappingSource          = $MappingSource
        }
    }

$UnmappedCount =
    @(
        $MigrationCandidates |
        Where-Object { $_.MappingStatus -in @('Unmapped', 'MappingFileMissing') }
    ).Count

# Settings left out by the exclusion file.
$ExcludedCount = 0

foreach ($Count in $ExcludedCounts.Values)
{
    $ExcludedCount += $Count
}

# Settings mapped from the manual mapping workbooks (the policy mapping file).
$WorkbookMappedCount =
    @(
        $MigrationCandidates |
        Where-Object { ("$($_.MappingSource)" -eq $PolicyMappingFileName) -or "$($_.MappingSource)".StartsWith("$($PolicyMappingFileName):") }
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
        MissingSettingsMatrix     = @($Matrix).Count
        IntuneMigrationCandidates = @($MigrationCandidates).Count
        FirewallDiagnostics       = @($FirewallDiagnostics).Count
        MappedFromWorkbooks       = $WorkbookMappedCount
        ExcludedFromMigration     = $ExcludedCount
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

Write-Host ""
Write-Host "Generated Reports"
Write-Host "-----------------"

if ($ExcelOutput)
{
    Save-ExcelOutput
}
else
{
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
    Write-Warning "$($Failures.Count) HTML file(s) failed to parse and are excluded from the comparison ($(Get-ReportLocation 'ParserFailures.csv'))."
}

if ($AllUnclassified.Count -gt 0)
{
    Write-Warning "$($AllUnclassified.Count) unclassified entries are not part of the comparison ($(Get-ReportLocation 'UnclassifiedSettings.csv')). This is normal for RSoP HTML reports - check the Reason and Category columns to see what was skipped."
}

if ($ExcludedCount -gt 0)
{
    Write-Host "$ExcludedCount setting(s) excluded from IntuneMigrationCandidates: $(@($ExcludedCounts.Keys | Sort-Object | ForEach-Object { "$($_) $($ExcludedCounts[$_])" }) -join ', ')"
}

Write-Host "Reports written to:"
Write-Host $OutputFolder
