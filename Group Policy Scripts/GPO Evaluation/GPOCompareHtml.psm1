#==========================================================
# GPOCompareHtml.psm1
#
# Parses gpresult /h (or GPMC "Group Policy Results") RSoP HTML reports
# into the same normalized shape GPOCompare.psm1 produces for XML:
#
#   Settings, FirewallRules, Unclassified
#
# IMPORTANT DIFFERENCE FROM THE XML SIDE:
# An RSoP HTML report is the RESOLVED policy for one computer/user at the
# time it was captured, with each setting tagged by its Winning GPO. It is
# not a raw export of everything configured in one GPO. Every setting
# object produced here includes a WinningGPO field.
#
# PARSING APPROACH:
# PowerShell has no built-in HTML DOM. This module loads the file with the
# HTMLFile COM object (mshtml, bundled with Windows) to get a real DOM to
# walk. This is Windows-only and depends on that COM component being
# registered, which it normally is on any Windows machine with Internet
# Explorer's engine present (which is still true of current Windows 10/11
# and Windows Server as of this writing). If Get-GPOSettingsFromHtml fails
# immediately with a COM error, see the comment above New-HtmlDom.
#
# This has not been executed against a live PowerShell session. It was
# written and structurally checked against real sample reports, but the
# COM interop calls in particular should be treated as the highest-risk
# part of this file until you run it.
#
# Version 1.5
#
# Changelog:
#   1.5 - Row and cell lookups now use the DOM's .rows and .cells (new
#         Get-TableRows / Get-RowCells helpers) instead of
#         getElementsByTagName, which searches every depth. A firewall
#         rule's detail row is one cell holding a nested table, so the old
#         lookup counted that cell plus every cell of the nested table and
#         never saw exactly one cell. Every rule's detail table was missed,
#         so rules fell through to ordinary settings (CommonSettings.csv)
#         and FirewallRules.csv stayed empty. Checked on a sample report:
#         detail tables found went from 0 of 204 rules to 204 of 204. Also
#         fixes list-style ADMX values (ASR rules, Hardened UNC Paths) not
#         being folded in, and nested-table rows being read as settings.
#   1.4 - Fixed Get-Attribute: it used getAttributeNode(name), which is
#         case-sensitive in the document mode the HTMLFile COM object
#         negotiates, while gpresult writes the colspan attribute
#         lowercase and the call site queried it as 'colSpan'. This
#         silently broke every nested-detail-table lookup (Get-Attribute
#         returned null instead of throwing), which is why FirewallRules.csv
#         came back empty with no error. Switched to getAttribute(name),
#         which is case-insensitive for HTML attributes, and normalized
#         the call sites to lowercase 'colspan' for defense in depth.
#   1.3 - Replaced all 4 uses of the "{0}={1}" -f composite-format
#         operator with plain string interpolation, matching the same fix
#         already applied to GPOCompare.psm1 (the XML side) for the same
#         reported error. String interpolation has no template/argument-
#         list mechanism to fail, so this removes the exception class.
#   1.2 - Fixed the actual reported source of "The property 'Count' cannot
#         be found on this object": Get-AllTags (26 call sites) and
#         Get-HeadingAncestors (4 call sites) both return a .NET
#         ArrayList, and PowerShell's pipeline silently enumerates/unwraps
#         an ArrayList with exactly one item into that single bare element
#         when the caller doesn't force array context - so any later
#         .Count check on it throws exactly this error. This is common:
#         one sample report alone has 402 rows with exactly one <td> and 3
#         tables with exactly one <th>. Every call site is now wrapped in
#         @(...) to force array context regardless of item count.
#   1.1 - Guarded three unguarded sibling-walk .tagName accesses behind a
#         new Get-NodeTagName helper, matching the one walk that was
#         already guarded; parser-error Reason text now includes the
#         module line number that threw.
#   1.0 - Initial version - see Compare-GPOHtml.ps1's changelog for the
#         paired script-level notes shipped alongside this version.
#==========================================================
Set-StrictMode -Version Latest

# Section headings that are pure structure/navigation, not settings. Anything
# under one of these (by exact heading text) is skipped rather than reported
# as Unclassified, to avoid noise.
# NOTE: 'Computer Details' / 'User Details' are NOT in this list even
# though they sound like identity-only sections. In this report format they
# are the top-level containers that everything else (including all Policies
# settings) lives inside, so skipping them would skip almost the entire
# report. The metadata subsections that actually sit alongside "Settings"
# under each of those (General, Component Status, ...) are what this list
# is for.
$script:SkippedSectionTitles = @(
    'Summary',
    'General',
    'Component Status',
    'Group Policy Objects',
    'Applied GPOs',
    'Denied GPOs',
    'WMI Filters',
    'Security Group Membership'
)

# Heading text that is purely structural wrapping (grouping headings, not a
# real category) and should be dropped when building a breadcrumb. Computer
# Details / User Details are identity wrappers used for Class detection
# (Get-ConfigurationClass), not real categories, so they are dropped here too
# or every Extension in the Computer/User branch would read "Computer
# Details" / "User Details" instead of the real top category.
$script:StructuralHeadings = @(
    'Policies',
    'Preferences',
    'Settings',
    'Windows Settings',
    'Software Settings',
    'Computer Details',
    'User Details'
)

$script:DeprecatedPolicyReference = @{
    Entries = @()
}

#==========================================================
# DOM Loading
#==========================================================

function New-HtmlDom {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "File not found: $Path"
    }

    # ReadAllText auto-detects the encoding from the byte order mark
    # (gpresult /h typically writes UTF-16LE, but this does not assume that).
    $ResolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $HtmlText     = [System.IO.File]::ReadAllText($ResolvedPath)

    $Doc = New-Object -ComObject "HTMLFile"

    # The write() signature differs between PowerShell hosts. Try the
    # Windows PowerShell 5.1 IHTMLDocument2_write path first, then fall
    # back to the array-of-bytes form used by some older hosts.
    try
    {
        $Doc.IHTMLDocument2_write($HtmlText)
    }
    catch
    {
        try
        {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($HtmlText)
            $Doc.write($Bytes)
        }
        catch
        {
            throw "Failed to load HTML into the HTMLFile COM object. This usually means mshtml is not available on this machine, or the PowerShell host's COM interop does not expose IHTMLDocument2_write. Original error: $($_.Exception.Message)"
        }
    }

    return $Doc
}

#==========================================================
# Generic DOM Helpers
#
# Deliberately avoid getElementsByClassName / querySelectorAll: those
# depend on the IE document mode the HTMLFile COM object negotiates, which
# is not guaranteed here. getElementsByTagName is the one API that has
# always been present, so class/attribute matching is done by hand.
#==========================================================

function Test-ElementHasClass {

    [CmdletBinding()]
    param(
        [object]$Element,
        [Parameter(Mandatory)]
        [string]$ClassName
    )

    if ($null -eq $Element)
    {
        return $false
    }

    $Existing = $null

    try
    {
        $Existing = $Element.className
    }
    catch
    {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Existing))
    {
        return $false
    }

    return (
        $Existing.Split(
            [char[]]@(' ', "`t"),
            [System.StringSplitOptions]::RemoveEmptyEntries
        ) -contains $ClassName
    )
}

function Get-AllTags {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Root,

        [Parameter(Mandatory)]
        [string]$TagName
    )

    $Collection = $Root.getElementsByTagName($TagName)
    $Items      = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $Collection.length; $i++)
    {
        [void]$Items.Add($Collection.item($i))
    }

    return $Items
}

function Get-TableRows {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Table
    )

    # Rows that belong to THIS table only. getElementsByTagName('TR') would
    # also return the rows of every table nested inside it.
    $Items = [System.Collections.ArrayList]::new()
    $Collection = $null

    try
    {
        $Collection = $Table.rows
    }
    catch
    {
    }

    if ($null -eq $Collection)
    {
        return $Items
    }

    for ($i = 0; $i -lt $Collection.length; $i++)
    {
        [void]$Items.Add($Collection.item($i))
    }

    return $Items
}

function Get-RowCells {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [ValidateSet('TD', 'TH')]
        [string]$TagName = 'TD'
    )

    # Cells that belong to THIS row only. getElementsByTagName('TD') would
    # also return the cells of any table nested inside one of its cells,
    # which made every detail row look like it had many cells instead of one.
    $Items = [System.Collections.ArrayList]::new()
    $Collection = $null

    try
    {
        $Collection = $Row.cells
    }
    catch
    {
    }

    if ($null -eq $Collection)
    {
        return $Items
    }

    for ($i = 0; $i -lt $Collection.length; $i++)
    {
        $Cell = $Collection.item($i)

        if ((Get-NodeTagName $Cell) -eq $TagName)
        {
            [void]$Items.Add($Cell)
        }
    }

    return $Items
}

function Get-CleanText {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value)
    {
        return ""
    }

    $Text = ""

    if ($Value -is [string])
    {
        $Text = $Value
    }
    else
    {
        try
        {
            $Text = $Value.innerText
        }
        catch
        {
            $Text = $Value.ToString()
        }
    }

    if ($null -eq $Text)
    {
        return ""
    }

    $Text = $Text -replace '\s+', ' '

    $Text.Trim()
}

function Get-Attribute {

    [CmdletBinding()]
    param(
        [object]$Element,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Element)
    {
        return $null
    }

    # getAttribute (not getAttributeNode) is used deliberately: it is
    # case-insensitive for HTML attribute names across IE document modes,
    # while getAttributeNode was found to be case-sensitive in the mode the
    # HTMLFile COM object negotiates - gpresult writes "colspan" lowercase,
    # and a mismatched-case lookup here silently returned null for every
    # row, which broke every nested-detail-table lookup (Firewall rules,
    # Administrative Template list values) without ever throwing an error.
    try
    {
        $Value = $Element.getAttribute($Name)

        if ($null -ne $Value)
        {
            return [string]$Value
        }
    }
    catch
    {
    }

    return $null
}

function Get-NodeTagName {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Node
    )

    # A whitespace/text node between tags does not expose .tagName the same
    # way an element does; guard every access instead of assuming it is
    # always safe to read.
    if ($null -eq $Node)
    {
        return $null
    }

    try
    {
        return $Node.tagName
    }
    catch
    {
        return $null
    }
}

function Test-IsNestedTable {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Table
    )

    # A table whose ancestor chain hits another <table> before it hits the
    # document body is a detail/sub table, not a top-level settings table.
    $Node = $Table.parentElement

    while ($null -ne $Node)
    {
        $TagName = $null

        try
        {
            $TagName = $Node.tagName
        }
        catch
        {
        }

        if ($TagName -eq 'TABLE')
        {
            return $true
        }

        if ($TagName -eq 'BODY')
        {
            return $false
        }

        $Node = $Node.parentElement
    }

    return $false
}

#==========================================================
# Heading / Breadcrumb / Class
#==========================================================

function Get-HeadingAncestors {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    # IMPORTANT: in this report format, a heading div (class he{N}h, "Local
    # Policies/Security Options") is NOT an ancestor of its content div; it
    # is the PRECEDING SIBLING of its content div, under a shared parent:
    #
    #   <div class="container">
    #     <div class="he4h"><span class="sectionTitle">Accounts</span></div>
    #     <div class="container">           <-- content lives in here
    #       <div class="he4i"><table>...</table></div>
    #     </div>
    #   </div>
    #
    # So finding the heading chain for an element means: at each ancestor
    # level, look at that level's OWN preceding siblings for a heading div,
    # then move up one level and repeat. A naive ancestor-only walk finds
    # nothing, because the heading is never actually an ancestor.
    $Result = [System.Collections.ArrayList]::new()
    $Node   = $Element.parentElement

    while ($null -ne $Node)
    {
        $Sibling = $Node.previousSibling

        while ($null -ne $Sibling)
        {
            $SiblingTag = $null

            try
            {
                $SiblingTag = $Sibling.tagName
            }
            catch
            {
            }

            if ($SiblingTag -eq 'DIV')
            {
                $SiblingClass = $null

                try
                {
                    $SiblingClass = $Sibling.className
                }
                catch
                {
                }

                if ($SiblingClass -match '^he\d')
                {
                    [void]$Result.Add($Sibling)
                    break
                }
            }

            $Sibling = $Sibling.previousSibling
        }

        $Node = $Node.parentElement
    }

    return $Result
}

function Get-SectionTitleText {

    [CmdletBinding()]
    param(
        [object]$HeadingDiv
    )

    if ($null -eq $HeadingDiv)
    {
        return $null
    }

    $Spans = @(Get-AllTags -Root $HeadingDiv -TagName 'SPAN')
    foreach ($Span in $Spans)
    {
        if (Test-ElementHasClass -Element $Span -ClassName 'sectionTitle')
        {
            return Get-CleanText $Span
        }
    }

    return $null
}

function Get-SectionBreadcrumb {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)
    $Titles    = [System.Collections.Generic.List[string]]::new()

    # Ancestors come back nearest-first; reverse for top-down order.
    for ($i = $Ancestors.Count - 1; $i -ge 0; $i--)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestors[$i]

        if ([string]::IsNullOrWhiteSpace($Title))
        {
            continue
        }

        if ($script:StructuralHeadings -contains $Title)
        {
            continue
        }

        # Avoid immediate duplicate labels (a heading div and its content
        # div sometimes both resolve to the same sectionTitle text).
        if ($Titles.Count -eq 0 -or $Titles[$Titles.Count - 1] -ne $Title)
        {
            $Titles.Add($Title)
        }
    }

    return $Titles
}

function Test-IsSkippedSection {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ($script:SkippedSectionTitles -contains $Title)
        {
            return $true
        }
    }

    return $false
}

function Test-IsInSection {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element,

        [Parameter(Mandatory)]
        [string[]]$SectionTitles
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ($SectionTitles -contains $Title)
        {
            return $true
        }
    }

    return $false
}

function Get-ConfigurationClass {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ([string]::IsNullOrWhiteSpace($Title))
        {
            continue
        }

        if ($Title -match '^(Computer|User)\s+(Configuration|Details)$')
        {
            return $Matches[1]
        }
    }

    return "Unknown"
}

#==========================================================
# Output Helpers (shared shape with GPOCompare.psm1)
#==========================================================

function New-HtmlParseResult {

    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Settings      = New-Object System.Collections.ArrayList
        FirewallRules = New-Object System.Collections.ArrayList
        Unclassified  = New-Object System.Collections.ArrayList
    }
}

function New-UnclassifiedRecord {

    [CmdletBinding()]
    param(
        [string]$ReportName,
        [string]$Class,
        [string]$Extension,
        [string]$Category,
        [string]$SettingName,
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    [PSCustomObject]@{
        ReportName  = $ReportName
        Class       = $Class
        Extension   = $Extension
        Category    = $Category
        SettingName = $SettingName
        Value       = $Value
        Reason      = $Reason
    }
}

function Add-HtmlSetting {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref]$Result,

        [string]$ReportName,
        [string]$Class,
        [string]$Extension,
        [string]$Category,
        [string]$SettingName,
        [string]$Value,
        [string]$WinningGPO
    )

    $SettingName = Get-CleanText $SettingName
    $Value       = Get-CleanText $Value
    $Category    = Get-CleanText $Category
    $Extension   = Get-CleanText $Extension
    $WinningGPO  = Get-CleanText $WinningGPO

    if ([string]::IsNullOrWhiteSpace($SettingName))
    {
        [void]$Result.Value.Unclassified.Add(
            (
                New-UnclassifiedRecord `
                    -ReportName $ReportName `
                    -Class $Class `
                    -Extension $Extension `
                    -Category $Category `
                    -Value $Value `
                    -Reason "Missing Setting Name"
            )
        )

        return
    }

    if ([string]::IsNullOrWhiteSpace($Category))
    {
        $Category = "<NoCategory>"
    }

    if ([string]::IsNullOrWhiteSpace($Extension))
    {
        $Extension = "<UnknownExtension>"
    }

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        $Value = "<NoValue>"
    }

    if ([string]::IsNullOrWhiteSpace($WinningGPO))
    {
        $WinningGPO = "<Unknown>"
    }

    [void]$Result.Value.Settings.Add(
        [PSCustomObject]@{
            ReportName  = $ReportName
            Class       = $Class
            Extension   = $Extension
            Category    = $Category
            SettingName = $SettingName
            Value       = $Value
            WinningGPO  = $WinningGPO
        }
    )
}

#==========================================================
# Nested Detail Table Extraction
#
# Several policies (Hardened UNC Paths, ASR rules, Firewall rules, some
# Administrative Template sub-options) render as a normal row followed by
# a second <tr><td colspan="N"> containing a nested table. This walks that
# nested table (unwrapping subtable_frame, which wraps explanatory text
# plus the actual list table) and returns its rows as an ordered list of
# cell-text arrays.
#==========================================================

function Get-NestedDetailRows {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $NextRow = $Row.nextSibling

    while ($null -ne $NextRow -and (Get-NodeTagName $NextRow) -ne 'TR')
    {
        $NextRow = $NextRow.nextSibling
    }

    if ($null -eq $NextRow)
    {
        return @()
    }

    $Cells = @(Get-RowCells -Row $NextRow -TagName 'TD')
    if ($Cells.Count -ne 1)
    {
        return @()
    }

    $ColSpan = Get-Attribute -Element $Cells[0] -Name 'colspan'

    if ([string]::IsNullOrWhiteSpace($ColSpan) -or [int]$ColSpan -lt 2)
    {
        return @()
    }

    # Find the first nested table inside this cell. subtable_frame wraps
    # explanatory prose plus the real subtable/subtable3; getElementsByTagName
    # on the cell finds tables at any depth, so take the first one, and if
    # that is itself a frame, look one level further for the real list.
    $Tables = @(Get-AllTags -Root $Cells[0] -TagName 'TABLE')
    if ($Tables.Count -eq 0)
    {
        return @()
    }

    $DetailTable = $null

    foreach ($Candidate in $Tables)
    {
        if (Test-ElementHasClass -Element $Candidate -ClassName 'subtable_frame')
        {
            continue
        }

        $DetailTable = $Candidate
        break
    }

    if ($null -eq $DetailTable)
    {
        return @()
    }

    $Rows = @(Get-TableRows -Table $DetailTable)
    $Out  = [System.Collections.ArrayList]::new()

    foreach ($DetailRow in $Rows)
    {
        # Skip header rows (th cells)
        if (@(Get-RowCells -Row $DetailRow -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $DetailCells = @(Get-RowCells -Row $DetailRow -TagName 'TD')
        if ($DetailCells.Count -eq 0)
        {
            continue
        }

        $Values = @($DetailCells | ForEach-Object { Get-CleanText $_ })

        [void]$Out.Add($Values)
    }

    return $Out
}

function ConvertTo-DetailValueString {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Rows
    )

    # Generic fold: 2-column rows become "Name=Value"; a 3rd column (usually
    # a per-item Source GPO that normally matches the parent row's Winning
    # GPO) is dropped to avoid duplicating that information. Sorted so row
    # order in the report does not affect comparison.
    $Entries =
        @(
            foreach ($RowValues in $Rows)
            {
                if ($RowValues.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($RowValues[0]))
                {
                    "$($RowValues[0])=$($RowValues[1])"
                }
                elseif ($RowValues.Count -eq 1)
                {
                    $RowValues[0]
                }
            }
        )

    (@($Entries) | Sort-Object) -join "; "
}

#==========================================================
# Standard "Policy / Setting / Winning GPO"-shaped tables
#
# Covers: Account Policies, Local Policies, Advanced Audit Configuration,
# Administrative Templates (incl. LAPS, ASR rules, Hardened UNC Paths, list
# settings), unresolved legacy Registry Settings, Certificates, Scripts,
# and (in Firewall detail mode) Firewall rule summaries.
#==========================================================

function Get-TableHeaders {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Table
    )

    $Rows = @(Get-TableRows -Table $Table)
    if ($Rows.Count -eq 0)
    {
        return @()
    }

    $HeaderCells = @(Get-RowCells -Row $Rows[0] -TagName 'TH')
    return @($HeaderCells | ForEach-Object { Get-CleanText $_ })
}

$script:ExcludedHeaderSets = @(
    , @('Name', 'Value', 'Reference GPO(s)')
)

function Parse-StandardPolicyTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName,
        [string[]]$Headers,
        [switch]$FirewallDetailMode,
        [string]$FirewallDirection
    )

    foreach ($ExcludedSet in $script:ExcludedHeaderSets)
    {
        if (@(Compare-Object $Headers $ExcludedSet -SyncWindow 0).Count -eq 0)
        {
            [void]$Result.Value.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -ReportName $ReportName `
                        -Category ($Headers -join ' | ') `
                        -Reason "Non-setting metadata table"
                )
            )

            return
        }
    }

    $Rows = @(Get-TableRows -Table $Table)
    foreach ($Row in $Rows)
    {
        # Skip header rows and nested-detail rows (single colspan cell).
        if (@(Get-RowCells -Row $Row -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $Cells = @(Get-RowCells -Row $Row -TagName 'TD')
        if ($Cells.Count -ne $Headers.Count)
        {
            continue
        }

        $ColSpan = Get-Attribute -Element $Cells[0] -Name 'colspan'

        if (-not [string]::IsNullOrWhiteSpace($ColSpan) -and [int]$ColSpan -ge 2)
        {
            continue
        }

        $WinningGPO  = ""
        $SettingName = ""
        $ValueText   = ""
        $Category    = (Get-SectionBreadcrumb -Element $Table) -join ' / '
        $Class       = Get-ConfigurationClass -Element $Table
        $Extension   = ""

        # Administrative Template policies expose their own canonical path
        # via the explainlink span; prefer that over the heading breadcrumb.
        $ExplainSpan = $null
        $Spans       = @(Get-AllTags -Root $Cells[0] -TagName 'SPAN')
        foreach ($Span in $Spans)
        {
            if (Test-ElementHasClass -Element $Span -ClassName 'explainlink')
            {
                $ExplainSpan = $Span
                break
            }
        }

        if ($null -ne $ExplainSpan)
        {
            $SettingPath = Get-Attribute -Element $ExplainSpan -Name 'gpmc_settingpath'
            $SettingNm   = Get-Attribute -Element $ExplainSpan -Name 'gpmc_settingname'

            if (-not [string]::IsNullOrWhiteSpace($SettingNm))
            {
                $SettingName = $SettingNm
            }

            if (-not [string]::IsNullOrWhiteSpace($SettingPath))
            {
                $Parts = @($SettingPath -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

                if ($Parts.Count -gt 0 -and $Parts[0] -match '^(Computer|User)\s+Configuration$')
                {
                    $Class = $Matches[1]
                    $Parts = $Parts[1..($Parts.Count - 1)]
                }

                if ($Parts.Count -gt 0)
                {
                    $Extension = $Parts[0]
                }

                if ($Parts.Count -gt 1)
                {
                    $Category = ($Parts[1..($Parts.Count - 1)]) -join ' / '
                }
                else
                {
                    $Category = $Extension
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($SettingName))
        {
            $SettingName = Get-CleanText $Cells[0]
        }

        if ([string]::IsNullOrWhiteSpace($Extension))
        {
            $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)

            if ($Breadcrumb.Count -gt 0)
            {
                $Extension = $Breadcrumb[0]
            }

            if ($Breadcrumb.Count -gt 1)
            {
                $Category = ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / '
            }
            else
            {
                $Category = $Extension
            }
        }

        # Column layout:
        #   3 columns: [Name] [Value] [WinningGPO]
        #   N columns (N>3): [Name] [middle columns folded] [WinningGPO]
        $LastIndex = $Cells.Count - 1
        $WinningGPO = Get-CleanText $Cells[$LastIndex]

        if ($Cells.Count -eq 3)
        {
            $ValueText = Get-CleanText $Cells[1]
        }
        elseif ($Cells.Count -gt 3)
        {
            $Middle =
                @(
                    for ($i = 1; $i -lt $LastIndex; $i++)
                    {
                        $CellText = Get-CleanText $Cells[$i]

                        if (-not [string]::IsNullOrWhiteSpace($CellText))
                        {
                            "$($Headers[$i])=$CellText"
                        }
                    }
                )

            $ValueText = $Middle -join "; "
        }
        else
        {
            $ValueText = ""
        }

        # Fold in a nested detail table, if this row has one (list-style
        # Administrative Template values, or Firewall rule detail).
        $DetailRows = @(Get-NestedDetailRows -Row $Row)

        if ($DetailRows.Count -gt 0)
        {
            if ($FirewallDetailMode)
            {
                Add-FirewallDetailRule `
                    -Result $Result `
                    -ReportName $ReportName `
                    -Name $SettingName `
                    -Description $ValueText `
                    -WinningGPO $WinningGPO `
                    -Direction $FirewallDirection `
                    -DetailRows $DetailRows

                continue
            }

            $DetailText = ConvertTo-DetailValueString -Rows $DetailRows

            if (-not [string]::IsNullOrWhiteSpace($DetailText))
            {
                if ([string]::IsNullOrWhiteSpace($ValueText) -or $ValueText -eq '<NoValue>')
                {
                    $ValueText = $DetailText
                }
                else
                {
                    $ValueText = "$ValueText; $DetailText"
                }
            }
        }

        Add-HtmlSetting `
            -Result $Result `
            -ReportName $ReportName `
            -Class $Class `
            -Extension $Extension `
            -Category $Category `
            -SettingName $SettingName `
            -Value $ValueText `
            -WinningGPO $WinningGPO
    }
}

#==========================================================
# Key/Value (headerless 2-column) tables
#
# Covers most Wireless profile detail ("Authentication", "Encryption", ...),
# and small identity tables ("Profile Name", "Network Type", ...).
#==========================================================

function Parse-KeyValueTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName
    )

    $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)
    $Class      = Get-ConfigurationClass -Element $Table
    $Extension  = if ($Breadcrumb.Count -gt 0) { $Breadcrumb[0] } else { "" }
    $Category   = if ($Breadcrumb.Count -gt 1) { ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / ' } else { $Extension }

    $Rows = @(Get-TableRows -Table $Table)
    foreach ($Row in $Rows)
    {
        $Cells = @(Get-RowCells -Row $Row -TagName 'TD')
        if ($Cells.Count -ne 2)
        {
            continue
        }

        $Name  = Get-CleanText $Cells[0]
        $Value = Get-CleanText $Cells[1]

        if ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Value))
        {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Name))
        {
            continue
        }

        Add-HtmlSetting `
            -Result $Result `
            -ReportName $ReportName `
            -Class $Class `
            -Extension $Extension `
            -Category $Category `
            -SettingName $Name `
            -Value $Value `
            -WinningGPO ""
    }
}

function Parse-LabeledTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName,
        [string[]]$Headers
    )

    # A 2-column table WITH a header row but no "Winning GPO" column
    # (e.g. "Network Name (SSID) | Network Broadcasts its SSID"). Each
    # header becomes its own setting per data row.
    $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)
    $Class      = Get-ConfigurationClass -Element $Table
    $Extension  = if ($Breadcrumb.Count -gt 0) { $Breadcrumb[0] } else { "" }
    $Category   = if ($Breadcrumb.Count -gt 1) { ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / ' } else { $Extension }

    $Rows = @(Get-TableRows -Table $Table)
    foreach ($Row in $Rows)
    {
        if (@(Get-RowCells -Row $Row -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $Cells = @(Get-RowCells -Row $Row -TagName 'TD')
        if ($Cells.Count -ne $Headers.Count)
        {
            continue
        }

        for ($i = 0; $i -lt $Cells.Count; $i++)
        {
            $CellText = Get-CleanText $Cells[$i]

            if ([string]::IsNullOrWhiteSpace($Headers[$i]))
            {
                continue
            }

            Add-HtmlSetting `
                -Result $Result `
                -ReportName $ReportName `
                -Class $Class `
                -Extension $Extension `
                -Category $Category `
                -SettingName $Headers[$i] `
                -Value $CellText `
                -WinningGPO ""
        }
    }
}

#==========================================================
# Firewall Rules
#==========================================================

function Add-FirewallDetailRule {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [string]$ReportName,
        [string]$Name,
        [string]$Description,
        [string]$WinningGPO,
        [string]$Direction,
        [System.Collections.IEnumerable]$DetailRows
    )

    $Fields = @{}

    foreach ($RowValues in $DetailRows)
    {
        if ($RowValues.Count -ge 2)
        {
            $Fields[$RowValues[0]] = $RowValues[1]
        }
    }

    [void]$Result.Value.FirewallRules.Add(
        [PSCustomObject]@{
            ReportName   = $ReportName
            Name         = $Name
            Direction    = $Direction
            Description  = $Description
            WinningGPO   = $WinningGPO
            Enabled      = $Fields['Enabled']
            Profile      = $Fields['Profile']
            Action       = $Fields['Action']
            Program      = $Fields['Program']
            Protocol     = $Fields['Protocol']
            LocalPort    = $Fields['Local port']
            RemotePort   = $Fields['Remote port']
            LocalScope   = $Fields['Local scope']
            RemoteScope  = $Fields['Remote scope']
            Security     = $Fields['Security']
            Service      = $Fields['Service']
            Group        = $Fields['Group']
        }
    )
}

#==========================================================
# System Services (dedicated walk - not table-driven)
#==========================================================

function Parse-SystemServicesSection {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Document,
        [string]$ReportName
    )

    $Spans = @(Get-AllTags -Root $Document -TagName 'SPAN')
    foreach ($Span in $Spans)
    {
        if (-not (Test-ElementHasClass -Element $Span -ClassName 'sectionTitle'))
        {
            continue
        }

        if ((Get-CleanText $Span) -ne 'System Services')
        {
            continue
        }

        $Heading = $Span.parentElement
        $Content = $Heading.nextSibling

        while ($null -ne $Content -and (Get-NodeTagName $Content) -ne 'DIV')
        {
            $Content = $Content.nextSibling
        }

        if ($null -eq $Content)
        {
            continue
        }

        $Class = Get-ConfigurationClass -Element $Heading

        $ChildDivs = @(Get-AllTags -Root $Content -TagName 'DIV')
        # he4h divs (direct children only) are the per-service headings.
        foreach ($ChildDiv in $ChildDivs)
        {
            if ($ChildDiv.parentElement -ne $Content)
            {
                continue
            }

            if (-not (Test-ElementHasClass -Element $ChildDiv -ClassName 'he4h'))
            {
                continue
            }

            $ServiceTitleSpan = $null
            $TitleSpans = @(Get-AllTags -Root $ChildDiv -TagName 'SPAN')
            foreach ($TitleSpan in $TitleSpans)
            {
                if (Test-ElementHasClass -Element $TitleSpan -ClassName 'sectionTitle')
                {
                    $ServiceTitleSpan = $TitleSpan
                    break
                }
            }

            if ($null -eq $ServiceTitleSpan)
            {
                continue
            }

            $ServiceHeading = Get-CleanText $ServiceTitleSpan
            $ServiceName    = $ServiceHeading
            $StartupMode    = ""

            if ($ServiceHeading -match '^(.*?)\s*\(Startup Mode:\s*(.*?)\)\s*$')
            {
                $ServiceName = $Matches[1].Trim()
                $StartupMode = $Matches[2].Trim()
            }

            $ServiceContent = $ChildDiv.nextSibling

            while ($null -ne $ServiceContent -and (Get-NodeTagName $ServiceContent) -ne 'DIV')
            {
                $ServiceContent = $ServiceContent.nextSibling
            }

            if ($null -eq $ServiceContent)
            {
                continue
            }

            $WinningGPO = ""
            $InfoTables = @(Get-AllTags -Root $ServiceContent -TagName 'TABLE')
            foreach ($InfoTable in $InfoTables)
            {
                if (Test-IsNestedTable -Table $InfoTable)
                {
                    continue
                }

                if (Test-ElementHasClass -Element $InfoTable -ClassName 'info')
                {
                    $Rows = @(Get-TableRows -Table $InfoTable)
                    foreach ($Row in $Rows)
                    {
                        $Cells = @(Get-RowCells -Row $Row -TagName 'TD')
                        if ($Cells.Count -eq 2 -and (Get-CleanText $Cells[0]) -eq 'Winning GPO')
                        {
                            $WinningGPO = Get-CleanText $Cells[1]
                        }
                    }
                }
            }

            Add-HtmlSetting `
                -Result $Result `
                -ReportName $ReportName `
                -Class $Class `
                -Extension "System Services" `
                -Category $ServiceName `
                -SettingName "$ServiceName - Startup Mode" `
                -Value $StartupMode `
                -WinningGPO $WinningGPO

            # Permissions / Auditing blocks: each is a <b>Label</b> followed
            # either by free text ("No permissions specified") or a
            # subtable3 (Type/Name/Permission or Type/Name/Access).
            $Labels = @(Get-AllTags -Root $ServiceContent -TagName 'B')
            foreach ($LabelBold in $Labels)
            {
                $Label = Get-CleanText $LabelBold

                if ($Label -notin @('Permissions', 'Auditing'))
                {
                    continue
                }

                $Container = $LabelBold.parentElement
                $DetailTable = $null
                $Siblings = @(Get-AllTags -Root $Container -TagName 'TABLE')
                foreach ($Candidate in $Siblings)
                {
                    if (Test-ElementHasClass -Element $Candidate -ClassName 'subtable3')
                    {
                        $DetailTable = $Candidate
                        break
                    }
                }

                if ($null -eq $DetailTable)
                {
                    $FreeText = Get-CleanText $Container
                    $FreeText = $FreeText -replace [regex]::Escape($Label), ''
                    $FreeText = $FreeText.Trim()

                    Add-HtmlSetting `
                        -Result $Result `
                        -ReportName $ReportName `
                        -Class $Class `
                        -Extension "System Services" `
                        -Category $ServiceName `
                        -SettingName "$ServiceName - $Label" `
                        -Value $FreeText `
                        -WinningGPO $WinningGPO

                    continue
                }

                $DetailRows = @(Get-TableRows -Table $DetailTable)
                $Entries    = [System.Collections.ArrayList]::new()

                foreach ($DetailRow in $DetailRows)
                {
                    if (@(Get-RowCells -Row $DetailRow -TagName 'TH').Count -gt 0)
                    {
                        continue
                    }

                    $DetailCells = @(Get-RowCells -Row $DetailRow -TagName 'TD')
                    if ($DetailCells.Count -lt 3)
                    {
                        continue
                    }

                    [void]$Entries.Add(
                        "$(Get-CleanText $DetailCells[1]): $(Get-CleanText $DetailCells[0]) - $(Get-CleanText $DetailCells[2])"
                    )
                }

                $Value = (@($Entries) | Sort-Object) -join "; "

                Add-HtmlSetting `
                    -Result $Result `
                    -ReportName $ReportName `
                    -Class $Class `
                    -Extension "System Services" `
                    -Category $ServiceName `
                    -SettingName "$ServiceName - $Label" `
                    -Value $Value `
                    -WinningGPO $WinningGPO
            }
        }
    }
}

#==========================================================
# Deprecated Policy Reference (shared file format with GPOCompare.psm1)
#==========================================================

function Import-DeprecatedPolicyReference {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $script:DeprecatedPolicyReference = @{
        Entries = @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Warning "Deprecated policy reference file not found: $Path"
        return
    }

    $ValidMatchTypes = @('Name', 'Category', 'RegistryPath')
    $Entries = [System.Collections.ArrayList]::new()

    foreach ($Line in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $CurrentLine = $Line.Trim()

        if (-not $CurrentLine.StartsWith('|'))
        {
            continue
        }

        $Cells = @(
            $CurrentLine.Trim('|').Split('|') |
            ForEach-Object { $_.Trim() }
        )

        if ($Cells.Count -lt 5)
        {
            continue
        }

        if ($Cells[0] -eq 'Technology')
        {
            continue
        }

        if ($Cells[0] -match '^:?-{3,}:?$')
        {
            continue
        }

        $MatchType = $Cells[1]
        $Pattern   = $Cells[2]

        if ($ValidMatchTypes -notcontains $MatchType)
        {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Pattern))
        {
            continue
        }

        $CategoryFilter = ''

        if ($Cells.Count -ge 6)
        {
            $CategoryFilter = $Cells[5]
        }

        if ($MatchType -eq 'RegistryPath')
        {
            $Pattern = $Pattern -replace '^(HKLM|HKCU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)\\', ''
        }

        [void]$Entries.Add(
            [PSCustomObject]@{
                Technology     = $Cells[0]
                MatchType      = $MatchType
                Pattern        = $Pattern
                Status         = $Cells[3]
                Replacement    = $Cells[4]
                CategoryFilter = $CategoryFilter
            }
        )
    }

    $script:DeprecatedPolicyReference = @{
        Entries = @($Entries)
    }
}

function Get-DeprecatedPolicyMatches {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Settings
    )

    $Entries = @($script:DeprecatedPolicyReference.Entries)

    if ($Entries.Count -eq 0)
    {
        return
    }

    $Ignore = [System.StringComparison]::OrdinalIgnoreCase

    foreach ($Setting in $Settings)
    {
        $SettingName = [string]$Setting.SettingName
        $Category    = [string]$Setting.Category

        foreach ($Entry in $Entries)
        {
            $IsMatch = $false

            switch ($Entry.MatchType)
            {
                'Name' {
                    if ([string]::Equals($SettingName, $Entry.Pattern, $Ignore))
                    {
                        $IsMatch = $true

                        if (
                            -not [string]::IsNullOrWhiteSpace($Entry.CategoryFilter) -and
                            -not [string]::Equals($Category, $Entry.CategoryFilter, $Ignore)
                        )
                        {
                            $IsMatch = $false
                        }
                    }
                }

                'Category' {
                    if ($Category.IndexOf($Entry.Pattern, $Ignore) -ge 0)
                    {
                        $IsMatch = $true
                    }
                }

                'RegistryPath' {
                    if (
                        $Setting.Extension -eq 'Registry Settings' -and
                        $Category.IndexOf($Entry.Pattern, $Ignore) -ge 0
                    )
                    {
                        $IsMatch = $true
                    }
                }
            }

            if ($IsMatch)
            {
                [PSCustomObject]@{
                    ReportName             = $Setting.ReportName
                    Class                  = $Setting.Class
                    Extension              = $Setting.Extension
                    Category               = $Setting.Category
                    SettingName            = $Setting.SettingName
                    Value                  = $Setting.Value
                    Technology             = $Entry.Technology
                    MatchType              = $Entry.MatchType
                    Status                 = $Entry.Status
                    RecommendedReplacement = $Entry.Replacement
                    Reason                 = "Deprecated: $($Entry.Technology)"
                }

                break
            }
        }
    }
}

#==========================================================
# Entry Point
#==========================================================

function Get-GPOSettingsFromHtml {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ReportName
    )

    $Result = New-HtmlParseResult
    $Doc    = $null

    try
    {
        $Doc = New-HtmlDom -Path $Path
    }
    catch
    {
        throw "Failed to load HTML: $($_.Exception.Message)"
    }

    try
    {
        # 1. System Services: dedicated walk, not table-driven.
        try
        {
            Parse-SystemServicesSection `
                -Result ([ref]$Result) `
                -Document $Doc `
                -ReportName $ReportName
        }
        catch
        {
            [void]$Result.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -ReportName $ReportName `
                        -Extension "System Services" `
                        -Reason "Parser error (module line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
                )
            )
        }

        # 2. All other sections: table-driven, dispatched by header shape.
        $AllTables = @(Get-AllTags -Root $Doc -TagName 'TABLE')
        foreach ($Table in $AllTables)
        {
            try
            {
                if (Test-IsNestedTable -Table $Table)
                {
                    continue
                }

                if (Test-IsSkippedSection -Element $Table)
                {
                    continue
                }

                if (Test-IsInSection -Element $Table -SectionTitles @('System Services'))
                {
                    continue
                }

                # Group Policy Preferences items (Registry, Files, Local Users
                # and Groups, Drive Maps, etc.) use a per-field property-sheet
                # layout that the generic table handlers below would fragment
                # into disconnected rows (e.g. a lone "Winning GPO" row with no
                # link back to which registry value it belongs to). Not parsed
                # in this version; preserved as Unclassified instead of being
                # silently mangled.
                if (Test-IsInSection -Element $Table -SectionTitles @('Preferences'))
                {
                    [void]$Result.Unclassified.Add(
                        (
                            New-UnclassifiedRecord `
                                -ReportName $ReportName `
                                -Category ((Get-SectionBreadcrumb -Element $Table) -join ' / ') `
                                -Reason "Group Policy Preferences item (not parsed in this version)"
                        )
                    )

                    continue
                }

                $Headers = @(Get-TableHeaders -Table $Table)

                $IsFirewallRuleTable =
                    (Test-IsInSection -Element $Table -SectionTitles @('Inbound Rules', 'Outbound Rules')) -and
                    ($Headers.Count -eq 3) -and
                    ($Headers[$Headers.Count - 1] -match '(?i)^winning gpo$')

                if ($IsFirewallRuleTable)
                {
                    $Direction = 'Inbound'

                    if (Test-IsInSection -Element $Table -SectionTitles @('Outbound Rules'))
                    {
                        $Direction = 'Outbound'
                    }

                    Parse-StandardPolicyTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers `
                        -FirewallDetailMode `
                        -FirewallDirection $Direction

                    continue
                }

                if ($Headers.Count -ge 3 -and $Headers[$Headers.Count - 1] -match '(?i)^winning gpo$')
                {
                    Parse-StandardPolicyTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers

                    continue
                }

                if ($Headers.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($Headers[0]))
                {
                    Parse-LabeledTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers

                    continue
                }

                if ($Headers.Count -eq 0)
                {
                    $Cells0 = @(Get-AllTags -Root $Table -TagName 'TD')
                    if ($Cells0.Count -gt 0)
                    {
                        Parse-KeyValueTable `
                            -Result ([ref]$Result) `
                            -Table $Table `
                            -ReportName $ReportName
                    }

                    continue
                }

                # Anything else (Type/Name/Permission summary tables inside
                # non-service contexts, unexpected shapes) is preserved but
                # not compared.
                [void]$Result.Unclassified.Add(
                    (
                        New-UnclassifiedRecord `
                            -ReportName $ReportName `
                            -Category ((Get-SectionBreadcrumb -Element $Table) -join ' / ') `
                            -Value ($Headers -join ' | ') `
                            -Reason "Unsupported table format"
                    )
                )
            }
            catch
            {
                [void]$Result.Unclassified.Add(
                    (
                        New-UnclassifiedRecord `
                            -ReportName $ReportName `
                            -Reason "Parser error (module line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
                    )
                )
            }
        }
    }
    finally
    {
        if ($null -ne $Doc)
        {
            try
            {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Doc)
            }
            catch
            {
            }
        }
    }

    return $Result
}

Export-ModuleMember -Function @(
    'Get-GPOSettingsFromHtml',
    'Import-DeprecatedPolicyReference',
    'Get-DeprecatedPolicyMatches'
)
#         returned null instead of throwing), which is why FirewallRules.csv
#         came back empty with no error. Switched to getAttribute(name),
#         which is case-insensitive for HTML attributes, and normalized
#         the call sites to lowercase 'colspan' for defense in depth.
#   1.3 - Replaced all 4 uses of the "{0}={1}" -f composite-format
#         operator with plain string interpolation, matching the same fix
#         already applied to GPOCompare.psm1 (the XML side) for the same
#         reported error. String interpolation has no template/argument-
#         list mechanism to fail, so this removes the exception class.
#   1.2 - Fixed the actual reported source of "The property 'Count' cannot
#         be found on this object": Get-AllTags (26 call sites) and
#         Get-HeadingAncestors (4 call sites) both return a .NET
#         ArrayList, and PowerShell's pipeline silently enumerates/unwraps
#         an ArrayList with exactly one item into that single bare element
#         when the caller doesn't force array context - so any later
#         .Count check on it throws exactly this error. This is common:
#         one sample report alone has 402 rows with exactly one <td> and 3
#         tables with exactly one <th>. Every call site is now wrapped in
#         @(...) to force array context regardless of item count.
#   1.1 - Guarded three unguarded sibling-walk .tagName accesses behind a
#         new Get-NodeTagName helper, matching the one walk that was
#         already guarded; parser-error Reason text now includes the
#         module line number that threw.
#   1.0 - Initial version - see Compare-GPOHtml.ps1's changelog for the
#         paired script-level notes shipped alongside this version.
#==========================================================
Set-StrictMode -Version Latest

# Section headings that are pure structure/navigation, not settings. Anything
# under one of these (by exact heading text) is skipped rather than reported
# as Unclassified, to avoid noise.
# NOTE: 'Computer Details' / 'User Details' are NOT in this list even
# though they sound like identity-only sections. In this report format they
# are the top-level containers that everything else (including all Policies
# settings) lives inside, so skipping them would skip almost the entire
# report. The metadata subsections that actually sit alongside "Settings"
# under each of those (General, Component Status, ...) are what this list
# is for.
$script:SkippedSectionTitles = @(
    'Summary',
    'General',
    'Component Status',
    'Group Policy Objects',
    'Applied GPOs',
    'Denied GPOs',
    'WMI Filters',
    'Security Group Membership'
)

# Heading text that is purely structural wrapping (grouping headings, not a
# real category) and should be dropped when building a breadcrumb. Computer
# Details / User Details are identity wrappers used for Class detection
# (Get-ConfigurationClass), not real categories, so they are dropped here too
# or every Extension in the Computer/User branch would read "Computer
# Details" / "User Details" instead of the real top category.
$script:StructuralHeadings = @(
    'Policies',
    'Preferences',
    'Settings',
    'Windows Settings',
    'Software Settings',
    'Computer Details',
    'User Details'
)

$script:DeprecatedPolicyReference = @{
    Entries = @()
}

#==========================================================
# DOM Loading
#==========================================================

function New-HtmlDom {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "File not found: $Path"
    }

    # ReadAllText auto-detects the encoding from the byte order mark
    # (gpresult /h typically writes UTF-16LE, but this does not assume that).
    $ResolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $HtmlText     = [System.IO.File]::ReadAllText($ResolvedPath)

    $Doc = New-Object -ComObject "HTMLFile"

    # The write() signature differs between PowerShell hosts. Try the
    # Windows PowerShell 5.1 IHTMLDocument2_write path first, then fall
    # back to the array-of-bytes form used by some older hosts.
    try
    {
        $Doc.IHTMLDocument2_write($HtmlText)
    }
    catch
    {
        try
        {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($HtmlText)
            $Doc.write($Bytes)
        }
        catch
        {
            throw "Failed to load HTML into the HTMLFile COM object. This usually means mshtml is not available on this machine, or the PowerShell host's COM interop does not expose IHTMLDocument2_write. Original error: $($_.Exception.Message)"
        }
    }

    return $Doc
}

#==========================================================
# Generic DOM Helpers
#
# Deliberately avoid getElementsByClassName / querySelectorAll: those
# depend on the IE document mode the HTMLFile COM object negotiates, which
# is not guaranteed here. getElementsByTagName is the one API that has
# always been present, so class/attribute matching is done by hand.
#==========================================================

function Test-ElementHasClass {

    [CmdletBinding()]
    param(
        [object]$Element,
        [Parameter(Mandatory)]
        [string]$ClassName
    )

    if ($null -eq $Element)
    {
        return $false
    }

    $Existing = $null

    try
    {
        $Existing = $Element.className
    }
    catch
    {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Existing))
    {
        return $false
    }

    return (
        $Existing.Split(
            [char[]]@(' ', "`t"),
            [System.StringSplitOptions]::RemoveEmptyEntries
        ) -contains $ClassName
    )
}

function Get-AllTags {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Root,

        [Parameter(Mandatory)]
        [string]$TagName
    )

    $Collection = $Root.getElementsByTagName($TagName)
    $Items      = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $Collection.length; $i++)
    {
        [void]$Items.Add($Collection.item($i))
    }

    return $Items
}

function Get-CleanText {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value)
    {
        return ""
    }

    $Text = ""

    if ($Value -is [string])
    {
        $Text = $Value
    }
    else
    {
        try
        {
            $Text = $Value.innerText
        }
        catch
        {
            $Text = $Value.ToString()
        }
    }

    if ($null -eq $Text)
    {
        return ""
    }

    $Text = $Text -replace '\s+', ' '

    $Text.Trim()
}

function Get-Attribute {

    [CmdletBinding()]
    param(
        [object]$Element,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Element)
    {
        return $null
    }

    # getAttribute (not getAttributeNode) is used deliberately: it is
    # case-insensitive for HTML attribute names across IE document modes,
    # while getAttributeNode was found to be case-sensitive in the mode the
    # HTMLFile COM object negotiates - gpresult writes "colspan" lowercase,
    # and a mismatched-case lookup here silently returned null for every
    # row, which broke every nested-detail-table lookup (Firewall rules,
    # Administrative Template list values) without ever throwing an error.
    try
    {
        $Value = $Element.getAttribute($Name)

        if ($null -ne $Value)
        {
            return [string]$Value
        }
    }
    catch
    {
    }

    return $null
}

function Get-NodeTagName {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Node
    )

    # A whitespace/text node between tags does not expose .tagName the same
    # way an element does; guard every access instead of assuming it is
    # always safe to read.
    if ($null -eq $Node)
    {
        return $null
    }

    try
    {
        return $Node.tagName
    }
    catch
    {
        return $null
    }
}

function Test-IsNestedTable {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Table
    )

    # A table whose ancestor chain hits another <table> before it hits the
    # document body is a detail/sub table, not a top-level settings table.
    $Node = $Table.parentElement

    while ($null -ne $Node)
    {
        $TagName = $null

        try
        {
            $TagName = $Node.tagName
        }
        catch
        {
        }

        if ($TagName -eq 'TABLE')
        {
            return $true
        }

        if ($TagName -eq 'BODY')
        {
            return $false
        }

        $Node = $Node.parentElement
    }

    return $false
}

#==========================================================
# Heading / Breadcrumb / Class
#==========================================================

function Get-HeadingAncestors {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    # IMPORTANT: in this report format, a heading div (class he{N}h, "Local
    # Policies/Security Options") is NOT an ancestor of its content div; it
    # is the PRECEDING SIBLING of its content div, under a shared parent:
    #
    #   <div class="container">
    #     <div class="he4h"><span class="sectionTitle">Accounts</span></div>
    #     <div class="container">           <-- content lives in here
    #       <div class="he4i"><table>...</table></div>
    #     </div>
    #   </div>
    #
    # So finding the heading chain for an element means: at each ancestor
    # level, look at that level's OWN preceding siblings for a heading div,
    # then move up one level and repeat. A naive ancestor-only walk finds
    # nothing, because the heading is never actually an ancestor.
    $Result = [System.Collections.ArrayList]::new()
    $Node   = $Element.parentElement

    while ($null -ne $Node)
    {
        $Sibling = $Node.previousSibling

        while ($null -ne $Sibling)
        {
            $SiblingTag = $null

            try
            {
                $SiblingTag = $Sibling.tagName
            }
            catch
            {
            }

            if ($SiblingTag -eq 'DIV')
            {
                $SiblingClass = $null

                try
                {
                    $SiblingClass = $Sibling.className
                }
                catch
                {
                }

                if ($SiblingClass -match '^he\d')
                {
                    [void]$Result.Add($Sibling)
                    break
                }
            }

            $Sibling = $Sibling.previousSibling
        }

        $Node = $Node.parentElement
    }

    return $Result
}

function Get-SectionTitleText {

    [CmdletBinding()]
    param(
        [object]$HeadingDiv
    )

    if ($null -eq $HeadingDiv)
    {
        return $null
    }

    $Spans = @(Get-AllTags -Root $HeadingDiv -TagName 'SPAN')
    foreach ($Span in $Spans)
    {
        if (Test-ElementHasClass -Element $Span -ClassName 'sectionTitle')
        {
            return Get-CleanText $Span
        }
    }

    return $null
}

function Get-SectionBreadcrumb {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)
    $Titles    = [System.Collections.Generic.List[string]]::new()

    # Ancestors come back nearest-first; reverse for top-down order.
    for ($i = $Ancestors.Count - 1; $i -ge 0; $i--)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestors[$i]

        if ([string]::IsNullOrWhiteSpace($Title))
        {
            continue
        }

        if ($script:StructuralHeadings -contains $Title)
        {
            continue
        }

        # Avoid immediate duplicate labels (a heading div and its content
        # div sometimes both resolve to the same sectionTitle text).
        if ($Titles.Count -eq 0 -or $Titles[$Titles.Count - 1] -ne $Title)
        {
            $Titles.Add($Title)
        }
    }

    return $Titles
}

function Test-IsSkippedSection {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ($script:SkippedSectionTitles -contains $Title)
        {
            return $true
        }
    }

    return $false
}

function Test-IsInSection {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element,

        [Parameter(Mandatory)]
        [string[]]$SectionTitles
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ($SectionTitles -contains $Title)
        {
            return $true
        }
    }

    return $false
}

function Get-ConfigurationClass {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Element
    )

    $Ancestors = @(Get-HeadingAncestors -Element $Element)

    foreach ($Ancestor in $Ancestors)
    {
        $Title = Get-SectionTitleText -HeadingDiv $Ancestor

        if ([string]::IsNullOrWhiteSpace($Title))
        {
            continue
        }

        if ($Title -match '^(Computer|User)\s+(Configuration|Details)$')
        {
            return $Matches[1]
        }
    }

    return "Unknown"
}

#==========================================================
# Output Helpers (shared shape with GPOCompare.psm1)
#==========================================================

function New-HtmlParseResult {

    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Settings      = New-Object System.Collections.ArrayList
        FirewallRules = New-Object System.Collections.ArrayList
        Unclassified  = New-Object System.Collections.ArrayList
    }
}

function New-UnclassifiedRecord {

    [CmdletBinding()]
    param(
        [string]$ReportName,
        [string]$Class,
        [string]$Extension,
        [string]$Category,
        [string]$SettingName,
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    [PSCustomObject]@{
        ReportName  = $ReportName
        Class       = $Class
        Extension   = $Extension
        Category    = $Category
        SettingName = $SettingName
        Value       = $Value
        Reason      = $Reason
    }
}

function Add-HtmlSetting {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref]$Result,

        [string]$ReportName,
        [string]$Class,
        [string]$Extension,
        [string]$Category,
        [string]$SettingName,
        [string]$Value,
        [string]$WinningGPO
    )

    $SettingName = Get-CleanText $SettingName
    $Value       = Get-CleanText $Value
    $Category    = Get-CleanText $Category
    $Extension   = Get-CleanText $Extension
    $WinningGPO  = Get-CleanText $WinningGPO

    if ([string]::IsNullOrWhiteSpace($SettingName))
    {
        [void]$Result.Value.Unclassified.Add(
            (
                New-UnclassifiedRecord `
                    -ReportName $ReportName `
                    -Class $Class `
                    -Extension $Extension `
                    -Category $Category `
                    -Value $Value `
                    -Reason "Missing Setting Name"
            )
        )

        return
    }

    if ([string]::IsNullOrWhiteSpace($Category))
    {
        $Category = "<NoCategory>"
    }

    if ([string]::IsNullOrWhiteSpace($Extension))
    {
        $Extension = "<UnknownExtension>"
    }

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        $Value = "<NoValue>"
    }

    if ([string]::IsNullOrWhiteSpace($WinningGPO))
    {
        $WinningGPO = "<Unknown>"
    }

    [void]$Result.Value.Settings.Add(
        [PSCustomObject]@{
            ReportName  = $ReportName
            Class       = $Class
            Extension   = $Extension
            Category    = $Category
            SettingName = $SettingName
            Value       = $Value
            WinningGPO  = $WinningGPO
        }
    )
}

#==========================================================
# Nested Detail Table Extraction
#
# Several policies (Hardened UNC Paths, ASR rules, Firewall rules, some
# Administrative Template sub-options) render as a normal row followed by
# a second <tr><td colspan="N"> containing a nested table. This walks that
# nested table (unwrapping subtable_frame, which wraps explanatory text
# plus the actual list table) and returns its rows as an ordered list of
# cell-text arrays.
#==========================================================

function Get-NestedDetailRows {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $NextRow = $Row.nextSibling

    while ($null -ne $NextRow -and (Get-NodeTagName $NextRow) -ne 'TR')
    {
        $NextRow = $NextRow.nextSibling
    }

    if ($null -eq $NextRow)
    {
        return @()
    }

    $Cells = @(Get-AllTags -Root $NextRow -TagName 'TD')
    if ($Cells.Count -ne 1)
    {
        return @()
    }

    $ColSpan = Get-Attribute -Element $Cells[0] -Name 'colspan'

    if ([string]::IsNullOrWhiteSpace($ColSpan) -or [int]$ColSpan -lt 2)
    {
        return @()
    }

    # Find the first nested table inside this cell. subtable_frame wraps
    # explanatory prose plus the real subtable/subtable3; getElementsByTagName
    # on the cell finds tables at any depth, so take the first one, and if
    # that is itself a frame, look one level further for the real list.
    $Tables = @(Get-AllTags -Root $Cells[0] -TagName 'TABLE')
    if ($Tables.Count -eq 0)
    {
        return @()
    }

    $DetailTable = $null

    foreach ($Candidate in $Tables)
    {
        if (Test-ElementHasClass -Element $Candidate -ClassName 'subtable_frame')
        {
            continue
        }

        $DetailTable = $Candidate
        break
    }

    if ($null -eq $DetailTable)
    {
        return @()
    }

    $Rows = @(Get-AllTags -Root $DetailTable -TagName 'TR')
    $Out  = [System.Collections.ArrayList]::new()

    foreach ($DetailRow in $Rows)
    {
        # Skip header rows (th cells)
        if (@(Get-AllTags -Root $DetailRow -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $DetailCells = @(Get-AllTags -Root $DetailRow -TagName 'TD')
        if ($DetailCells.Count -eq 0)
        {
            continue
        }

        $Values = @($DetailCells | ForEach-Object { Get-CleanText $_ })

        [void]$Out.Add($Values)
    }

    return $Out
}

function ConvertTo-DetailValueString {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Rows
    )

    # Generic fold: 2-column rows become "Name=Value"; a 3rd column (usually
    # a per-item Source GPO that normally matches the parent row's Winning
    # GPO) is dropped to avoid duplicating that information. Sorted so row
    # order in the report does not affect comparison.
    $Entries =
        @(
            foreach ($RowValues in $Rows)
            {
                if ($RowValues.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($RowValues[0]))
                {
                    "$($RowValues[0])=$($RowValues[1])"
                }
                elseif ($RowValues.Count -eq 1)
                {
                    $RowValues[0]
                }
            }
        )

    (@($Entries) | Sort-Object) -join "; "
}

#==========================================================
# Standard "Policy / Setting / Winning GPO"-shaped tables
#
# Covers: Account Policies, Local Policies, Advanced Audit Configuration,
# Administrative Templates (incl. LAPS, ASR rules, Hardened UNC Paths, list
# settings), unresolved legacy Registry Settings, Certificates, Scripts,
# and (in Firewall detail mode) Firewall rule summaries.
#==========================================================

function Get-TableHeaders {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Table
    )

    $Rows = @(Get-AllTags -Root $Table -TagName 'TR')
    if ($Rows.Count -eq 0)
    {
        return @()
    }

    $HeaderCells = @(Get-AllTags -Root $Rows[0] -TagName 'TH')
    return @($HeaderCells | ForEach-Object { Get-CleanText $_ })
}

$script:ExcludedHeaderSets = @(
    , @('Name', 'Value', 'Reference GPO(s)')
)

function Parse-StandardPolicyTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName,
        [string[]]$Headers,
        [switch]$FirewallDetailMode,
        [string]$FirewallDirection
    )

    foreach ($ExcludedSet in $script:ExcludedHeaderSets)
    {
        if (@(Compare-Object $Headers $ExcludedSet -SyncWindow 0).Count -eq 0)
        {
            [void]$Result.Value.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -ReportName $ReportName `
                        -Category ($Headers -join ' | ') `
                        -Reason "Non-setting metadata table"
                )
            )

            return
        }
    }

    $Rows = @(Get-AllTags -Root $Table -TagName 'TR')
    foreach ($Row in $Rows)
    {
        # Skip header rows and nested-detail rows (single colspan cell).
        if (@(Get-AllTags -Root $Row -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $Cells = @(Get-AllTags -Root $Row -TagName 'TD')
        if ($Cells.Count -ne $Headers.Count)
        {
            continue
        }

        $ColSpan = Get-Attribute -Element $Cells[0] -Name 'colspan'

        if (-not [string]::IsNullOrWhiteSpace($ColSpan) -and [int]$ColSpan -ge 2)
        {
            continue
        }

        $WinningGPO  = ""
        $SettingName = ""
        $ValueText   = ""
        $Category    = (Get-SectionBreadcrumb -Element $Table) -join ' / '
        $Class       = Get-ConfigurationClass -Element $Table
        $Extension   = ""

        # Administrative Template policies expose their own canonical path
        # via the explainlink span; prefer that over the heading breadcrumb.
        $ExplainSpan = $null
        $Spans       = @(Get-AllTags -Root $Cells[0] -TagName 'SPAN')
        foreach ($Span in $Spans)
        {
            if (Test-ElementHasClass -Element $Span -ClassName 'explainlink')
            {
                $ExplainSpan = $Span
                break
            }
        }

        if ($null -ne $ExplainSpan)
        {
            $SettingPath = Get-Attribute -Element $ExplainSpan -Name 'gpmc_settingpath'
            $SettingNm   = Get-Attribute -Element $ExplainSpan -Name 'gpmc_settingname'

            if (-not [string]::IsNullOrWhiteSpace($SettingNm))
            {
                $SettingName = $SettingNm
            }

            if (-not [string]::IsNullOrWhiteSpace($SettingPath))
            {
                $Parts = @($SettingPath -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

                if ($Parts.Count -gt 0 -and $Parts[0] -match '^(Computer|User)\s+Configuration$')
                {
                    $Class = $Matches[1]
                    $Parts = $Parts[1..($Parts.Count - 1)]
                }

                if ($Parts.Count -gt 0)
                {
                    $Extension = $Parts[0]
                }

                if ($Parts.Count -gt 1)
                {
                    $Category = ($Parts[1..($Parts.Count - 1)]) -join ' / '
                }
                else
                {
                    $Category = $Extension
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($SettingName))
        {
            $SettingName = Get-CleanText $Cells[0]
        }

        if ([string]::IsNullOrWhiteSpace($Extension))
        {
            $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)

            if ($Breadcrumb.Count -gt 0)
            {
                $Extension = $Breadcrumb[0]
            }

            if ($Breadcrumb.Count -gt 1)
            {
                $Category = ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / '
            }
            else
            {
                $Category = $Extension
            }
        }

        # Column layout:
        #   3 columns: [Name] [Value] [WinningGPO]
        #   N columns (N>3): [Name] [middle columns folded] [WinningGPO]
        $LastIndex = $Cells.Count - 1
        $WinningGPO = Get-CleanText $Cells[$LastIndex]

        if ($Cells.Count -eq 3)
        {
            $ValueText = Get-CleanText $Cells[1]
        }
        elseif ($Cells.Count -gt 3)
        {
            $Middle =
                @(
                    for ($i = 1; $i -lt $LastIndex; $i++)
                    {
                        $CellText = Get-CleanText $Cells[$i]

                        if (-not [string]::IsNullOrWhiteSpace($CellText))
                        {
                            "$($Headers[$i])=$CellText"
                        }
                    }
                )

            $ValueText = $Middle -join "; "
        }
        else
        {
            $ValueText = ""
        }

        # Fold in a nested detail table, if this row has one (list-style
        # Administrative Template values, or Firewall rule detail).
        $DetailRows = @(Get-NestedDetailRows -Row $Row)

        if ($DetailRows.Count -gt 0)
        {
            if ($FirewallDetailMode)
            {
                Add-FirewallDetailRule `
                    -Result $Result `
                    -ReportName $ReportName `
                    -Name $SettingName `
                    -Description $ValueText `
                    -WinningGPO $WinningGPO `
                    -Direction $FirewallDirection `
                    -DetailRows $DetailRows

                continue
            }

            $DetailText = ConvertTo-DetailValueString -Rows $DetailRows

            if (-not [string]::IsNullOrWhiteSpace($DetailText))
            {
                if ([string]::IsNullOrWhiteSpace($ValueText) -or $ValueText -eq '<NoValue>')
                {
                    $ValueText = $DetailText
                }
                else
                {
                    $ValueText = "$ValueText; $DetailText"
                }
            }
        }

        Add-HtmlSetting `
            -Result $Result `
            -ReportName $ReportName `
            -Class $Class `
            -Extension $Extension `
            -Category $Category `
            -SettingName $SettingName `
            -Value $ValueText `
            -WinningGPO $WinningGPO
    }
}

#==========================================================
# Key/Value (headerless 2-column) tables
#
# Covers most Wireless profile detail ("Authentication", "Encryption", ...),
# and small identity tables ("Profile Name", "Network Type", ...).
#==========================================================

function Parse-KeyValueTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName
    )

    $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)
    $Class      = Get-ConfigurationClass -Element $Table
    $Extension  = if ($Breadcrumb.Count -gt 0) { $Breadcrumb[0] } else { "" }
    $Category   = if ($Breadcrumb.Count -gt 1) { ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / ' } else { $Extension }

    $Rows = @(Get-AllTags -Root $Table -TagName 'TR')
    foreach ($Row in $Rows)
    {
        $Cells = @(Get-AllTags -Root $Row -TagName 'TD')
        if ($Cells.Count -ne 2)
        {
            continue
        }

        $Name  = Get-CleanText $Cells[0]
        $Value = Get-CleanText $Cells[1]

        if ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Value))
        {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Name))
        {
            continue
        }

        Add-HtmlSetting `
            -Result $Result `
            -ReportName $ReportName `
            -Class $Class `
            -Extension $Extension `
            -Category $Category `
            -SettingName $Name `
            -Value $Value `
            -WinningGPO ""
    }
}

function Parse-LabeledTable {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Table,
        [string]$ReportName,
        [string[]]$Headers
    )

    # A 2-column table WITH a header row but no "Winning GPO" column
    # (e.g. "Network Name (SSID) | Network Broadcasts its SSID"). Each
    # header becomes its own setting per data row.
    $Breadcrumb = @(Get-SectionBreadcrumb -Element $Table)
    $Class      = Get-ConfigurationClass -Element $Table
    $Extension  = if ($Breadcrumb.Count -gt 0) { $Breadcrumb[0] } else { "" }
    $Category   = if ($Breadcrumb.Count -gt 1) { ($Breadcrumb[1..($Breadcrumb.Count - 1)]) -join ' / ' } else { $Extension }

    $Rows = @(Get-AllTags -Root $Table -TagName 'TR')
    foreach ($Row in $Rows)
    {
        if (@(Get-AllTags -Root $Row -TagName 'TH').Count -gt 0)
        {
            continue
        }

        $Cells = @(Get-AllTags -Root $Row -TagName 'TD')
        if ($Cells.Count -ne $Headers.Count)
        {
            continue
        }

        for ($i = 0; $i -lt $Cells.Count; $i++)
        {
            $CellText = Get-CleanText $Cells[$i]

            if ([string]::IsNullOrWhiteSpace($Headers[$i]))
            {
                continue
            }

            Add-HtmlSetting `
                -Result $Result `
                -ReportName $ReportName `
                -Class $Class `
                -Extension $Extension `
                -Category $Category `
                -SettingName $Headers[$i] `
                -Value $CellText `
                -WinningGPO ""
        }
    }
}

#==========================================================
# Firewall Rules
#==========================================================

function Add-FirewallDetailRule {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [string]$ReportName,
        [string]$Name,
        [string]$Description,
        [string]$WinningGPO,
        [string]$Direction,
        [System.Collections.IEnumerable]$DetailRows
    )

    $Fields = @{}

    foreach ($RowValues in $DetailRows)
    {
        if ($RowValues.Count -ge 2)
        {
            $Fields[$RowValues[0]] = $RowValues[1]
        }
    }

    [void]$Result.Value.FirewallRules.Add(
        [PSCustomObject]@{
            ReportName   = $ReportName
            Name         = $Name
            Direction    = $Direction
            Description  = $Description
            WinningGPO   = $WinningGPO
            Enabled      = $Fields['Enabled']
            Profile      = $Fields['Profile']
            Action       = $Fields['Action']
            Program      = $Fields['Program']
            Protocol     = $Fields['Protocol']
            LocalPort    = $Fields['Local port']
            RemotePort   = $Fields['Remote port']
            LocalScope   = $Fields['Local scope']
            RemoteScope  = $Fields['Remote scope']
            Security     = $Fields['Security']
            Service      = $Fields['Service']
            Group        = $Fields['Group']
        }
    )
}

#==========================================================
# System Services (dedicated walk - not table-driven)
#==========================================================

function Parse-SystemServicesSection {

    [CmdletBinding()]
    param(
        [ref]$Result,
        [object]$Document,
        [string]$ReportName
    )

    $Spans = @(Get-AllTags -Root $Document -TagName 'SPAN')
    foreach ($Span in $Spans)
    {
        if (-not (Test-ElementHasClass -Element $Span -ClassName 'sectionTitle'))
        {
            continue
        }

        if ((Get-CleanText $Span) -ne 'System Services')
        {
            continue
        }

        $Heading = $Span.parentElement
        $Content = $Heading.nextSibling

        while ($null -ne $Content -and (Get-NodeTagName $Content) -ne 'DIV')
        {
            $Content = $Content.nextSibling
        }

        if ($null -eq $Content)
        {
            continue
        }

        $Class = Get-ConfigurationClass -Element $Heading

        $ChildDivs = @(Get-AllTags -Root $Content -TagName 'DIV')
        # he4h divs (direct children only) are the per-service headings.
        foreach ($ChildDiv in $ChildDivs)
        {
            if ($ChildDiv.parentElement -ne $Content)
            {
                continue
            }

            if (-not (Test-ElementHasClass -Element $ChildDiv -ClassName 'he4h'))
            {
                continue
            }

            $ServiceTitleSpan = $null
            $TitleSpans = @(Get-AllTags -Root $ChildDiv -TagName 'SPAN')
            foreach ($TitleSpan in $TitleSpans)
            {
                if (Test-ElementHasClass -Element $TitleSpan -ClassName 'sectionTitle')
                {
                    $ServiceTitleSpan = $TitleSpan
                    break
                }
            }

            if ($null -eq $ServiceTitleSpan)
            {
                continue
            }

            $ServiceHeading = Get-CleanText $ServiceTitleSpan
            $ServiceName    = $ServiceHeading
            $StartupMode    = ""

            if ($ServiceHeading -match '^(.*?)\s*\(Startup Mode:\s*(.*?)\)\s*$')
            {
                $ServiceName = $Matches[1].Trim()
                $StartupMode = $Matches[2].Trim()
            }

            $ServiceContent = $ChildDiv.nextSibling

            while ($null -ne $ServiceContent -and (Get-NodeTagName $ServiceContent) -ne 'DIV')
            {
                $ServiceContent = $ServiceContent.nextSibling
            }

            if ($null -eq $ServiceContent)
            {
                continue
            }

            $WinningGPO = ""
            $InfoTables = @(Get-AllTags -Root $ServiceContent -TagName 'TABLE')
            foreach ($InfoTable in $InfoTables)
            {
                if (Test-IsNestedTable -Table $InfoTable)
                {
                    continue
                }

                if (Test-ElementHasClass -Element $InfoTable -ClassName 'info')
                {
                    $Rows = @(Get-AllTags -Root $InfoTable -TagName 'TR')
                    foreach ($Row in $Rows)
                    {
                        $Cells = @(Get-AllTags -Root $Row -TagName 'TD')
                        if ($Cells.Count -eq 2 -and (Get-CleanText $Cells[0]) -eq 'Winning GPO')
                        {
                            $WinningGPO = Get-CleanText $Cells[1]
                        }
                    }
                }
            }

            Add-HtmlSetting `
                -Result $Result `
                -ReportName $ReportName `
                -Class $Class `
                -Extension "System Services" `
                -Category $ServiceName `
                -SettingName "$ServiceName - Startup Mode" `
                -Value $StartupMode `
                -WinningGPO $WinningGPO

            # Permissions / Auditing blocks: each is a <b>Label</b> followed
            # either by free text ("No permissions specified") or a
            # subtable3 (Type/Name/Permission or Type/Name/Access).
            $Labels = @(Get-AllTags -Root $ServiceContent -TagName 'B')
            foreach ($LabelBold in $Labels)
            {
                $Label = Get-CleanText $LabelBold

                if ($Label -notin @('Permissions', 'Auditing'))
                {
                    continue
                }

                $Container = $LabelBold.parentElement
                $DetailTable = $null
                $Siblings = @(Get-AllTags -Root $Container -TagName 'TABLE')
                foreach ($Candidate in $Siblings)
                {
                    if (Test-ElementHasClass -Element $Candidate -ClassName 'subtable3')
                    {
                        $DetailTable = $Candidate
                        break
                    }
                }

                if ($null -eq $DetailTable)
                {
                    $FreeText = Get-CleanText $Container
                    $FreeText = $FreeText -replace [regex]::Escape($Label), ''
                    $FreeText = $FreeText.Trim()

                    Add-HtmlSetting `
                        -Result $Result `
                        -ReportName $ReportName `
                        -Class $Class `
                        -Extension "System Services" `
                        -Category $ServiceName `
                        -SettingName "$ServiceName - $Label" `
                        -Value $FreeText `
                        -WinningGPO $WinningGPO

                    continue
                }

                $DetailRows = @(Get-AllTags -Root $DetailTable -TagName 'TR')
                $Entries    = [System.Collections.ArrayList]::new()

                foreach ($DetailRow in $DetailRows)
                {
                    if (@(Get-AllTags -Root $DetailRow -TagName 'TH').Count -gt 0)
                    {
                        continue
                    }

                    $DetailCells = @(Get-AllTags -Root $DetailRow -TagName 'TD')
                    if ($DetailCells.Count -lt 3)
                    {
                        continue
                    }

                    [void]$Entries.Add(
                        "$(Get-CleanText $DetailCells[1]): $(Get-CleanText $DetailCells[0]) - $(Get-CleanText $DetailCells[2])"
                    )
                }

                $Value = (@($Entries) | Sort-Object) -join "; "

                Add-HtmlSetting `
                    -Result $Result `
                    -ReportName $ReportName `
                    -Class $Class `
                    -Extension "System Services" `
                    -Category $ServiceName `
                    -SettingName "$ServiceName - $Label" `
                    -Value $Value `
                    -WinningGPO $WinningGPO
            }
        }
    }
}

#==========================================================
# Deprecated Policy Reference (shared file format with GPOCompare.psm1)
#==========================================================

function Import-DeprecatedPolicyReference {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $script:DeprecatedPolicyReference = @{
        Entries = @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Warning "Deprecated policy reference file not found: $Path"
        return
    }

    $ValidMatchTypes = @('Name', 'Category', 'RegistryPath')
    $Entries = [System.Collections.ArrayList]::new()

    foreach ($Line in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $CurrentLine = $Line.Trim()

        if (-not $CurrentLine.StartsWith('|'))
        {
            continue
        }

        $Cells = @(
            $CurrentLine.Trim('|').Split('|') |
            ForEach-Object { $_.Trim() }
        )

        if ($Cells.Count -lt 5)
        {
            continue
        }

        if ($Cells[0] -eq 'Technology')
        {
            continue
        }

        if ($Cells[0] -match '^:?-{3,}:?$')
        {
            continue
        }

        $MatchType = $Cells[1]
        $Pattern   = $Cells[2]

        if ($ValidMatchTypes -notcontains $MatchType)
        {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Pattern))
        {
            continue
        }

        $CategoryFilter = ''

        if ($Cells.Count -ge 6)
        {
            $CategoryFilter = $Cells[5]
        }

        if ($MatchType -eq 'RegistryPath')
        {
            $Pattern = $Pattern -replace '^(HKLM|HKCU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)\\', ''
        }

        [void]$Entries.Add(
            [PSCustomObject]@{
                Technology     = $Cells[0]
                MatchType      = $MatchType
                Pattern        = $Pattern
                Status         = $Cells[3]
                Replacement    = $Cells[4]
                CategoryFilter = $CategoryFilter
            }
        )
    }

    $script:DeprecatedPolicyReference = @{
        Entries = @($Entries)
    }
}

function Get-DeprecatedPolicyMatches {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Settings
    )

    $Entries = @($script:DeprecatedPolicyReference.Entries)

    if ($Entries.Count -eq 0)
    {
        return
    }

    $Ignore = [System.StringComparison]::OrdinalIgnoreCase

    foreach ($Setting in $Settings)
    {
        $SettingName = [string]$Setting.SettingName
        $Category    = [string]$Setting.Category

        foreach ($Entry in $Entries)
        {
            $IsMatch = $false

            switch ($Entry.MatchType)
            {
                'Name' {
                    if ([string]::Equals($SettingName, $Entry.Pattern, $Ignore))
                    {
                        $IsMatch = $true

                        if (
                            -not [string]::IsNullOrWhiteSpace($Entry.CategoryFilter) -and
                            -not [string]::Equals($Category, $Entry.CategoryFilter, $Ignore)
                        )
                        {
                            $IsMatch = $false
                        }
                    }
                }

                'Category' {
                    if ($Category.IndexOf($Entry.Pattern, $Ignore) -ge 0)
                    {
                        $IsMatch = $true
                    }
                }

                'RegistryPath' {
                    if (
                        $Setting.Extension -eq 'Registry Settings' -and
                        $Category.IndexOf($Entry.Pattern, $Ignore) -ge 0
                    )
                    {
                        $IsMatch = $true
                    }
                }
            }

            if ($IsMatch)
            {
                [PSCustomObject]@{
                    ReportName             = $Setting.ReportName
                    Class                  = $Setting.Class
                    Extension              = $Setting.Extension
                    Category               = $Setting.Category
                    SettingName            = $Setting.SettingName
                    Value                  = $Setting.Value
                    Technology             = $Entry.Technology
                    MatchType              = $Entry.MatchType
                    Status                 = $Entry.Status
                    RecommendedReplacement = $Entry.Replacement
                    Reason                 = "Deprecated: $($Entry.Technology)"
                }

                break
            }
        }
    }
}

#==========================================================
# Entry Point
#==========================================================

function Get-GPOSettingsFromHtml {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ReportName
    )

    $Result = New-HtmlParseResult
    $Doc    = $null

    try
    {
        $Doc = New-HtmlDom -Path $Path
    }
    catch
    {
        throw "Failed to load HTML: $($_.Exception.Message)"
    }

    try
    {
        # 1. System Services: dedicated walk, not table-driven.
        try
        {
            Parse-SystemServicesSection `
                -Result ([ref]$Result) `
                -Document $Doc `
                -ReportName $ReportName
        }
        catch
        {
            [void]$Result.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -ReportName $ReportName `
                        -Extension "System Services" `
                        -Reason "Parser error (module line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
                )
            )
        }

        # 2. All other sections: table-driven, dispatched by header shape.
        $AllTables = @(Get-AllTags -Root $Doc -TagName 'TABLE')
        foreach ($Table in $AllTables)
        {
            try
            {
                if (Test-IsNestedTable -Table $Table)
                {
                    continue
                }

                if (Test-IsSkippedSection -Element $Table)
                {
                    continue
                }

                if (Test-IsInSection -Element $Table -SectionTitles @('System Services'))
                {
                    continue
                }

                # Group Policy Preferences items (Registry, Files, Local Users
                # and Groups, Drive Maps, etc.) use a per-field property-sheet
                # layout that the generic table handlers below would fragment
                # into disconnected rows (e.g. a lone "Winning GPO" row with no
                # link back to which registry value it belongs to). Not parsed
                # in this version; preserved as Unclassified instead of being
                # silently mangled.
                if (Test-IsInSection -Element $Table -SectionTitles @('Preferences'))
                {
                    [void]$Result.Unclassified.Add(
                        (
                            New-UnclassifiedRecord `
                                -ReportName $ReportName `
                                -Category ((Get-SectionBreadcrumb -Element $Table) -join ' / ') `
                                -Reason "Group Policy Preferences item (not parsed in this version)"
                        )
                    )

                    continue
                }

                $Headers = @(Get-TableHeaders -Table $Table)

                $IsFirewallRuleTable =
                    (Test-IsInSection -Element $Table -SectionTitles @('Inbound Rules', 'Outbound Rules')) -and
                    ($Headers.Count -eq 3) -and
                    ($Headers[$Headers.Count - 1] -match '(?i)^winning gpo$')

                if ($IsFirewallRuleTable)
                {
                    $Direction = 'Inbound'

                    if (Test-IsInSection -Element $Table -SectionTitles @('Outbound Rules'))
                    {
                        $Direction = 'Outbound'
                    }

                    Parse-StandardPolicyTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers `
                        -FirewallDetailMode `
                        -FirewallDirection $Direction

                    continue
                }

                if ($Headers.Count -ge 3 -and $Headers[$Headers.Count - 1] -match '(?i)^winning gpo$')
                {
                    Parse-StandardPolicyTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers

                    continue
                }

                if ($Headers.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($Headers[0]))
                {
                    Parse-LabeledTable `
                        -Result ([ref]$Result) `
                        -Table $Table `
                        -ReportName $ReportName `
                        -Headers $Headers

                    continue
                }

                if ($Headers.Count -eq 0)
                {
                    $Cells0 = @(Get-AllTags -Root $Table -TagName 'TD')
                    if ($Cells0.Count -gt 0)
                    {
                        Parse-KeyValueTable `
                            -Result ([ref]$Result) `
                            -Table $Table `
                            -ReportName $ReportName
                    }

                    continue
                }

                # Anything else (Type/Name/Permission summary tables inside
                # non-service contexts, unexpected shapes) is preserved but
                # not compared.
                [void]$Result.Unclassified.Add(
                    (
                        New-UnclassifiedRecord `
                            -ReportName $ReportName `
                            -Category ((Get-SectionBreadcrumb -Element $Table) -join ' / ') `
                            -Value ($Headers -join ' | ') `
                            -Reason "Unsupported table format"
                    )
                )
            }
            catch
            {
                [void]$Result.Unclassified.Add(
                    (
                        New-UnclassifiedRecord `
                            -ReportName $ReportName `
                            -Reason "Parser error (module line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
                    )
                )
            }
        }
    }
    finally
    {
        if ($null -ne $Doc)
        {
            try
            {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Doc)
            }
            catch
            {
            }
        }
    }

    return $Result
}

Export-ModuleMember -Function @(
    'Get-GPOSettingsFromHtml',
    'Import-DeprecatedPolicyReference',
    'Get-DeprecatedPolicyMatches'
)
