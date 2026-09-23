<#
.SYNOPSIS
Import manual GPO-to-Intune mappings from Excel workbooks into
IntunePolicyMappings.json.

.DESCRIPTION
Reads workbooks in which GPO policies were mapped to Intune by hand, and
saves each mapping to IntunePolicyMappings.json. Compare-GPOXml.ps1 and
Compare-GPOHtml.ps1 use that file to map a GPO setting to its Intune
setting automatically, by policy name.

Workbook layout (column names and positions may vary between workbooks):
- One header row, within the first 5 rows, with a "Policy" column and at
  least one column whose name contains "Intune".
- Category rows: a row with no policy, usually merged across the left
  columns, for example "Security Settings > Account Policies > Password
  Policy". It applies to the policy rows below it.
- Policy rows, with these columns where present:
    Category, Sub-Category        (optional)
    Policy                        the GPO policy name
    Setting / Setting / Value     the GPO value (read but not stored)
    Intune Setting                for example "device lock"
    Intune Sub Setting            for example "Minimum Password Length"
    Remarks, Comment(s), Rema,    notes; several are joined with " | "
    Migration status
- An Intune cell merged across several policy rows applies to each of
  them.
- Worksheets without a Policy and an Intune column (GPO summary or
  metadata, firewall rules, Preferences) are skipped.

Class: a worksheet whose name contains "User" is User configuration;
every other worksheet is Computer configuration.

Each policy row is one of:
    Mapped               it has an Intune setting or sub setting
    NoIntuneEquivalent   no Intune setting, but a remark
    (blank)              neither; not stored. Workbooks may leave a policy
                         blank when another workbook maps it.
An Intune cell with no letter or digit (for example "`") counts as empty.

A policy is identified by Class + policy name + the last part of its
category path (case and spacing ignored). The last part is used because
workbooks write the full path differently ("Account Policies/Password
Policy", "Security Settings > Account Policies > Password Policy"), and
because some policy names exist in several categories with different
Intune settings (the Application, Security, Setup and System event logs;
WinRM Client and WinRM Service). When workbooks give different mappings
for one policy, the first one read is used and the others are kept as
alternates. A Mapped row replaces a NoIntuneEquivalent entry for the same
policy.

By default the mapping file is scrubbed, so it can be kept in a public
repository. Identifying details are kept out of it:
- GPO values are not stored.
- Remarks are not stored. They are still read, to tell a reviewed
  "no Intune equivalent" row from a blank one.
- Rows that are permission entries ("Allow: DOMAIN\Group", "Deny: ...")
  are skipped.
- Sources: each mapping records the mapping file's own name (for example
  IntunePolicyMappings.json), not the workbook and worksheet names. The
  import report (-ReportPath) still shows the workbook and worksheet.
- Every text written (policy, category, Intune setting) is redacted: URLs -> <URL>, UNC paths -> <UNC-PATH>, email addresses ->
  <EMAIL>, IPv4 addresses -> <IP>, host and domain names -> <DOMAIN-NAME>,
  DOMAIN\account -> <DOMAIN>\<ACCOUNT> (registry roots such as SYSTEM\ and
  BUILTIN\ are kept), and each term in the redaction file (for example an
  organization name) -> its placeholder.
The redaction file lists the organization-specific terms. It must not be
committed to a public repository, because the terms themselves identify
the organization.

With -KeepSensitiveData, nothing is redacted and remarks are included, for
an organization that needs to see them internally. That file is written
to IntunePolicyMappings.Internal.json by default and records
"scrubbed": false. Scrubbed and unscrubbed data are never merged into one
file. Permission rows are skipped and GPO values are not stored in both
modes.

.PARAMETER Path
One or more workbook files (.xlsx) or folders. For a folder, every .xlsx
file in it is read, in name order.

.PARAMETER MappingPath
The mapping file to write. Default: IntunePolicyMappings.json next to
this script, or IntunePolicyMappings.Internal.json with
-KeepSensitiveData.

.PARAMETER KeepSensitiveData
Write the mapping file without scrubbing: workbook names, categories,
policy names and Intune text exactly as written, and remarks included.
For internal use by an organization that needs to see them; do not commit
the file to a public repository. Use it with the compare scripts through
their -PolicyMappingPath parameter. An existing file is only added to
when it was written in the same mode (otherwise use -Rebuild or another
-MappingPath).

.PARAMETER Rebuild
Start a new mapping file from the given workbooks only. Without it, the
workbooks are added to the existing file. Use -Rebuild with every
workbook after changing a mapping in a workbook; otherwise the old
mapping stays and the changed one is kept as an alternate.

.PARAMETER ReportPath
Optional CSV file with one row per policy row read: source, class,
policy, result (Added, AddedSource, Alternate, ReplacedNoEquivalent,
Skipped-Blank, Skipped-Duplicate, Skipped-Permission) and the Intune
setting. Its text is redacted like the mapping file, and it has remarks
only with -KeepSensitiveData.

.PARAMETER RedactionPath
Local file of organization-specific terms to replace, one per line:
"term" (replaced with <ORG>) or "term=placeholder". Lines starting with #
are ignored. Whole words only, case ignored. Default:
IntuneMappingRedactions.txt next to this script. Optional; without it
only the built-in patterns are redacted. Keep this file out of the
repository.

.EXAMPLE
.\Import-IntuneMappingWorkbook.ps1 -Path "C:\GPOProject\Mappings" -Rebuild

.EXAMPLE
.\Import-IntuneMappingWorkbook.ps1 -Path ".\New-Policy-Settings.xlsx" -ReportPath ".\ImportReport.csv"

.EXAMPLE
.\Import-IntuneMappingWorkbook.ps1 -Path "C:\GPOProject\Mappings" -Rebuild -KeepSensitiveData
.\Compare-GPOHtml.ps1 -HtmlFolder "C:\GPOProject\HTML" -OutputFolder "C:\GPOProject\Output" -PolicyMappingPath ".\IntunePolicyMappings.Internal.json"

.NOTES
Author:  Siconic
Version: 1.0

Needs the ImportExcel module (Install-Module ImportExcel -Scope
CurrentUser). Excel itself is not needed.

Changelog:
  1.0 - Initial version.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Path,

    [string]$MappingPath,

    [switch]$KeepSensitiveData,

    [switch]$Rebuild,

    [string]$ReportPath,

    [string]$RedactionPath = (Join-Path $PSScriptRoot "IntuneMappingRedactions.txt")
)

$ErrorActionPreference = "Stop"

$Sep = [string][char]0x1F

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

# Scrubbed (default): identifying details redacted, no remarks; safe for a
# public repository. -KeepSensitiveData: everything as written in the
# workbooks, including remarks; for internal use only, written to a
# separate file by default.
$Scrubbed = -not $KeepSensitiveData

if ([string]::IsNullOrWhiteSpace($MappingPath))
{
    if ($Scrubbed)
    {
        $MappingPath = Join-Path $PSScriptRoot "IntunePolicyMappings.json"
    }
    else
    {
        $MappingPath = Join-Path $PSScriptRoot "IntunePolicyMappings.Internal.json"
    }
}

if (-not $Scrubbed)
{
    Write-Warning "-KeepSensitiveData: the mapping file will contain workbook names, remarks and any other text exactly as written in the workbooks. Do not commit it to a public repository: $MappingPath"
}

if (@(Get-Module -ListAvailable -Name ImportExcel).Count -eq 0)
{
    throw "The ImportExcel module is not installed. Install it with: Install-Module ImportExcel -Scope CurrentUser"
}

Import-Module ImportExcel -ErrorAction Stop

$WorkbookFiles = [System.Collections.ArrayList]::new()

foreach ($Item in $Path)
{
    if (Test-Path -LiteralPath $Item -PathType Container)
    {
        foreach ($File in @(Get-ChildItem -LiteralPath $Item -Filter *.xlsx -File | Sort-Object Name))
        {
            # Skip Excel's temporary lock files (~$name.xlsx).
            if (-not $File.Name.StartsWith('~$'))
            {
                [void]$WorkbookFiles.Add($File.FullName)
            }
        }
    }
    elseif (Test-Path -LiteralPath $Item -PathType Leaf)
    {
        [void]$WorkbookFiles.Add((Resolve-Path -LiteralPath $Item).ProviderPath)
    }
    else
    {
        throw "Workbook or folder not found: $Item"
    }
}

if ($WorkbookFiles.Count -eq 0)
{
    throw "No .xlsx workbooks found in: $($Path -join ', ')"
}

# ------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------

function Get-CategoryLeaf
{
    param(
        [AllowNull()]
        [string]$CategoryPath
    )

    # The last part of a category path, split on ">" or "/": "Security
    # Settings > Account Policies > Password Policy" and "Account
    # Policies/Password Policy" both give "password policy". Workbooks
    # write the full path in different ways, but the last part is the same.
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
        [string]$Class,
        [string]$Policy
    )

    # Class + policy name, case and spacing ignored.
    return "$($Class.ToLowerInvariant())$Sep$((($Policy -replace '\s+', ' ').Trim()).ToLowerInvariant())"
}

function Get-PolicyKey
{
    param(
        [string]$Class,
        [string]$Policy,
        [AllowNull()]
        [string]$CategoryPath
    )

    # Class + policy name + last category part. Some policy names exist in
    # several categories with different Intune settings (for example
    # "Specify the maximum log file size (KB)" for the Application,
    # Security, Setup and System event logs), so the name alone is not
    # enough.
    return "$(Get-PolicyNameKey -Class $Class -Policy $Policy)$Sep$(Get-CategoryLeaf -CategoryPath $CategoryPath)"
}

function Get-TargetKey
{
    param(
        [AllowNull()]
        [string]$IntuneSetting,

        [AllowNull()]
        [string]$IntuneSubSetting
    )

    return "$((("$IntuneSetting" -replace '\s+', ' ').Trim()).ToLowerInvariant())$Sep$((("$IntuneSubSetting" -replace '\s+', ' ').Trim()).ToLowerInvariant())"
}

function Get-CellText
{
    param(
        [Parameter(Mandatory)]
        [object]$Worksheet,

        [Parameter(Mandatory)]
        [hashtable]$MergedCells,

        [int]$Row,

        [int]$Column
    )

    if ($Column -le 0)
    {
        return ""
    }

    # A cell inside a merged range takes the value of the range's top-left
    # cell.
    $Key = "$Row,$Column"

    if ($MergedCells.ContainsKey($Key))
    {
        $Row    = $MergedCells[$Key][0]
        $Column = $MergedCells[$Key][1]
    }

    return (("$($Worksheet.Cells[$Row, $Column].Text)" -replace '\s+', ' ').Trim())
}

function Import-RedactionTerms
{
    param(
        [AllowNull()]
        [string]$Path
    )

    # Reads the local redaction terms file. One term per line, optionally
    # "term=placeholder" (default placeholder <ORG>). Empty lines and lines
    # starting with # are ignored. The file is not committed, because the
    # terms themselves are the identifying data.
    $Terms = [System.Collections.ArrayList]::new()

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $Terms
    }

    foreach ($Line in @(Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $Text = "$Line".Trim()

        if (($Text -eq '') -or $Text.StartsWith('#'))
        {
            continue
        }

        $Parts       = $Text -split '=', 2
        $Term        = $Parts[0].Trim()
        $Placeholder = if ($Parts.Count -gt 1 -and $Parts[1].Trim() -ne '') { $Parts[1].Trim() } else { '<ORG>' }

        if ($Term -ne '')
        {
            [void]$Terms.Add(
                [PSCustomObject]@{
                    Term        = $Term
                    Placeholder = $Placeholder
                }
            )
        }
    }

    return $Terms
}

function Protect-Text
{
    param(
        [AllowNull()]
        [string]$Text
    )

    # Replaces identifying details with placeholders. Applied to every text
    # written to the mapping file. With -KeepSensitiveData the text is
    # returned unchanged.
    if ([string]::IsNullOrEmpty($Text) -or (-not $Scrubbed))
    {
        return $Text
    }

    # Terms from the local redaction file (for example an organization
    # name), as whole words, case ignored. Longest first, so a longer term
    # is not cut by a shorter one inside it.
    foreach ($Entry in @($script:RedactionTerms | Sort-Object { $_.Term.Length } -Descending))
    {
        $Text = [regex]::Replace($Text, "(?i)(?<![A-Za-z0-9])$([regex]::Escape($Entry.Term))(?![A-Za-z0-9])", $Entry.Placeholder)
    }

    # URLs, UNC paths, email addresses, IPv4 addresses.
    $Text = [regex]::Replace($Text, '(?i)\b(https?|ftp)://[^\s|;,"]+', '<URL>')
    $Text = [regex]::Replace($Text, '\\\\[A-Za-z0-9._$-]+(\\[^\s|;,"]*)?', '<UNC-PATH>')
    $Text = [regex]::Replace($Text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<EMAIL>')
    $Text = [regex]::Replace($Text, '\b\d{1,3}(\.\d{1,3}){3}\b', '<IP>')

    # Host and domain names with a common top-level domain.
    $Text = [regex]::Replace($Text, '(?i)\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|local|lan|corp|internal|int|gov|edu|mil|biz|us|uk|ca)\b', '<DOMAIN-NAME>')

    # DOMAIN\account. Registry roots (SYSTEM\..., SOFTWARE\...) and the
    # built-in BUILTIN domain are not accounts and are left as they are.
    $Text = [regex]::Replace($Text, '\b(?!(?:SYSTEM|SOFTWARE|MACHINE|USER|HKLM|HKCU|HKCR|HKU|HKCC|BUILTIN|HKEY_[A-Z_]+)\\)[A-Z][A-Z0-9_-]{1,15}\\[^\s\\|;,"]+', '<DOMAIN>\<ACCOUNT>')

    return $Text
}

function Get-SourceLabel
{
    param(
        [AllowNull()]
        [string]$Label
    )

    # The source recorded for a mapping. Scrubbed files record the mapping
    # file's own name instead of workbook and worksheet names, which can
    # identify the organization. With -KeepSensitiveData the workbook and
    # worksheet label is kept.
    if ($Scrubbed)
    {
        return [System.IO.Path]::GetFileName($MappingPath)
    }

    return $Label
}

function Get-IntuneText
{
    param(
        [AllowNull()]
        [string]$Text
    )

    # An Intune cell with no letter or digit (for example a stray "`" or
    # "-") is treated as empty.
    if ("$Text" -notmatch '[A-Za-z0-9]')
    {
        return ""
    }

    return $Text
}

function Get-MergedCellMap
{
    param(
        [Parameter(Mandatory)]
        [object]$Worksheet
    )

    # Every cell of a merged range -> the row and column of its top-left
    # cell.
    $Map = @{}

    foreach ($Address in @($Worksheet.MergedCells))
    {
        if ([string]::IsNullOrWhiteSpace($Address))
        {
            continue
        }

        $Range = New-Object OfficeOpenXml.ExcelAddress $Address

        foreach ($Row in $Range.Start.Row..$Range.End.Row)
        {
            foreach ($Column in $Range.Start.Column..$Range.End.Column)
            {
                $Map["$Row,$Column"] = @($Range.Start.Row, $Range.Start.Column)
            }
        }
    }

    return $Map
}

function Find-HeaderColumns
{
    param(
        [Parameter(Mandatory)]
        [object]$Worksheet,

        [Parameter(Mandatory)]
        [hashtable]$MergedCells
    )

    # Returns the header row and the column of each field, or $null when
    # the worksheet has no Policy column and Intune column in its first 5
    # rows.
    $LastRow    = $Worksheet.Dimension.End.Row
    $LastColumn = $Worksheet.Dimension.End.Column

    foreach ($Row in 1..[Math]::Min(5, $LastRow))
    {
        # A plain hashtable: an [ordered] dictionary treats an integer key
        # as a position, not a key.
        $Headers = @{}

        foreach ($Column in 1..$LastColumn)
        {
            $Headers[$Column] = Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Column
        }

        $HasPolicy = @($Headers.Values | Where-Object { $_ -match '(?i)^policy( name)?$' }).Count -gt 0
        $HasIntune = @($Headers.Values | Where-Object { $_ -match '(?i)intune' }).Count -gt 0

        if (-not ($HasPolicy -and $HasIntune))
        {
            continue
        }

        $Columns = [PSCustomObject]@{
            HeaderRow     = $Row
            Category      = 0
            SubCategory   = 0
            Policy        = 0
            IntuneSetting = 0
            IntuneSub     = 0
            Notes         = [System.Collections.ArrayList]::new()
        }

        foreach ($Column in 1..$LastColumn)
        {
            $Text = $Headers[$Column]

            if ($Text -match '(?i)^category$')
            {
                $Columns.Category = $Column
            }
            elseif ($Text -match '(?i)^sub-?\s?category$')
            {
                $Columns.SubCategory = $Column
            }
            elseif ($Text -match '(?i)^policy( name)?$')
            {
                $Columns.Policy = $Column
            }
            elseif ($Text -match '(?i)sub.?\s?sett')
            {
                # "Sub Setting", "Intune Sub Settings", "Intune Sub-setting",
                # "Intune Setting Sub-Setting"
                if ($Columns.IntuneSub -eq 0)
                {
                    $Columns.IntuneSub = $Column
                }
            }
            elseif ($Text -match '(?i)intune\s*set+i+n?g')
            {
                # "Intune Setting", including the misspelling "Setiing"
                if ($Columns.IntuneSetting -eq 0)
                {
                    $Columns.IntuneSetting = $Column
                }
            }
            elseif ($Text -match '(?i)^(remarks?|rema|comments?|migration status)$')
            {
                [void]$Columns.Notes.Add($Column)
            }
        }

        return $Columns
    }

    return $null
}

function Read-MappingWorkbook
{
    param(
        [Parameter(Mandatory)]
        [string]$File
    )

    # Returns one object per policy row, and prints what was read from each
    # worksheet.
    $Rows    = [System.Collections.ArrayList]::new()
    $Package = Open-ExcelPackage -Path $File
    $Name    = [System.IO.Path]::GetFileName($File)

    try
    {
        foreach ($Worksheet in $Package.Workbook.Worksheets)
        {
            if ($null -eq $Worksheet.Dimension)
            {
                continue
            }

            $MergedCells = Get-MergedCellMap -Worksheet $Worksheet
            $Columns     = Find-HeaderColumns -Worksheet $Worksheet -MergedCells $MergedCells

            if ($null -eq $Columns)
            {
                Write-Host "  $($Worksheet.Name): skipped (no Policy and Intune columns)"
                continue
            }

            $Class         = if ($Worksheet.Name -match '(?i)user') { 'User' } else { 'Computer' }
            $CategoryPath  = ""
            $PolicyRows    = 0

            foreach ($Row in ($Columns.HeaderRow + 1)..$Worksheet.Dimension.End.Row)
            {
                $Policy = Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Columns.Policy
                $First  = Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column 1

                # A category row has no policy of its own. When it is merged
                # across the left columns, the Policy cell shows the
                # category text, so a Policy cell merged from column 1 also
                # means a category row.
                $PolicyKey        = "$Row,$($Columns.Policy)"
                $PolicyMergedLeft = $MergedCells.ContainsKey($PolicyKey) -and ($MergedCells[$PolicyKey][1] -eq 1) -and ($Columns.Policy -ne 1)

                if (($Policy -eq '') -or $PolicyMergedLeft)
                {
                    if ($First -ne '')
                    {
                        $CategoryPath = $First
                    }

                    continue
                }

                # A permission entry of a registry or file ACL ("Allow:
                # DOMAIN\Group") is data, not a policy name, and
                # contains account and group names. The compare scripts
                # never produce a setting with such a name.
                if ($Policy -match '(?i)^(allow|deny)\s*:')
                {
                    [void]$Rows.Add(
                        [PSCustomObject]@{
                            Workbook         = Protect-Text "$Name / $($Worksheet.Name)"
                            Source           = Get-SourceLabel (Protect-Text "$Name / $($Worksheet.Name)")
                            Row              = $Row
                            Class            = $Class
                            CategoryPath     = Protect-Text $CategoryPath
                            Policy           = Protect-Text $Policy
                            IntuneSetting    = ""
                            IntuneSubSetting = ""
                            Remarks          = ""
                            Skip             = 'Skipped-Permission'
                        }
                    )

                    continue
                }

                $Notes =
                    @(
                        foreach ($Column in $Columns.Notes)
                        {
                            $Text = Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Column

                            if ($Text -ne '')
                            {
                                $Text
                            }
                        }
                    ) -join ' | '

                # With Category / Sub-Category columns, the row's own
                # category is more specific than the category row above.
                $RowCategory =
                    @(
                        Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Columns.Category
                        Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Columns.SubCategory
                    ) | Where-Object { $_ -ne '' }

                # Every text is redacted here, before the policy key is
                # built, so keys from a redacted mapping file and from a new
                # import are the same.
                [void]$Rows.Add(
                    [PSCustomObject]@{
                        Workbook         = Protect-Text "$Name / $($Worksheet.Name)"
                        Source           = Get-SourceLabel (Protect-Text "$Name / $($Worksheet.Name)")
                        Row              = $Row
                        Class            = $Class
                        CategoryPath     = Protect-Text $(if ($CategoryPath -ne '') { $CategoryPath } else { @($RowCategory) -join ' > ' })
                        Policy           = Protect-Text $Policy
                        IntuneSetting    = Get-IntuneText (Protect-Text (Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Columns.IntuneSetting))
                        IntuneSubSetting = Get-IntuneText (Protect-Text (Get-CellText -Worksheet $Worksheet -MergedCells $MergedCells -Row $Row -Column $Columns.IntuneSub))
                        Remarks          = Protect-Text $Notes
                        Skip             = ''
                    }
                )

                $PolicyRows++
            }

            Write-Host "  $($Worksheet.Name): $PolicyRows policy rows ($Class)"
        }
    }
    finally
    {
        Close-ExcelPackage -ExcelPackage $Package -NoSave
    }

    return $Rows
}

# ------------------------------------------------------------
# Redaction terms
# ------------------------------------------------------------

$script:RedactionTerms = @(Import-RedactionTerms -Path $RedactionPath)

if (-not $Scrubbed)
{
    Write-Host "Redaction: off (-KeepSensitiveData)."
}
elseif ($script:RedactionTerms.Count -gt 0)
{
    Write-Host "Redaction terms: $($script:RedactionTerms.Count) loaded ($RedactionPath)"
}
else
{
    Write-Host "Redaction terms: none ($RedactionPath not found or empty). Only the built-in patterns are redacted."
}

# ------------------------------------------------------------
# Load the existing mapping file
# ------------------------------------------------------------

# Key (Get-PolicyKey) -> mapping entry, in the order entries were added.
$Entries = [ordered]@{}

if ((-not $Rebuild) -and (Test-Path -LiteralPath $MappingPath -PathType Leaf))
{
    $Existing =
        Get-Content -LiteralPath $MappingPath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    # A scrubbed file and an unscrubbed file must not be mixed: the merged
    # file would be partly redacted, and keys would not match. A file
    # without the "scrubbed" field was written scrubbed.
    $ExistingScrubbed = ($null -eq $Existing.scrubbed) -or ($Existing.scrubbed -eq $true)

    if ($ExistingScrubbed -ne $Scrubbed)
    {
        if ($ExistingScrubbed)
        {
            throw "$MappingPath was written scrubbed; this run uses -KeepSensitiveData. Use -Rebuild or a different -MappingPath."
        }

        throw "$MappingPath was written with -KeepSensitiveData; this run is scrubbed. Use -Rebuild or a different -MappingPath."
    }

    foreach ($Policy in @($Existing.policies))
    {
        $Entries[(Get-PolicyKey -Class $Policy.class -Policy $Policy.policy -CategoryPath $Policy.categoryPath)] =
            [PSCustomObject]@{
                class            = $Policy.class
                policy           = $Policy.policy
                categoryPath     = $Policy.categoryPath
                status           = $Policy.status
                intuneSetting    = $Policy.intuneSetting
                intuneSubSetting = $Policy.intuneSubSetting
                remarks          = $Policy.remarks
                # A scrubbed file's sources become the mapping file name,
                # also for entries written before that rule.
                sources          = [System.Collections.ArrayList]@(@($Policy.sources | Where-Object { $null -ne $_ } | ForEach-Object { Get-SourceLabel $_ } | Select-Object -Unique))
                alternates       = [System.Collections.ArrayList]@(
                    @(
                        $Policy.alternates |
                        Where-Object { $null -ne $_ } |
                        ForEach-Object {
                            [PSCustomObject]@{
                                intuneSetting    = $_.intuneSetting
                                intuneSubSetting = $_.intuneSubSetting
                                remarks          = $_.remarks
                                source           = Get-SourceLabel $_.source
                            }
                        }
                    )
                )
            }
    }

    Write-Host "Existing mapping file: $($Entries.Count) policies ($MappingPath)"
}
elseif ($Rebuild)
{
    Write-Host "Rebuild: starting a new mapping file."
}

# ------------------------------------------------------------
# Read the workbooks and merge
# ------------------------------------------------------------

$Report = [System.Collections.ArrayList]::new()

foreach ($File in $WorkbookFiles)
{
    Write-Host ""
    Write-Host "Reading: $File"

    foreach ($Row in @(Read-MappingWorkbook -File $File))
    {
        $Key       = Get-PolicyKey -Class $Row.Class -Policy $Row.Policy -CategoryPath $Row.CategoryPath
        $HasIntune = ($Row.IntuneSetting -ne '') -or ($Row.IntuneSubSetting -ne '')
        $Status    = if ($HasIntune) { 'Mapped' } elseif ($Row.Remarks -ne '') { 'NoIntuneEquivalent' } else { '' }
        $Result    = ''

        $Existing = $null

        if ($Entries.Contains($Key))
        {
            $Existing = $Entries[$Key]
        }

        if ($Row.Skip -ne '')
        {
            $Result = $Row.Skip
        }
        elseif ($Status -eq '')
        {
            $Result = 'Skipped-Blank'
        }
        elseif ($null -eq $Existing)
        {
            $Entries[$Key] =
                [PSCustomObject]@{
                    class            = $Row.Class
                    policy           = $Row.Policy
                    categoryPath     = $Row.CategoryPath
                    status           = $Status
                    intuneSetting    = $Row.IntuneSetting
                    intuneSubSetting = $Row.IntuneSubSetting
                    remarks          = $Row.Remarks
                    sources          = [System.Collections.ArrayList]@($Row.Source)
                    alternates       = [System.Collections.ArrayList]::new()
                }

            $Result = 'Added'
        }
        elseif (($Status -eq 'Mapped') -and ($Existing.status -eq 'NoIntuneEquivalent'))
        {
            # A real mapping replaces a "no equivalent" remark.
            $Existing.status           = 'Mapped'
            $Existing.intuneSetting    = $Row.IntuneSetting
            $Existing.intuneSubSetting = $Row.IntuneSubSetting

            if ($Row.Remarks -ne '')
            {
                $Existing.remarks = $Row.Remarks
            }

            if ($Existing.sources -notcontains $Row.Source)
            {
                [void]$Existing.sources.Add($Row.Source)
            }

            $Result = 'ReplacedNoEquivalent'
        }
        elseif (($Status -eq 'NoIntuneEquivalent') -and ($Existing.status -eq 'Mapped'))
        {
            # The policy is already mapped from another workbook.
            $Result = 'Skipped-Duplicate'
        }
        elseif (
            (Get-TargetKey $Existing.intuneSetting $Existing.intuneSubSetting) -eq
            (Get-TargetKey $Row.IntuneSetting $Row.IntuneSubSetting)
        )
        {
            # Same mapping from another workbook or worksheet.
            if ($Existing.sources -notcontains $Row.Source)
            {
                [void]$Existing.sources.Add($Row.Source)
                $Result = 'AddedSource'
            }
            else
            {
                $Result = 'Skipped-Duplicate'
            }

            if ([string]::IsNullOrEmpty($Existing.remarks) -and ($Row.Remarks -ne ''))
            {
                $Existing.remarks = $Row.Remarks
            }
        }
        else
        {
            # A different mapping for the same policy: keep it as an
            # alternate, once.
            $TargetKey = Get-TargetKey $Row.IntuneSetting $Row.IntuneSubSetting
            $Known     = @($Existing.alternates | Where-Object { (Get-TargetKey $_.intuneSetting $_.intuneSubSetting) -eq $TargetKey }).Count -gt 0

            if ($Known)
            {
                $Result = 'Skipped-Duplicate'
            }
            else
            {
                [void]$Existing.alternates.Add(
                    [PSCustomObject]@{
                        intuneSetting    = $Row.IntuneSetting
                        intuneSubSetting = $Row.IntuneSubSetting
                        remarks          = $Row.Remarks
                        source           = $Row.Source
                    }
                )

                $Result = 'Alternate'
            }
        }

        [void]$Report.Add(
            [PSCustomObject]@{
                Source           = $Row.Workbook
                Row              = $Row.Row
                Class            = $Row.Class
                Policy           = $Row.Policy
                Result           = $Result
                IntuneSetting    = $Row.IntuneSetting
                IntuneSubSetting = $Row.IntuneSubSetting
                Remarks          = if ($Scrubbed) { '' } else { $Row.Remarks }
            }
        )
    }
}

# ------------------------------------------------------------
# Write the mapping file
# ------------------------------------------------------------

# Scrubbed files have no remarks, for the policy or its alternates.
$Policies =
    @(
        $Entries.Values |
        Sort-Object class, categoryPath, policy |
        ForEach-Object {
            $Policy = [ordered]@{
                class            = $_.class
                policy           = $_.policy
                categoryPath     = $_.categoryPath
                status           = $_.status
                intuneSetting    = $_.intuneSetting
                intuneSubSetting = $_.intuneSubSetting
            }

            if (-not $Scrubbed)
            {
                $Policy.remarks = $_.remarks
            }

            $Policy.sources    = @($_.sources)
            $Policy.alternates =
                @(
                    foreach ($Alternate in @($_.alternates))
                    {
                        $Copy = [ordered]@{
                            intuneSetting    = $Alternate.intuneSetting
                            intuneSubSetting = $Alternate.intuneSubSetting
                        }

                        if (-not $Scrubbed)
                        {
                            $Copy.remarks = $Alternate.remarks
                        }

                        $Copy.source = $Alternate.source

                        [PSCustomObject]$Copy
                    }
                )

            [PSCustomObject]$Policy
        }
    )

$Description = "GPO policy to Intune setting mappings, imported from manual mapping workbooks by Import-IntuneMappingWorkbook.ps1. Compare-GPOXml.ps1 and Compare-GPOHtml.ps1 match a setting by class + policy name (case and spacing ignored). Status Mapped: intuneSetting / intuneSubSetting is the Intune equivalent. Status NoIntuneEquivalent: reviewed in a workbook, no Intune setting. alternates: other mappings given for the same policy in other workbooks."

if ($Scrubbed)
{
    $Description += " scrubbed = true: identifying details are replaced with placeholders and remarks are not included."
}
else
{
    $Description += " scrubbed = false: written with -KeepSensitiveData; text is as written in the workbooks, including remarks. Internal use only."
}

$Document =
    [PSCustomObject][ordered]@{
        schemaVersion = "1.0"
        description   = $Description
        scrubbed      = $Scrubbed
        updated       = (Get-Date).ToString('s')
        policies      = $Policies
    }

$Json = ConvertTo-Json -InputObject $Document -Depth 6

# Windows PowerShell 5.1 writes the characters < > ' & as JSON escape
# codes (backslash, "u00", then 3c, 3e, 27 or 26). Both forms are valid
# JSON; the plain characters keep the file readable. The escape codes are
# built from their parts so this file does not contain them literally.
$Unicode = [string][char]92 + 'u00'

$Json = $Json.
    Replace($Unicode + '3c', '<').
    Replace($Unicode + '3e', '>').
    Replace($Unicode + '27', "'").
    Replace($Unicode + '26', '&')

# UTF-8 without a byte order mark.
[System.IO.File]::WriteAllText($MappingPath, $Json, [System.Text.UTF8Encoding]::new($false))

if (-not [string]::IsNullOrWhiteSpace($ReportPath))
{
    $Report | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
}

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

$ReportRows = @($Report)
$Blank      = @($ReportRows | Where-Object { $_.Result -eq 'Skipped-Blank' })

# A blank row is still open only when no workbook maps that policy name,
# in any category.
$MappedNames = @{}

foreach ($Entry in $Entries.Values)
{
    $MappedNames[(Get-PolicyNameKey -Class $Entry.class -Policy $Entry.policy)] = $true
}

$BlankMapped = @($Blank | Where-Object { $MappedNames.ContainsKey((Get-PolicyNameKey -Class $_.Class -Policy $_.Policy)) })

$OpenBlank =
    @(
        $Blank |
        Where-Object { -not $MappedNames.ContainsKey((Get-PolicyNameKey -Class $_.Class -Policy $_.Policy)) } |
        Sort-Object Class, Policy -Unique
    )

$WithAlternates = @($Policies | Where-Object { @($_.alternates).Count -gt 0 })

Write-Host ""
Write-Host "====================================="
Write-Host "Import Complete"
Write-Host "====================================="
Write-Host "Workbooks read:                 $($WorkbookFiles.Count)"
Write-Host "Policy rows read:               $($ReportRows.Count)"
Write-Host "Policies in the mapping file:   $($Policies.Count)"
Write-Host "  Mapped:                       $(@($Policies | Where-Object { $_.status -eq 'Mapped' }).Count)"
Write-Host "  NoIntuneEquivalent:           $(@($Policies | Where-Object { $_.status -eq 'NoIntuneEquivalent' }).Count)"
Write-Host "Blank rows:                     $($Blank.Count)"
Write-Host "  mapped in another workbook:   $($BlankMapped.Count)"
Write-Host "  not mapped anywhere:          $($OpenBlank.Count) distinct policies"
Write-Host "Permission rows skipped:        $(@($ReportRows | Where-Object { $_.Result -eq 'Skipped-Permission' }).Count)"
Write-Host "Policies with alternates:       $($WithAlternates.Count)"

foreach ($Policy in $WithAlternates)
{
    Write-Host "  $($Policy.class): $($Policy.policy)"
    Write-Host "      used:      $($Policy.intuneSetting) >> $($Policy.intuneSubSetting)"

    foreach ($Alternate in @($Policy.alternates))
    {
        Write-Host "      alternate: $($Alternate.intuneSetting) >> $($Alternate.intuneSubSetting)  [$($Alternate.source)]"
    }
}

Write-Host ""
Write-Host "Mapping file written: $MappingPath"

if (-not [string]::IsNullOrWhiteSpace($ReportPath))
{
    Write-Host "Import report written: $ReportPath"
}
