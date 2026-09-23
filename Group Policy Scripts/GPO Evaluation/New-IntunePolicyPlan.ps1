<#
.SYNOPSIS
Group the settings of several GPOs into a proposed set of Intune policies.

.DESCRIPTION
Reads the output of Compare-GPOXml.ps1 or Compare-GPOHtml.ps1 (the CSV
files or the Excel workbook) and writes IntunePolicyPlan.xlsx: a proposed
set of Intune policies that together hold every migratable setting.

Grouping:
- A setting with a given value belongs to the exact set of GPOs that
  configure it with that value. All settings that share the same set of
  GPOs form one group, so each proposed policy can be assigned to the
  devices or users those GPOs applied to:
      Baseline   the setting is in every GPO
      Shared     the setting is in two or more GPOs, but not all
      Single     the setting is in one GPO
- Each group is split by scope (Device for Computer settings, User for
  User settings) and by Intune policy type (Settings Catalog, Endpoint
  security - Firewall, Endpoint security - Account protection, ...),
  because one Intune policy holds one type and is assigned to one kind of
  group. The type comes from the IntuneType column (see
  $PolicyTypeRules).
- A GPO with several values for one setting (for example user rights
  members) is compared as the whole set of values.
- Firewall rules are grouped the same way, by rule name + direction + all
  rule fields, into "Endpoint security - Firewall rules" policies.

Not placed in a policy:
- Deprecated settings (Deprecated = Yes), and settings mapped as
  NoIntuneEquivalent from the manual mapping workbooks. They are listed on
  the Not Migrated worksheet with the reason.

Conflicts:
- A setting configured with different values in different GPOs goes into
  a different group for each value. A device that is in the assignment of
  both groups receives both values, so every such setting is listed on the
  Conflicts worksheet with each value, its GPOs and its proposed policy.

For Compare-GPOHtml.ps1 output, each input "GPO" is an RSoP report.

Workbook written to OutputFolder (every worksheet is a blue Excel table):

Summary
    Counts for the run. Each count links to its worksheet.

PolicyPlan
    One row per proposed Intune policy: name, tier, GPOs, scope, type and
    number of settings or firewall rules.

PolicySettings
    Every placed setting, with only the columns needed to build the Intune
    policies: PolicyName, GPOName (XML) or ReportName (HTML) - the GPOs or
    reports the setting is in - Class, SettingName, Value, WinningGPO (HTML
    only), IntuneType, IntuneSetting, MappingStatus, Confidence.

FirewallRules
    Every firewall rule with its proposed policy and GPOs.

Conflicts
    Settings and firewall rules configured differently in different GPOs.

NotMigrated
    Deprecated and NoIntuneEquivalent settings, with the reason.

.PARAMETER InputPath
The output folder of Compare-GPOXml.ps1 or Compare-GPOHtml.ps1 (CSV files
or the GPOCompareXml.xlsx / GPOCompareHtml.xlsx workbook), or the workbook
file itself.

.PARAMETER OutputFolder
Folder for IntunePolicyPlan.xlsx. Default: the input folder.

.PARAMETER FilePrefix
The file name prefix used for the compare run (for example LS for
LS-IntuneMigrationCandidates.csv). Only needed when the input folder holds
the output of more than one run. The plan is written with the same
prefix (LS-IntunePolicyPlan.xlsx).

.PARAMETER PolicyNamePrefix
Text added to the start of every proposed policy name, for example
"WIN - ".

.EXAMPLE
.\New-IntunePolicyPlan.ps1 -InputPath "C:\GPOProject\Output"

.EXAMPLE
.\New-IntunePolicyPlan.ps1 -InputPath "C:\GPOProject\Output\LS-GPOCompareXml.xlsx" -PolicyNamePrefix "WIN - "

.NOTES
Author:  Siconic
Version: 1.0

Needs the ImportExcel module; if it is not installed, the script installs
it for the current user from the PowerShell Gallery. Excel itself is not
needed.

Changelog:
  1.0 - Initial version.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [string]$OutputFolder,

    [string]$FilePrefix,

    [string]$PolicyNamePrefix = ""
)

$ErrorActionPreference = "Stop"

$Sep = [string][char]0x1F

# Intune policy type from the IntuneType column, first match wins. The
# text of IntuneType comes from the manual mapping workbooks or from the
# general rules in intunemapping.json. Anything not matched is a Settings
# Catalog policy.
$PolicyTypeRules = @(
    @{ Pattern = '(?i)firewall';                               Type = 'Endpoint security - Firewall' }
    @{ Pattern = '(?i)account protection|local user group';    Type = 'Endpoint security - Account protection' }
    @{ Pattern = '(?i)attack surface|\basr\b';                 Type = 'Endpoint security - Attack surface reduction' }
    @{ Pattern = '(?i)antivirus';                              Type = 'Endpoint security - Antivirus' }
    @{ Pattern = '(?i)bitlocker|disk encryption';              Type = 'Endpoint security - Disk encryption' }
    @{ Pattern = '(?i)\blaps\b|local admin(istrator)? password'; Type = 'Endpoint security - LAPS' }
    @{ Pattern = '(?i)no direct';                              Type = 'Needs review (no direct Intune policy)' }
    @{ Pattern = '(?i)settings catalog';                       Type = 'Settings Catalog' }
    @{ Pattern = '(?i)remediation|powershell|script';          Type = 'Remediation script' }
)

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $InputPath))
{
    throw "Input not found: $InputPath"
}

$InputItem = Get-Item -LiteralPath $InputPath

if ([string]::IsNullOrWhiteSpace($OutputFolder))
{
    $OutputFolder = if ($InputItem.PSIsContainer) { $InputItem.FullName } else { $InputItem.DirectoryName }
}

if (-not (Test-Path -LiteralPath $OutputFolder))
{
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).ProviderPath

# ImportExcel: needed to write the plan (and to read a workbook input).
if (@(Get-Module -ListAvailable -Name ImportExcel).Count -eq 0)
{
    Write-Host "The ImportExcel module is not installed. Installing it for the current user from the PowerShell Gallery..."

    try
    {
        # The PowerShell Gallery requires TLS 1.2, which Windows PowerShell
        # 5.1 does not always use by default.
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        if (@(Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue).Count -eq 0)
        {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }

        Install-Module -Name ImportExcel -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
    }
    catch
    {
        throw "The ImportExcel module could not be installed ($($_.Exception.Message)). It is needed to write IntunePolicyPlan.xlsx. Install it with: Install-Module ImportExcel -Scope CurrentUser"
    }
}

Import-Module ImportExcel -ErrorAction Stop

# ------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------

function Get-PropertyValue
{
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    # The value of the first of the given properties the object has. The
    # XML and HTML outputs name some columns differently (GPOName /
    # ReportName, GPOValue / Value).
    foreach ($Name in $Names)
    {
        $Property = $Object.PSObject.Properties[$Name]

        if ($null -ne $Property)
        {
            return "$($Property.Value)"
        }
    }

    return ""
}

function Test-EmptySheetRows
{
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    # The compare scripts write a worksheet with a single "No rows" row for
    # an empty report.
    $Rows = @($Rows)

    return (
        ($Rows.Count -eq 0) -or
        (($Rows.Count -eq 1) -and ($null -ne $Rows[0].PSObject.Properties['Result']) -and ("$($Rows[0].Result)" -eq 'No rows'))
    )
}

function Read-CompareReport
{
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Rows of one compare report (for example IntuneMigrationCandidates),
    # from the CSV file or the workbook worksheet. An empty or missing
    # report gives no rows.
    if ($script:InputMode -eq 'Csv')
    {
        $File = Join-Path $script:InputFolder "$($script:InputPrefix)$($Name).csv"

        if (-not (Test-Path -LiteralPath $File -PathType Leaf))
        {
            return @()
        }

        if ((Get-Item -LiteralPath $File).Length -eq 0)
        {
            return @()
        }

        return @(Import-Csv -LiteralPath $File -Encoding UTF8)
    }

    $Sheets = @(Get-ExcelSheetInfo -Path $script:InputWorkbook | ForEach-Object { $_.Name })

    if ($Sheets -notcontains $Name)
    {
        return @()
    }

    $Rows = @(Import-Excel -Path $script:InputWorkbook -WorksheetName $Name)

    if (Test-EmptySheetRows -Rows $Rows)
    {
        return @()
    }

    return $Rows
}

function Get-PolicyType
{
    param(
        [AllowNull()]
        [string]$IntuneType,

        [AllowNull()]
        [string]$MappingStatus
    )

    if ($MappingStatus -in @('Unmapped', 'MappingFileMissing'))
    {
        return 'Needs mapping'
    }

    foreach ($Rule in $PolicyTypeRules)
    {
        if ("$IntuneType" -match $Rule.Pattern)
        {
            return $Rule.Type
        }
    }

    return 'Settings Catalog'
}

function Get-ScopeName
{
    param(
        [AllowNull()]
        [string]$Class
    )

    switch ("$Class")
    {
        'Computer' { return 'Device' }
        'User'     { return 'User' }
        default    { if ("$Class" -eq '') { return 'Unknown' } else { return "$Class" } }
    }
}

function ConvertTo-ExcelSheetRows
{
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    # Same rules as the compare scripts: values over the 32767-character
    # Excel cell limit are cut, and text starting with "=" is recorded so it
    # can be written back as text instead of a formula.
    $MaxCellLength = 32767
    $Output        = [System.Collections.ArrayList]::new()
    $TextCells     = [System.Collections.ArrayList]::new()
    $Truncated     = 0
    $RowNumber     = 1

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
                [void]$TextCells.Add([PSCustomObject]@{ Row = $RowNumber; Column = $ColumnNumber; Value = $Value })
            }

            $Copy[$Property.Name] = $Value
        }

        [void]$Output.Add([PSCustomObject]$Copy)
    }

    return [PSCustomObject]@{
        Rows      = $Output
        TextCells = $TextCells
        Truncated = $Truncated
    }
}

function Write-PlanSheet
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object[]]$Rows
    )

    # One worksheet as a blue Excel table with a frozen header row, text
    # kept as text.
    $SheetRows = @($Rows)
    $TextCells = @()

    if ($SheetRows.Count -eq 0)
    {
        $SheetRows = @([PSCustomObject]@{ Result = "No rows" })
    }
    else
    {
        $Converted  = ConvertTo-ExcelSheetRows -Rows $SheetRows
        $SheetRows  = @($Converted.Rows)
        $TextCells  = @($Converted.TextCells)
        $script:TruncatedCells += $Converted.Truncated
    }

    $Package = $SheetRows |
        Export-Excel -Path $Path -WorksheetName $Name -TableName "$($Name)Table" -TableStyle Medium2 -FreezeTopRow -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    $Worksheet = $Package.Workbook.Worksheets[$Name]

    foreach ($TextCell in $TextCells)
    {
        $Cell         = $Worksheet.Cells[$TextCell.Row, $TextCell.Column]
        $Cell.Formula = ""
        $Cell.Value   = $TextCell.Value
    }

    Close-ExcelPackage -ExcelPackage $Package
}

function Write-SummarySheet
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    # Two-column table (Item, Value) with a title. Rows with a Worksheet are
    # links to that worksheet, as on the compare scripts' RunStatistics.
    $TableRows = @($Rows | ForEach-Object { [PSCustomObject]@{ Item = $_.Item; Value = $_.Value } })

    $Package = $TableRows |
        Export-Excel -Path $Path -WorksheetName 'Summary' -Title 'Intune Policy Plan' -TitleBold -TitleSize 14 -TableName 'SummaryTable' -TableStyle Medium2 -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    $Worksheet = $Package.Workbook.Worksheets['Summary']
    $Worksheet.Column(2).Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Left

    # Row 1 is the title, row 2 the table header.
    $RowNumber = 2

    foreach ($Row in $Rows)
    {
        $RowNumber++

        if ([string]::IsNullOrWhiteSpace($Row.Worksheet))
        {
            continue
        }

        $Cell           = $Worksheet.Cells[$RowNumber, 1]
        $Cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$($Row.Worksheet)'!A1", $Row.Item)
        $Cell.Style.Font.UnderLine = $true
        $Cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(5, 99, 193))
    }

    Close-ExcelPackage -ExcelPackage $Package
}

function Get-TierName
{
    param(
        [int]$SourceCount,

        [int]$TotalSources
    )

    if (($SourceCount -eq $TotalSources) -and ($TotalSources -gt 1))
    {
        return 'Baseline'
    }

    if ($SourceCount -gt 1)
    {
        return 'Shared'
    }

    return 'Single'
}

# ------------------------------------------------------------
# Find the input
# ------------------------------------------------------------

if ($InputItem.PSIsContainer)
{
    $script:InputFolder = $InputItem.FullName

    $CsvFiles = @(Get-ChildItem -LiteralPath $script:InputFolder -Filter "$($FilePrefix)*IntuneMigrationCandidates.csv" -File)

    if ($CsvFiles.Count -gt 1)
    {
        throw "More than one IntuneMigrationCandidates.csv in $($script:InputFolder) ($(@($CsvFiles | ForEach-Object { $_.Name }) -join ', ')). Use -FilePrefix to choose the run."
    }

    if ($CsvFiles.Count -eq 1)
    {
        $script:InputMode   = 'Csv'
        $script:InputPrefix = $CsvFiles[0].Name.Substring(0, $CsvFiles[0].Name.Length - 'IntuneMigrationCandidates.csv'.Length)
    }
    else
    {
        $Workbooks = @(Get-ChildItem -LiteralPath $script:InputFolder -Filter "$($FilePrefix)*GPOCompare*.xlsx" -File | Where-Object { -not $_.Name.StartsWith('~$') })

        if ($Workbooks.Count -ne 1)
        {
            throw "No compare output found in $($script:InputFolder): expected one IntuneMigrationCandidates.csv or one GPOCompareXml.xlsx / GPOCompareHtml.xlsx (found $($Workbooks.Count) workbooks). Use -FilePrefix when the folder has the output of several runs."
        }

        $script:InputMode     = 'Workbook'
        $script:InputWorkbook = $Workbooks[0].FullName
        $script:InputPrefix   = $Workbooks[0].Name.Substring(0, $Workbooks[0].Name.IndexOf('GPOCompare'))
    }
}
else
{
    if ($InputItem.Extension -ne '.xlsx')
    {
        throw "InputPath must be a compare output folder or a GPOCompareXml.xlsx / GPOCompareHtml.xlsx workbook: $InputPath"
    }

    $script:InputMode     = 'Workbook'
    $script:InputWorkbook = $InputItem.FullName
    $script:InputFolder   = $InputItem.DirectoryName
    $Index                = $InputItem.Name.IndexOf('GPOCompare')
    $script:InputPrefix   = if ($Index -gt 0) { $InputItem.Name.Substring(0, $Index) } else { "" }
}

if ($script:InputMode -eq 'Csv')
{
    Write-Host "Input: CSV files in $($script:InputFolder) (prefix: $(if ($script:InputPrefix) { $script:InputPrefix } else { '(none)' }))"
}
else
{
    Write-Host "Input: workbook $($script:InputWorkbook)"
}

$CandidateRows = @(Read-CompareReport -Name 'IntuneMigrationCandidates')
$FirewallRows  = @(Read-CompareReport -Name 'FirewallRules')

if ($CandidateRows.Count -eq 0 -and $FirewallRows.Count -eq 0)
{
    throw "The input has no IntuneMigrationCandidates or FirewallRules rows."
}

# XML output names the source GPOName, HTML output ReportName.
$SourceColumn = 'GPOName'

if (($CandidateRows.Count -gt 0) -and ($null -eq $CandidateRows[0].PSObject.Properties['GPOName']))
{
    $SourceColumn = 'ReportName'
}
elseif (($CandidateRows.Count -eq 0) -and ($null -eq $FirewallRows[0].PSObject.Properties['GPOName']))
{
    $SourceColumn = 'ReportName'
}

$SourceLabel = if ($SourceColumn -eq 'GPOName') { 'GPOs' } else { 'Reports' }

$AllSources =
    @(
        @($CandidateRows | ForEach-Object { Get-PropertyValue $_ @('GPOName', 'ReportName') }) +
        @($FirewallRows  | ForEach-Object { Get-PropertyValue $_ @('GPOName', 'ReportName') }) |
        Where-Object { $_ -ne '' } |
        Sort-Object -Unique
    )

Write-Host "$($SourceLabel): $($AllSources.Count) ($($AllSources -join ', '))"
Write-Host "Settings rows: $($CandidateRows.Count); firewall rule rows: $($FirewallRows.Count)"

# ------------------------------------------------------------
# Settings: one value set per GPO and setting
# ------------------------------------------------------------

# Setting key -> source -> list of values. A GPO with several rows for one
# setting (list values) is compared as the set of its values.
$SettingValues = @{}

# Setting key -> the first row seen, for the setting's names and mapping.
$SettingInfo = [ordered]@{}

# Setting key -> source -> winning GPOs (HTML output only).
$SettingWinning = @{}

foreach ($Row in $CandidateRows)
{
    $Source = Get-PropertyValue $Row @('GPOName', 'ReportName')
    $Value  = Get-PropertyValue $Row @('GPOValue', 'Value')
    $State  = Get-PropertyValue $Row @('GPOState')

    $SettingKey =
        @(
            (Get-PropertyValue $Row @('Class'))
            (Get-PropertyValue $Row @('Extension'))
            (Get-PropertyValue $Row @('Category'))
            (Get-PropertyValue $Row @('SettingName'))
        ) -join $Sep

    $SettingKey = $SettingKey.ToLowerInvariant()

    if (-not $SettingInfo.Contains($SettingKey))
    {
        $SettingInfo[$SettingKey]    = $Row
        $SettingValues[$SettingKey]  = @{}
        $SettingWinning[$SettingKey] = @{}
    }

    if (-not $SettingValues[$SettingKey].ContainsKey($Source))
    {
        $SettingValues[$SettingKey][$Source]  = [System.Collections.ArrayList]::new()
        $SettingWinning[$SettingKey][$Source] = [System.Collections.ArrayList]::new()
    }

    $WinningGpo = Get-PropertyValue $Row @('WinningGPO')

    if (($WinningGpo -ne '') -and ($SettingWinning[$SettingKey][$Source] -notcontains $WinningGpo))
    {
        [void]$SettingWinning[$SettingKey][$Source].Add($WinningGpo)
    }

    # XML output has a separate state (Enabled, Disabled, Configured). It
    # is part of the comparison, and shown after the value unless it only
    # repeats the value or says Configured.
    $ValueText = $Value

    if (($State -ne '') -and ($State -ne $Value) -and ($State -ne 'Configured'))
    {
        $ValueText = "$Value [$State]"
    }
    [void]$SettingValues[$SettingKey][$Source].Add($ValueText)
}

# ------------------------------------------------------------
# Settings: group by exact set of GPOs
# ------------------------------------------------------------

$PlacedSettings = [System.Collections.ArrayList]::new()
$NotMigrated    = [System.Collections.ArrayList]::new()
$Conflicts      = [System.Collections.ArrayList]::new()

foreach ($SettingKey in $SettingInfo.Keys)
{
    $Info = $SettingInfo[$SettingKey]

    # Value set (sorted, case ignored) -> the GPOs that have exactly it.
    $ByValue = [ordered]@{}

    foreach ($Source in ($SettingValues[$SettingKey].Keys | Sort-Object))
    {
        $Values   = @($SettingValues[$SettingKey][$Source] | Sort-Object -Unique)
        $ValueKey = (($Values | ForEach-Object { "$_".ToLowerInvariant() }) -join $Sep)

        if (-not $ByValue.Contains($ValueKey))
        {
            $ByValue[$ValueKey] = [PSCustomObject]@{
                Display = ($Values -join '; ')
                Sources = [System.Collections.ArrayList]::new()
            }
        }

        [void]$ByValue[$ValueKey].Sources.Add($Source)
    }

    $IsConflict    = $ByValue.Count -gt 1
    $Deprecated    = (Get-PropertyValue $Info @('Deprecated')) -eq 'Yes'
    $MappingStatus = Get-PropertyValue $Info @('MappingStatus')
    $Scope         = Get-ScopeName (Get-PropertyValue $Info @('Class'))
    $PolicyType    = Get-PolicyType -IntuneType (Get-PropertyValue $Info @('IntuneType')) -MappingStatus $MappingStatus

    foreach ($Group in $ByValue.Values)
    {
        $Sources = @($Group.Sources | Sort-Object)

        $Item =
            [PSCustomObject]@{
                Scope         = $Scope
                PolicyType    = $PolicyType
                Sources       = $Sources
                SourceKey     = ($Sources -join $Sep).ToLowerInvariant()
                Class         = Get-PropertyValue $Info @('Class')
                Extension     = Get-PropertyValue $Info @('Extension')
                Category      = Get-PropertyValue $Info @('Category')
                SettingName   = Get-PropertyValue $Info @('SettingName')
                Value         = $Group.Display
                WinningGPO    = (@($Sources | ForEach-Object { $SettingWinning[$SettingKey][$_] } | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
                IntuneType    = Get-PropertyValue $Info @('IntuneType')
                IntuneSetting = Get-PropertyValue $Info @('IntuneSetting')
                MappingStatus = $MappingStatus
                Confidence    = Get-PropertyValue $Info @('Confidence')
                MappingSource = Get-PropertyValue $Info @('MappingSource')
                Notes         = Get-PropertyValue $Info @('Notes')
                IsConflict    = $IsConflict
                PolicyName    = ""
            }

        if ($Deprecated)
        {
            $Replacement = Get-PropertyValue $Info @('RecommendedReplacement')

            [void]$NotMigrated.Add(
                [PSCustomObject]@{
                    Reason      = "Deprecated$(if ($Replacement) { ": $Replacement" })"
                    Class       = $Item.Class
                    Extension   = $Item.Extension
                    Category    = $Item.Category
                    SettingName = $Item.SettingName
                    Value       = $Item.Value
                    Sources     = $Sources -join '; '
                }
            )
        }
        elseif ($MappingStatus -eq 'NoIntuneEquivalent')
        {
            [void]$NotMigrated.Add(
                [PSCustomObject]@{
                    Reason      = "No Intune equivalent (manual mapping workbook)"
                    Class       = $Item.Class
                    Extension   = $Item.Extension
                    Category    = $Item.Category
                    SettingName = $Item.SettingName
                    Value       = $Item.Value
                    Sources     = $Sources -join '; '
                }
            )
        }
        else
        {
            [void]$PlacedSettings.Add($Item)
        }
    }
}

# ------------------------------------------------------------
# Firewall rules: group by exact set of GPOs
# ------------------------------------------------------------

# Columns that are not part of a rule's configuration.
$FirewallIgnore = @('GPOName', 'ReportName', 'WinningGPO', 'IntuneType')

# Rule identity (name + direction) -> configuration -> GPOs.
$RuleConfigs = [ordered]@{}
$RuleInfo    = @{}

foreach ($Row in $FirewallRows)
{
    $Source   = Get-PropertyValue $Row @('GPOName', 'ReportName')
    $RuleKey  = "$(Get-PropertyValue $Row @('Name'))$Sep$(Get-PropertyValue $Row @('Direction'))".ToLowerInvariant()

    $Config =
        @(
            foreach ($Property in $Row.PSObject.Properties)
            {
                if ($FirewallIgnore -notcontains $Property.Name)
                {
                    "$($Property.Name)=$($Property.Value)"
                }
            }
        ) -join $Sep

    $ConfigKey = $Config.ToLowerInvariant()

    if (-not $RuleConfigs.Contains($RuleKey))
    {
        $RuleConfigs[$RuleKey] = [ordered]@{}
    }

    if (-not $RuleConfigs[$RuleKey].Contains($ConfigKey))
    {
        $RuleConfigs[$RuleKey][$ConfigKey] = [System.Collections.ArrayList]::new()
        $RuleInfo["$RuleKey$Sep$ConfigKey"] = $Row
    }

    if ($RuleConfigs[$RuleKey][$ConfigKey] -notcontains $Source)
    {
        [void]$RuleConfigs[$RuleKey][$ConfigKey].Add($Source)
    }
}

$PlacedRules = [System.Collections.ArrayList]::new()

foreach ($RuleKey in $RuleConfigs.Keys)
{
    $IsConflict = $RuleConfigs[$RuleKey].Count -gt 1

    foreach ($ConfigKey in $RuleConfigs[$RuleKey].Keys)
    {
        $Sources = @($RuleConfigs[$RuleKey][$ConfigKey] | Sort-Object)

        [void]$PlacedRules.Add(
            [PSCustomObject]@{
                Scope      = 'Device'
                PolicyType = 'Endpoint security - Firewall rules'
                Sources    = $Sources
                SourceKey  = ($Sources -join $Sep).ToLowerInvariant()
                Rule       = $RuleInfo["$RuleKey$Sep$ConfigKey"]
                IsConflict = $IsConflict
                PolicyName = ""
            }
        )
    }
}

# ------------------------------------------------------------
# Proposed policies: GPO set + scope + policy type
# ------------------------------------------------------------

$PolicyGroups = [ordered]@{}

foreach ($Item in @($PlacedSettings) + @($PlacedRules))
{
    $PolicyKey = "$($Item.SourceKey)$Sep$($Item.Scope)$Sep$($Item.PolicyType)"

    if (-not $PolicyGroups.Contains($PolicyKey))
    {
        $PolicyGroups[$PolicyKey] = [PSCustomObject]@{
            Sources    = $Item.Sources
            Scope      = $Item.Scope
            PolicyType = $Item.PolicyType
            Items      = [System.Collections.ArrayList]::new()
        }
    }

    [void]$PolicyGroups[$PolicyKey].Items.Add($Item)
}

# Order: most GPOs first (Baseline), then by GPO names, scope and type.
$OrderedGroups =
    @(
        $PolicyGroups.Values |
        Sort-Object `
            @{ Expression = { @($_.Sources).Count }; Descending = $true },
            @{ Expression = { @($_.Sources) -join '; ' } },
            @{ Expression = { $_.Scope } },
            @{ Expression = { $_.PolicyType } }
    )

# Shared groups with long GPO lists get a number instead of the list.
$SharedNumbers = @{}
$PolicyPlan    = [System.Collections.ArrayList]::new()

foreach ($Group in $OrderedGroups)
{
    $Sources = @($Group.Sources)
    $Tier    = Get-TierName -SourceCount $Sources.Count -TotalSources $AllSources.Count

    switch ($Tier)
    {
        'Baseline'
        {
            $GroupLabel = 'Baseline'
        }
        'Single'
        {
            $GroupLabel = "Only $($Sources[0])"
        }
        default
        {
            $Joined = $Sources -join ' + '

            if ($Joined.Length -le 60)
            {
                $GroupLabel = $Joined
            }
            else
            {
                $SetKey = $Sources -join $Sep

                if (-not $SharedNumbers.ContainsKey($SetKey))
                {
                    $SharedNumbers[$SetKey] = $SharedNumbers.Count + 1
                }

                $GroupLabel = "Shared group $("$($SharedNumbers[$SetKey])".PadLeft(2, '0'))"
            }
        }
    }

    $PolicyName = "$($PolicyNamePrefix)$GroupLabel - $($Group.Scope) - $($Group.PolicyType)"

    foreach ($Item in $Group.Items)
    {
        $Item.PolicyName = $PolicyName
    }

    $Settings  = @($Group.Items | Where-Object { $null -eq $_.PSObject.Properties['Rule'] })
    $Rules     = @($Group.Items | Where-Object { $null -ne $_.PSObject.Properties['Rule'] })
    $Conflict  = @($Group.Items | Where-Object { $_.IsConflict }).Count
    $NeedsWork = @($Settings | Where-Object { $_.MappingStatus -in @('Unmapped', 'MappingFileMissing', 'Discover', 'Review') }).Count

    [void]$PolicyPlan.Add(
        [PSCustomObject][ordered]@{
            PolicyName          = $PolicyName
            Tier                = $Tier
            SourceCount         = $Sources.Count
            $SourceLabel        = $Sources -join '; '
            Scope               = $Group.Scope
            PolicyType          = $Group.PolicyType
            Settings            = $Settings.Count
            FirewallRules       = $Rules.Count
            ConflictingItems    = $Conflict
            SettingsToReview    = $NeedsWork
        }
    )
}

# ------------------------------------------------------------
# Worksheet rows
# ------------------------------------------------------------

# Only the columns needed to build the Intune policies. The source column
# has the compare output's name: GPOName (XML) or ReportName (HTML).
# WinningGPO exists only in HTML output.
$HasWinningGpo = ($CandidateRows.Count -gt 0) -and ($null -ne $CandidateRows[0].PSObject.Properties['WinningGPO'])

$PolicySettingsRows =
    @(
        $PlacedSettings |
        Sort-Object PolicyName, Extension, Category, SettingName |
        ForEach-Object {
            $Out = [ordered]@{
                PolicyName    = $_.PolicyName
                $SourceColumn = $_.Sources -join '; '
                Class         = $_.Class
                SettingName   = $_.SettingName
                Value         = $_.Value
            }

            if ($HasWinningGpo)
            {
                $Out.WinningGPO = $_.WinningGPO
            }

            $Out.IntuneType    = $_.IntuneType
            $Out.IntuneSetting = $_.IntuneSetting
            $Out.MappingStatus = $_.MappingStatus
            $Out.Confidence    = $_.Confidence

            [PSCustomObject]$Out
        }
    )

$FirewallRuleRows =
    @(
        $PlacedRules |
        Sort-Object PolicyName |
        ForEach-Object {
            $Rule = $_.Rule
            $Out  = [ordered]@{
                PolicyName   = $_.PolicyName
                $SourceLabel = $_.Sources -join '; '
                Conflict     = if ($_.IsConflict) { 'Yes' } else { 'No' }
            }

            foreach ($Property in $Rule.PSObject.Properties)
            {
                if ($FirewallIgnore -notcontains $Property.Name)
                {
                    $Out[$Property.Name] = $Property.Value
                }
            }

            [PSCustomObject]$Out
        }
    )

$ConflictRows =
    @(
        @(
            $PlacedSettings |
            Where-Object { $_.IsConflict } |
            ForEach-Object {
                [PSCustomObject][ordered]@{
                    Kind         = 'Setting'
                    Scope        = $_.Scope
                    Item         = "$($_.Extension) / $($_.Category) / $($_.SettingName)"
                    Value        = $_.Value
                    $SourceLabel = $_.Sources -join '; '
                    PolicyName   = $_.PolicyName
                }
            }
        ) +
        @(
            $PlacedRules |
            Where-Object { $_.IsConflict } |
            ForEach-Object {
                [PSCustomObject][ordered]@{
                    Kind         = 'Firewall rule'
                    Scope        = $_.Scope
                    Item         = "$(Get-PropertyValue $_.Rule @('Name')) ($(Get-PropertyValue $_.Rule @('Direction')))"
                    Value        = "Action=$(Get-PropertyValue $_.Rule @('Action')); Profile=$(Get-PropertyValue $_.Rule @('Profile')); Protocol=$(Get-PropertyValue $_.Rule @('Protocol')); LocalPort=$(Get-PropertyValue $_.Rule @('LocalPort')); RemotePort=$(Get-PropertyValue $_.Rule @('RemotePort'))"
                    $SourceLabel = $_.Sources -join '; '
                    PolicyName   = $_.PolicyName
                }
            }
        ) |
        Sort-Object Kind, Item, PolicyName
    )

$NotMigratedRows =
    @(
        $NotMigrated |
        Sort-Object Reason, Extension, Category, SettingName |
        ForEach-Object {
            [PSCustomObject][ordered]@{
                Reason        = $_.Reason
                $SourceColumn = $_.Sources
                Class         = $_.Class
                SettingName   = $_.SettingName
                Value         = $_.Value
            }
        }
    )

$ConflictSettingCount = @($PlacedSettings | Where-Object { $_.IsConflict } | ForEach-Object { "$($_.Extension)$Sep$($_.Category)$Sep$($_.SettingName)$Sep$($_.Scope)" } | Sort-Object -Unique).Count
$ConflictRuleCount    = @($PlacedRules | Where-Object { $_.IsConflict } | ForEach-Object { "$(Get-PropertyValue $_.Rule @('Name'))$Sep$(Get-PropertyValue $_.Rule @('Direction'))" } | Sort-Object -Unique).Count

$SummaryRows = @(
    [PSCustomObject]@{ Item = 'Created';                      Value = (Get-Date).ToString(); Worksheet = '' }
    [PSCustomObject]@{ Item = "Input";                        Value = $(if ($script:InputMode -eq 'Csv') { "CSV files ($(if ($script:InputPrefix) { $script:InputPrefix } else { 'no prefix' }))" } else { [System.IO.Path]::GetFileName($script:InputWorkbook) }); Worksheet = '' }
    [PSCustomObject]@{ Item = $SourceLabel;                   Value = $AllSources.Count; Worksheet = '' }
    [PSCustomObject]@{ Item = 'Proposed Intune policies';     Value = $PolicyPlan.Count; Worksheet = 'PolicyPlan' }
    [PSCustomObject]@{ Item = '  Baseline policies';          Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Baseline' }).Count; Worksheet = 'PolicyPlan' }
    [PSCustomObject]@{ Item = '  Shared policies';            Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Shared' }).Count; Worksheet = 'PolicyPlan' }
    [PSCustomObject]@{ Item = '  Single-GPO policies';        Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Single' }).Count; Worksheet = 'PolicyPlan' }
    [PSCustomObject]@{ Item = 'Settings placed in policies';  Value = $PolicySettingsRows.Count; Worksheet = 'PolicySettings' }
    [PSCustomObject]@{ Item = 'Firewall rules placed';        Value = $FirewallRuleRows.Count; Worksheet = 'FirewallRules' }
    [PSCustomObject]@{ Item = 'Conflicting settings';         Value = $ConflictSettingCount; Worksheet = 'Conflicts' }
    [PSCustomObject]@{ Item = 'Conflicting firewall rules';   Value = $ConflictRuleCount; Worksheet = 'Conflicts' }
    [PSCustomObject]@{ Item = 'Settings not migrated';        Value = $NotMigratedRows.Count; Worksheet = 'NotMigrated' }
)

# ------------------------------------------------------------
# Write the workbook
# ------------------------------------------------------------

$WorkbookName = "$($script:InputPrefix)IntunePolicyPlan.xlsx"
$WorkbookPath = Join-Path $OutputFolder $WorkbookName
$script:TruncatedCells = 0

if (Test-Path -LiteralPath $WorkbookPath)
{
    try
    {
        Remove-Item -LiteralPath $WorkbookPath -Force -ErrorAction Stop
    }
    catch
    {
        throw "Cannot replace $($WorkbookPath): $($_.Exception.Message). Close it in Excel and run again."
    }
}

Write-SummarySheet -Path $WorkbookPath -Rows $SummaryRows
Write-PlanSheet    -Path $WorkbookPath -Name 'PolicyPlan'     -Rows @($PolicyPlan)
Write-PlanSheet    -Path $WorkbookPath -Name 'PolicySettings' -Rows $PolicySettingsRows
Write-PlanSheet    -Path $WorkbookPath -Name 'FirewallRules'  -Rows $FirewallRuleRows
Write-PlanSheet    -Path $WorkbookPath -Name 'Conflicts'      -Rows $ConflictRows
Write-PlanSheet    -Path $WorkbookPath -Name 'NotMigrated'    -Rows $NotMigratedRows

if ($script:TruncatedCells -gt 0)
{
    Write-Warning "$($script:TruncatedCells) value(s) were longer than 32767 characters and were cut to that length in the workbook."
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "====================================="
Write-Host "Intune Policy Plan Complete"
Write-Host "====================================="

foreach ($Row in $SummaryRows | Select-Object -Skip 1)
{
    Write-Host "$("$($Row.Item):".PadRight(32)) $($Row.Value)"
}

Write-Host ""
Write-Host "Written: $WorkbookPath"
