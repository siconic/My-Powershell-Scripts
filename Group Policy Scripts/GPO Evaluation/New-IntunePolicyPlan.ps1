<#
.SYNOPSIS
Group the settings of several GPOs into a proposed set of Intune policies.

.DESCRIPTION
Reads the output of Compare-GPOXml.ps1 or Compare-GPOHtml.ps1 (the CSV
files or the Excel workbook) and writes IntunePolicyPlan.xlsx: a proposed
set of Intune policies that together hold every migratable setting.

Grouping:
- The Baseline comes from the compare script's CommonSettings report
  (plus FirewallSettingsCommon for HTML output): a setting is Baseline
  when all its value rows are in it, that is, it is configured
  identically in every GPO. The Baseline policies are assigned to all
  devices (or all users, for User settings); every other policy is built
  on top of it. If the input has no CommonSettings, a warning is shown and
  the Baseline is calculated the same way from IntuneMigrationCandidates.
- Every other setting with a given value belongs to the exact set of GPOs
  that configure it with that value. All settings that share the same set
  of GPOs form one group, so each proposed policy can be assigned to the
  devices or users those GPOs applied to:
      Baseline   in CommonSettings: assigned to all devices / all users
      Shared     in two or more GPOs, but not in CommonSettings
      Single     in one GPO
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
    Counts for the run (each links to its worksheet or table), and below
    them the policy plan: one row per proposed Intune policy with its
    worksheet, tier, assignment (All devices / All users for the Baseline,
    "Devices of: ..." or "Users of: ..." otherwise), GPOs, scope, type and
    number of settings or firewall rules. Each policy name links to its
    worksheet. The Baseline source (CommonSettings, or calculated) is
    shown with the counts.

One worksheet per proposed policy, in plan order
    Titled with the full policy name, with a link back to Summary. The
    worksheet name is a simple "<group> - <type>" name, for example
    "Baseline - Settings", "GPO-A - User Settings" or "Shared 1 - Firewall
    Rules" (shared groups are numbered; their GPOs are in the plan).
    Excel limits worksheet names to 31 characters, so a long GPO name is
    cut at the last whole word that fits (the type is kept), and a
    repeated name gets " (2)". A settings
    policy has only the columns needed to build it, in this order: Class,
    WinningGPO (HTML only), IntuneType, IntuneSetting, Value,
    MappingStatus, Confidence. A firewall rules policy has a Conflict flag
    and the rule fields. The GPOs or reports of each policy are on the
    Summary.

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

function Test-CompareReport
{
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Whether the compare output has this report at all (an empty report
    # counts as present).
    if ($script:InputMode -eq 'Csv')
    {
        return (Test-Path -LiteralPath (Join-Path $script:InputFolder "$($script:InputPrefix)$($Name).csv") -PathType Leaf)
    }

    return (@(Get-ExcelSheetInfo -Path $script:InputWorkbook | ForEach-Object { $_.Name }) -contains $Name)
}

function Get-SettingRowKey
{
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter(Mandatory)]
        [string[]]$ValueNames,

        [Parameter(Mandatory)]
        [string[]]$StateNames
    )

    # Class, Extension, Category, SettingName, Value and State (XML only)
    # of one row, case ignored: the key the compare scripts use to build
    # CommonSettings.
    return (
        @(
            (Get-PropertyValue $Row @('Class'))
            (Get-PropertyValue $Row @('Extension'))
            (Get-PropertyValue $Row @('Category'))
            (Get-PropertyValue $Row @('SettingName'))
            (Get-PropertyValue $Row $ValueNames)
            (Get-PropertyValue $Row $StateNames)
        ) -join $Sep
    ).ToLowerInvariant()
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

function Set-LinkCell
{
    param(
        [Parameter(Mandatory)]
        [object]$Cell,

        [Parameter(Mandatory)]
        [string]$Worksheet,

        [Parameter(Mandatory)]
        [string]$Text,

        [string]$Address = 'A1'
    )

    # A blue, underlined link to a cell in this workbook.
    $Cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$($Worksheet)'!$($Address)", $Text)
    $Cell.Style.Font.UnderLine = $true
    $Cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(5, 99, 193))
}

function Write-PlanSheet
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object[]]$Rows,

        # Optional title in row 1, above the table, with a link back to the
        # Summary worksheet.
        [string]$Title,

        [string]$TableName
    )

    # One worksheet as a blue Excel table with a frozen header row, text
    # kept as text.
    $SheetRows = @($Rows)
    $TextCells = @()

    if ([string]::IsNullOrWhiteSpace($TableName))
    {
        $TableName = "$($Name)Table"
    }

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

    if ([string]::IsNullOrWhiteSpace($Title))
    {
        $Package = $SheetRows |
            Export-Excel -Path $Path -WorksheetName $Name -TableName $TableName -TableStyle Medium2 -FreezeTopRow -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

        $RowOffset = 0
    }
    else
    {
        # Title in row 1, table header in row 2; rows 1-2 stay visible.
        $Package = $SheetRows |
            Export-Excel -Path $Path -WorksheetName $Name -Title $Title -TitleBold -TitleSize 14 -TableName $TableName -TableStyle Medium2 -FreezePane 3, 1 -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

        $RowOffset = 1
    }

    $Worksheet = $Package.Workbook.Worksheets[$Name]

    foreach ($TextCell in $TextCells)
    {
        # Parentheses needed: the comma binds more tightly than +.
        $Cell         = $Worksheet.Cells[($TextCell.Row + $RowOffset), $TextCell.Column]
        $Cell.Formula = ""
        $Cell.Value   = $TextCell.Value
    }

    if (-not [string]::IsNullOrWhiteSpace($Title))
    {
        # Above the last table column, so it does not cover the title.
        $LastColumn = @($SheetRows[0].PSObject.Properties).Count
        Set-LinkCell -Cell $Worksheet.Cells[1, [Math]::Max(2, $LastColumn)] -Worksheet 'Summary' -Text 'Back to Summary'
    }

    Close-ExcelPackage -ExcelPackage $Package
}

function Get-PolicySheetName
{
    param(
        [Parameter(Mandatory)]
        [string]$Tier,

        [Parameter(Mandatory)]
        [string[]]$Sources,

        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$PolicyType,

        # GPO set -> "Shared N" number.
        [Parameter(Mandatory)]
        [hashtable]$SharedNumbers,

        # GPO -> its short worksheet label (Get-SourceSheetLabels), the same
        # on all of that GPO's worksheets.
        [Parameter(Mandatory)]
        [hashtable]$SourceLabels,

        # Worksheet names already used (keys; case ignored).
        [Parameter(Mandatory)]
        [hashtable]$UsedNames
    )

    # A simple name, "<group> - <type>": "Baseline - Settings",
    # "GPO-A - User Settings", "Shared 1 - Firewall Rules". Device is the
    # default scope, so only User (or Unknown) is named. Excel allows 31
    # characters and no [ ] : * ? / \ in a worksheet name. The type is
    # always kept whole; a long GPO name is cut at the last whole word that
    # fits. The full policy name is the worksheet's title.
    $TypeNames = @{
        'Settings Catalog'                             = 'Settings'
        'Endpoint security - Firewall'                 = 'Firewall'
        'Endpoint security - Firewall rules'           = 'Firewall Rules'
        'Endpoint security - Account protection'       = 'Account Protection'
        'Endpoint security - Attack surface reduction' = 'Attack Surface'
        'Endpoint security - Antivirus'                = 'Antivirus'
        'Endpoint security - Disk encryption'          = 'Disk Encryption'
        'Endpoint security - LAPS'                     = 'LAPS'
        'Needs review (no direct Intune policy)'       = 'Review'
        'Needs mapping'                                = 'Needs Mapping'
        'Remediation script'                           = 'Scripts'
    }

    $Type = if ($TypeNames.ContainsKey($PolicyType)) { $TypeNames[$PolicyType] } else { $PolicyType }

    if ($Scope -ne 'Device')
    {
        $Type = "$Scope $Type"
    }

    $Suffix   = " - $($Type -replace '[\[\]:\*\?/\\]', '')"
    $MaxGroup = [Math]::Max(1, 31 - $Suffix.Length)

    switch ($Tier)
    {
        'Baseline'
        {
            $GroupName = 'Baseline'
        }
        'Single'
        {
            $GroupName = if ($SourceLabels.ContainsKey($Sources[0])) { $SourceLabels[$Sources[0]] } else { $Sources[0] }
        }
        default
        {
            # Always a number, so one GPO set has the same name on each of
            # its worksheets. Its GPOs are listed in the plan on Summary.
            $SetKey = $Sources -join $Sep

            if (-not $SharedNumbers.ContainsKey($SetKey))
            {
                $SharedNumbers[$SetKey] = $SharedNumbers.Count + 1
            }

            $GroupName = "Shared $($SharedNumbers[$SetKey])"
        }
    }

    $GroupName = ($GroupName -replace '[\[\]:\*\?/\\]', '').Trim().Trim("'")
    $Name      = "$(Get-WordCut -Text $GroupName -MaxLength $MaxGroup)$Suffix"

    # Unique (case ignored) and not the name of another worksheet: a number
    # is added to the group part, so the type stays whole
    # ("Workstation 2 - Firewall Rules").
    $Copy = 1

    while ($UsedNames.ContainsKey($Name) -or ($Name -in @('Summary', 'Conflicts', 'NotMigrated', 'History')))
    {
        $Copy++
        $Number = " $Copy"
        $Name   = "$(Get-WordCut -Text $GroupName -MaxLength ($MaxGroup - $Number.Length))$Number$Suffix"
    }

    $UsedNames[$Name] = $true

    return $Name
}

function Get-SourceSheetLabels
{
    param(
        [AllowNull()]
        [string[]]$Sources
    )

    # GPO -> a short label for its worksheet names: the name cut at the
    # last whole word within 14 characters, which fits beside almost every
    # type within Excel's 31 characters. Two GPOs with the same label get a
    # number ("Workstation", "Workstation 2"), so each GPO has one label on
    # all its worksheets.
    $MaxLength = 14
    $Labels    = @{}
    $Used      = @{}

    foreach ($Source in @($Sources))
    {
        $Clean = ("$Source" -replace '[\[\]:\*\?/\\]', '').Trim().Trim("'")
        $Label = Get-WordCut -Text $Clean -MaxLength $MaxLength
        $Copy  = 1

        while ($Used.ContainsKey($Label) -or ($Label -eq 'Baseline') -or ($Label -match '^Shared \d+$'))
        {
            $Copy++
            $Number = " $Copy"
            $Label  = "$(Get-WordCut -Text $Clean -MaxLength ($MaxLength - $Number.Length))$Number"
        }

        $Used[$Label]    = $true
        $Labels[$Source] = $Label
    }

    return $Labels
}

function Get-WordCut
{
    param(
        [AllowEmptyString()]
        [string]$Text,

        [int]$MaxLength
    )

    # The text, cut at the last whole word that fits in MaxLength
    # characters (or at MaxLength when the first word is longer).
    if ($MaxLength -lt 1)
    {
        $MaxLength = 1
    }

    if ($Text.Length -le $MaxLength)
    {
        return $Text
    }

    $Cut       = $Text.Substring(0, $MaxLength + 1)
    $LastSpace = $Cut.LastIndexOf(' ')

    if ($LastSpace -ge 3)
    {
        $Cut = $Cut.Substring(0, $LastSpace)
    }
    else
    {
        $Cut = $Text.Substring(0, $MaxLength)
    }

    return $Cut.TrimEnd(' ', '-', '+', '_', '.', ',', "'")
}

function Write-SummarySheet
{
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object[]]$Rows,

        [AllowNull()]
        [object[]]$PlanRows
    )

    # The Summary worksheet: the counts table (Item, Value) with a title,
    # and below it the policy plan table with a title. A count with a
    # Worksheet links to that worksheet ('#Plan' = the policy plan table
    # below). Each policy name links to its own worksheet.
    $TableRows = @($Rows | ForEach-Object { [PSCustomObject]@{ Item = $_.Item; Value = $_.Value } })

    # Row 1: title, row 2: counts header, then the counts, one empty row,
    # the plan title and the plan header.
    $PlanTitleRow = 2 + $TableRows.Count + 2

    $Package = $TableRows |
        Export-Excel -Path $Path -WorksheetName 'Summary' -Title 'Intune Policy Plan' -TitleBold -TitleSize 14 -TableName 'SummaryTable' -TableStyle Medium2 -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    $PlanTable = @($PlanRows)

    if ($PlanTable.Count -eq 0)
    {
        $PlanTable = @([PSCustomObject]@{ Result = "No rows" })
    }

    $Package = $PlanTable |
        Export-Excel -ExcelPackage $Package -WorksheetName 'Summary' -StartRow $PlanTitleRow -Title 'Proposed Intune Policies' -TitleBold -TitleSize 14 -TableName 'PolicyPlanTable' -TableStyle Medium2 -AutoSize -NoNumberConversion '*' -NoHyperLinkConversion '*' -PassThru

    $Worksheet = $Package.Workbook.Worksheets['Summary']

    # Counts: row 3 is the first count.
    $RowNumber = 2

    foreach ($Row in $Rows)
    {
        $RowNumber++

        if ([string]::IsNullOrWhiteSpace($Row.Worksheet))
        {
            continue
        }

        if ($Row.Worksheet -eq '#Plan')
        {
            Set-LinkCell -Cell $Worksheet.Cells[$RowNumber, 1] -Worksheet 'Summary' -Text $Row.Item -Address "A$($PlanTitleRow)"
        }
        else
        {
            Set-LinkCell -Cell $Worksheet.Cells[$RowNumber, 1] -Worksheet $Row.Worksheet -Text $Row.Item
        }
    }

    # Policy names: the plan header is one row below the plan title.
    $RowNumber = $PlanTitleRow + 1

    foreach ($Row in @($PlanRows))
    {
        $RowNumber++
        Set-LinkCell -Cell $Worksheet.Cells[$RowNumber, 1] -Worksheet $Row.Worksheet -Text $Row.PolicyName
    }

    Close-ExcelPackage -ExcelPackage $Package
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
# Baseline: CommonSettings
# ------------------------------------------------------------

# The Baseline - the policies for all devices and all users - is taken
# from the compare script's CommonSettings report: settings configured
# identically in every GPO. HTML output keeps common firewall settings in
# FirewallSettingsCommon instead, so that report is read too. A setting is
# Baseline when all its value rows are in these reports. Without
# CommonSettings (for example, only some files were copied), the Baseline
# is calculated here the same way from IntuneMigrationCandidates.
$CommonRowKeys     = [System.Collections.Generic.HashSet[string]]::new()
$UseCommonSettings = Test-CompareReport -Name 'CommonSettings'

if ($UseCommonSettings)
{
    foreach ($Row in (@(Read-CompareReport -Name 'CommonSettings') + @(Read-CompareReport -Name 'FirewallSettingsCommon')))
    {
        [void]$CommonRowKeys.Add((Get-SettingRowKey -Row $Row -ValueNames @('Value') -StateNames @('State')))
    }

    $BaselineSource = "CommonSettings"
    Write-Host "Baseline: from CommonSettings ($($CommonRowKeys.Count) rows)"
}
else
{
    $BaselineSource = "Calculated (CommonSettings not found)"
    Write-Warning "CommonSettings was not found in the input. The Baseline is calculated from IntuneMigrationCandidates: settings with the same values in every GPO or report."
}

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

# Setting key -> $true while every value row of the setting is in
# CommonSettings.
$SettingAllCommon = @{}

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
        $SettingInfo[$SettingKey]      = $Row
        $SettingValues[$SettingKey]    = @{}
        $SettingWinning[$SettingKey]   = @{}
        $SettingAllCommon[$SettingKey] = $true
    }

    if (-not $CommonRowKeys.Contains((Get-SettingRowKey -Row $Row -ValueNames @('GPOValue', 'Value') -StateNames @('GPOState'))))
    {
        $SettingAllCommon[$SettingKey] = $false
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

    # Baseline: every value row of the setting is in CommonSettings. Without
    # CommonSettings: the same values in every GPO. (Every row in
    # CommonSettings means the same values in every GPO, so a Baseline
    # setting has one value group.)
    if ($UseCommonSettings)
    {
        $IsBaseline = [bool]$SettingAllCommon[$SettingKey]
    }
    else
    {
        $IsBaseline = ($ByValue.Count -eq 1) -and (@($SettingValues[$SettingKey].Keys).Count -eq $AllSources.Count)
    }

    foreach ($Group in $ByValue.Values)
    {
        $Sources = @($Group.Sources | Sort-Object)

        $Item =
            [PSCustomObject]@{
                Scope         = $Scope
                PolicyType    = $PolicyType
                Sources       = $Sources
                SourceKey     = if ($IsBaseline) { '#baseline' } else { ($Sources -join $Sep).ToLowerInvariant() }
                IsBaseline    = $IsBaseline
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

        # Baseline: the same rule configuration in every GPO (the rule
        # compare scripts' FirewallRulesCommon uses the same test).
        $IsBaseline = $Sources.Count -eq $AllSources.Count

        [void]$PlacedRules.Add(
            [PSCustomObject]@{
                Scope      = 'Device'
                PolicyType = 'Endpoint security - Firewall rules'
                Sources    = $Sources
                SourceKey  = if ($IsBaseline) { '#baseline' } else { ($Sources -join $Sep).ToLowerInvariant() }
                IsBaseline = $IsBaseline
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
        # A Baseline policy applies to all devices or users, so its GPOs are
        # all of them.
        $PolicyGroups[$PolicyKey] = [PSCustomObject]@{
            Sources    = if ($Item.IsBaseline) { $AllSources } else { $Item.Sources }
            IsBaseline = $Item.IsBaseline
            Scope      = $Item.Scope
            PolicyType = $Item.PolicyType
            Items      = [System.Collections.ArrayList]::new()
        }
    }

    [void]$PolicyGroups[$PolicyKey].Items.Add($Item)
}

# Order: Baseline first, then most GPOs first, then by GPO names, scope
# and type.
$OrderedGroups =
    @(
        $PolicyGroups.Values |
        Sort-Object `
            @{ Expression = { [int]$_.IsBaseline }; Descending = $true },
            @{ Expression = { @($_.Sources).Count }; Descending = $true },
            @{ Expression = { @($_.Sources) -join '; ' } },
            @{ Expression = { $_.Scope } },
            @{ Expression = { $_.PolicyType } }
    )

# Shared groups with long GPO lists get a number instead of the list, in
# the policy name and (separately, when the names do not fit in 31
# characters) in the worksheet name.
$SharedNumbers      = @{}
$SheetSharedNumbers = @{}
$UsedSheetNames     = @{}
$SourceSheetLabels  = Get-SourceSheetLabels -Sources $AllSources
$PolicyPlan         = [System.Collections.ArrayList]::new()
$PolicyNumber       = 0

foreach ($Group in $OrderedGroups)
{
    $PolicyNumber++
    $Sources = @($Group.Sources)

    if ($Group.IsBaseline)
    {
        $Tier = 'Baseline'
    }
    elseif ($Sources.Count -gt 1)
    {
        $Tier = 'Shared'
    }
    else
    {
        $Tier = 'Single'
    }

    # Who the policy is assigned to.
    $ScopeGroup = if ($Group.Scope -eq 'User') { 'users' } else { 'devices' }

    if ($Group.IsBaseline)
    {
        $Assignment = "All $ScopeGroup"
    }
    else
    {
        $Assignment = "$((Get-Culture).TextInfo.ToTitleCase($ScopeGroup)) of: $($Sources -join '; ')"
    }

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
    # The worksheet name is a simple "<group> - <type>" name and leaves out
    # -PolicyNamePrefix, which is the same on every sheet.
    $SheetName  =
        Get-PolicySheetName `
            -Tier $Tier `
            -Sources $Sources `
            -Scope $Group.Scope `
            -PolicyType $Group.PolicyType `
            -SharedNumbers $SheetSharedNumbers `
            -SourceLabels $SourceSheetLabels `
            -UsedNames $UsedSheetNames

    $Group | Add-Member -NotePropertyName PolicyName -NotePropertyValue $PolicyName
    $Group | Add-Member -NotePropertyName SheetName  -NotePropertyValue $SheetName
    $Group | Add-Member -NotePropertyName Number     -NotePropertyValue $PolicyNumber

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
            Worksheet           = $SheetName
            Tier                = $Tier
            Assignment          = $Assignment
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

function Get-PolicySheetRows
{
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    # The rows of one policy's worksheet. Settings: only the columns needed
    # to build the Intune policy. Firewall rules: the rule fields.
    $Settings = @($Group.Items | Where-Object { $null -eq $_.PSObject.Properties['Rule'] })
    $Rules    = @($Group.Items | Where-Object { $null -ne $_.PSObject.Properties['Rule'] })

    # The policy name is the worksheet, and the GPOs / reports are on the
    # Summary, so neither is repeated here. Column order as requested:
    # Class, WinningGPO (HTML only), IntuneType, IntuneSetting, Value,
    # MappingStatus, Confidence.
    foreach ($Item in @($Settings | Sort-Object Extension, Category, SettingName))
    {
        $Out = [ordered]@{
            Class = $Item.Class
        }

        if ($HasWinningGpo)
        {
            $Out.WinningGPO = $Item.WinningGPO
        }

        $Out.IntuneType    = $Item.IntuneType
        $Out.IntuneSetting = $Item.IntuneSetting
        $Out.Value         = $Item.Value
        $Out.MappingStatus = $Item.MappingStatus
        $Out.Confidence    = $Item.Confidence

        [PSCustomObject]$Out
    }

    foreach ($Item in @($Rules | Sort-Object { Get-PropertyValue $_.Rule @('Name') }))
    {
        $Out = [ordered]@{
            Conflict = if ($Item.IsConflict) { 'Yes' } else { 'No' }
        }

        foreach ($Property in $Item.Rule.PSObject.Properties)
        {
            if ($FirewallIgnore -notcontains $Property.Name)
            {
                $Out[$Property.Name] = $Property.Value
            }
        }

        [PSCustomObject]$Out
    }
}

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
            # Full detail, like Conflicts: only the policy worksheets use
            # the shortened column set.
            [PSCustomObject][ordered]@{
                Reason       = $_.Reason
                Class        = $_.Class
                Extension    = $_.Extension
                Category     = $_.Category
                SettingName  = $_.SettingName
                Value        = $_.Value
                $SourceLabel = $_.Sources
            }
        }
    )

$ConflictSettingCount = @($PlacedSettings | Where-Object { $_.IsConflict } | ForEach-Object { "$($_.Extension)$Sep$($_.Category)$Sep$($_.SettingName)$Sep$($_.Scope)" } | Sort-Object -Unique).Count
$ConflictRuleCount    = @($PlacedRules | Where-Object { $_.IsConflict } | ForEach-Object { "$(Get-PropertyValue $_.Rule @('Name'))$Sep$(Get-PropertyValue $_.Rule @('Direction'))" } | Sort-Object -Unique).Count

$SummaryRows = @(
    [PSCustomObject]@{ Item = 'Created';                      Value = (Get-Date).ToString(); Worksheet = '' }
    [PSCustomObject]@{ Item = "Input";                        Value = $(if ($script:InputMode -eq 'Csv') { "CSV files ($(if ($script:InputPrefix) { $script:InputPrefix } else { 'no prefix' }))" } else { [System.IO.Path]::GetFileName($script:InputWorkbook) }); Worksheet = '' }
    [PSCustomObject]@{ Item = 'Baseline source';              Value = $BaselineSource; Worksheet = '' }
    [PSCustomObject]@{ Item = $SourceLabel;                   Value = $AllSources.Count; Worksheet = '' }
    [PSCustomObject]@{ Item = 'Proposed Intune policies';     Value = $PolicyPlan.Count; Worksheet = '#Plan' }
    [PSCustomObject]@{ Item = '  Baseline policies';          Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Baseline' }).Count; Worksheet = '#Plan' }
    [PSCustomObject]@{ Item = '  Shared policies';            Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Shared' }).Count; Worksheet = '#Plan' }
    [PSCustomObject]@{ Item = '  Single-GPO policies';        Value = @($PolicyPlan | Where-Object { $_.Tier -eq 'Single' }).Count; Worksheet = '#Plan' }
    [PSCustomObject]@{ Item = 'Settings placed in policies';  Value = $PlacedSettings.Count; Worksheet = '' }
    [PSCustomObject]@{ Item = 'Firewall rules placed';        Value = $PlacedRules.Count; Worksheet = '' }
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

# Summary (counts and the policy plan), one worksheet per policy in plan
# order, then Conflicts and NotMigrated.
Write-SummarySheet -Path $WorkbookPath -Rows $SummaryRows -PlanRows @($PolicyPlan)

foreach ($Group in $OrderedGroups)
{
    Write-PlanSheet `
        -Path $WorkbookPath `
        -Name $Group.SheetName `
        -Title $Group.PolicyName `
        -TableName "Policy$($Group.Number)Table" `
        -Rows @(Get-PolicySheetRows -Group $Group)
}

Write-PlanSheet -Path $WorkbookPath -Name 'Conflicts'   -Rows $ConflictRows
Write-PlanSheet -Path $WorkbookPath -Name 'NotMigrated' -Rows $NotMigratedRows

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
