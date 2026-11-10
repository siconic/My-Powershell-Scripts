#Requires -Version 5.1
<#
.SYNOPSIS
Menu for the GPO Evaluation toolkit: pick an action, answer its questions,
and the matching script in the Scripts folder is run.

.DESCRIPTION
Actions:
  1  Compare GPO XML exports          Scripts\Compare-GPOXml.ps1
  2  Compare GPResult HTML reports     Scripts\Compare-GPOHtml.ps1
  3  Build an Intune policy plan       Scripts\New-IntunePolicyPlan.ps1
  4  Build a GPO consolidation plan    Scripts\New-GpoConsolidationPlan.ps1
  5  Import Intune mapping workbooks   Scripts\Import-IntuneMappingWorkbook.ps1
  6  Check the toolkit files

The launcher asks only for the inputs each script needs. The scripts ask
their own questions (output file prefix, CSV or Excel, exclusions). Press
Enter to accept a default shown in [brackets]. Paths can be typed, pasted
or dragged into the window; surrounding quotes are removed.

After an action finishes (or fails), the menu is shown again. Folders used
in this session are offered as defaults for the next action, so the output
folder of a compare run is the default input of the plans.

Every script can still be run directly with its parameters; see
README.md and each script's help (Get-Help .\Scripts\<name>.ps1 -Full).

Folders:
  Scripts   the scripts the menu runs
  Modules   PowerShell modules used by the scripts
  Data      shared reference and mapping files (deprecated policies,
            Intune mappings, exclusions)
  Config    your own configuration (GpoRoles.csv, ConsolidationRules.json,
            IntuneMappingRedactions.txt); the *.example.* files show the
            format

.EXAMPLE
.\Start-GPOToolkit.ps1

.NOTES
Author:  Siconic
Version: 1.0

Changelog:
  1.0 - Initial version.
#>

[CmdletBinding()]
param()

$ToolkitRoot = $PSScriptRoot
$ScriptsFolder = Join-Path $ToolkitRoot 'Scripts'
$ConfigFolder = Join-Path $ToolkitRoot 'Config'

# Paths used in this session, offered as defaults.
$Last = @{
    XmlFolder     = ''
    HtmlFolder    = ''
    CompareOutput = ''
    PlanOutput    = ''
    MappingInput  = ''
}

# ------------------------------------------------------------
# Input helpers
# ------------------------------------------------------------

function Read-Text
{
    # Returns the answer, or the default when Enter is pressed.
    param([string]$Prompt, [string]$Default = '')

    $Text = $Prompt

    if ($Default -ne '')
    {
        $Text = "$Prompt [$Default]"
    }

    $Answer = "$(Read-Host $Text)".Trim()

    if ($Answer -eq '')
    {
        return $Default
    }

    return $Answer
}

function Read-YesNo
{
    # Y/yes = $true, N/no = $false, Enter = the default.
    param([string]$Prompt, [bool]$Default = $false)

    $Hint = if ($Default) { 'Y/n' } else { 'y/N' }

    while ($true)
    {
        $Answer = "$(Read-Host "$Prompt ($Hint)")".Trim()

        if ($Answer -eq '') { return $Default }
        if ($Answer -match '^(?i)(y|yes)$') { return $true }
        if ($Answer -match '^(?i)(n|no)$') { return $false }

        Write-Host "Answer Y or N." -ForegroundColor Yellow
    }
}

function ConvertTo-CleanPath
{
    # Removes spaces and surrounding quotes (pasted or dragged paths).
    param([string]$Path)

    return $Path.Trim().Trim('"').Trim("'").Trim()
}

function Read-ExistingPath
{
    <#
    Asks until the answer is an existing folder or file. Type: Folder,
    File, or Any. An empty answer with no default returns '' when
    AllowEmpty is set; otherwise it asks again.
    #>
    param(
        [string]$Prompt,
        [string]$Default = '',
        [ValidateSet('Folder', 'File', 'Any')][string]$Type = 'Any',
        [switch]$AllowEmpty
    )

    while ($true)
    {
        $Answer = ConvertTo-CleanPath (Read-Text -Prompt $Prompt -Default $Default)

        if ($Answer -eq '')
        {
            if ($AllowEmpty) { return '' }
            Write-Host "A path is needed." -ForegroundColor Yellow
            continue
        }

        $Valid = switch ($Type)
        {
            'Folder' { Test-Path -LiteralPath $Answer -PathType Container }
            'File'   { Test-Path -LiteralPath $Answer -PathType Leaf }
            default  { Test-Path -LiteralPath $Answer }
        }

        if ($Valid)
        {
            return (Resolve-Path -LiteralPath $Answer).Path
        }

        Write-Host "Not found ($($Type.ToLower())): $Answer" -ForegroundColor Yellow
    }
}

function Read-OutputFolder
{
    # Asks for an output folder; creates it after confirmation.
    param([string]$Prompt, [string]$Default = '')

    while ($true)
    {
        $Answer = ConvertTo-CleanPath (Read-Text -Prompt $Prompt -Default $Default)

        if ($Answer -eq '')
        {
            Write-Host "A folder is needed." -ForegroundColor Yellow
            continue
        }

        if (Test-Path -LiteralPath $Answer -PathType Container)
        {
            return (Resolve-Path -LiteralPath $Answer).Path
        }

        if (Test-Path -LiteralPath $Answer -PathType Leaf)
        {
            Write-Host "That is a file, not a folder: $Answer" -ForegroundColor Yellow
            continue
        }

        if (Read-YesNo -Prompt "Folder does not exist. Create $Answer?" -Default $true)
        {
            New-Item -ItemType Directory -Path $Answer -Force | Out-Null
            return (Resolve-Path -LiteralPath $Answer).Path
        }
    }
}

function Read-PathList
{
    # Asks for one or more existing paths, one per line, until Enter on an
    # empty line. The first line may be accepted from the default.
    param([string]$Prompt, [string]$Default = '')

    $Paths = [System.Collections.ArrayList]::new()
    Write-Host "$Prompt One per line; press Enter on an empty line when done."

    while ($true)
    {
        $LinePrompt = "  Path $($Paths.Count + 1)"
        $LineDefault = if ($Paths.Count -eq 0) { $Default } else { '' }
        $Answer = ConvertTo-CleanPath (Read-Text -Prompt $LinePrompt -Default $LineDefault)

        if ($Answer -eq '')
        {
            if ($Paths.Count -gt 0) { return @($Paths) }
            Write-Host "At least one path is needed." -ForegroundColor Yellow
            continue
        }

        if (Test-Path -LiteralPath $Answer)
        {
            [void]$Paths.Add((Resolve-Path -LiteralPath $Answer).Path)
        }
        else
        {
            Write-Host "Not found: $Answer" -ForegroundColor Yellow
        }
    }
}

function Show-Command
{
    # Prints the equivalent direct command, so it can be reused.
    param([string]$Script, [System.Collections.IDictionary]$Parameters)

    $Parts = [System.Collections.ArrayList]::new()
    [void]$Parts.Add(".\Scripts\$Script")

    foreach ($Name in $Parameters.Keys)
    {
        $Value = $Parameters[$Name]

        if ($Value -is [switch] -or $Value -is [bool])
        {
            if ($Value) { [void]$Parts.Add("-$Name") }
        }
        elseif ($Value -is [array])
        {
            [void]$Parts.Add("-$Name $(@($Value | ForEach-Object { '"' + $_ + '"' }) -join ', ')")
        }
        else
        {
            [void]$Parts.Add("-$Name `"$Value`"")
        }
    }

    Write-Host ""
    Write-Host "Running: $($Parts -join ' ')" -ForegroundColor Cyan
    Write-Host ""
}

function Invoke-ToolkitScript
{
    # Runs a script from the Scripts folder. Errors are shown and the menu
    # continues.
    param([string]$Script, [System.Collections.IDictionary]$Parameters)

    $Path = Join-Path $ScriptsFolder $Script

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Host "Script not found: $Path" -ForegroundColor Red
        return $false
    }

    Show-Command -Script $Script -Parameters $Parameters

    # Splatting needs a hashtable; the menu builds ordered dictionaries.
    $Splat = @{}

    foreach ($Name in $Parameters.Keys)
    {
        $Splat[$Name] = $Parameters[$Name]
    }

    try
    {
        & $Path @Splat
        Write-Host ""
        Write-Host "Finished: $Script" -ForegroundColor Green
        return $true
    }
    catch
    {
        Write-Host ""
        Write-Host "$Script stopped with an error:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

function Invoke-CompareXml
{
    Write-Host "Compare GPO XML exports (Get-GPOReport -ReportType Xml)." -ForegroundColor Cyan
    $XmlFolder = Read-ExistingPath -Prompt 'Folder with the GPO XML exports' -Default $Last.XmlFolder -Type Folder
    $Output = Read-OutputFolder -Prompt 'Output folder' -Default $(if ($Last.CompareOutput) { $Last.CompareOutput } else { Join-Path $XmlFolder 'Output' })

    $Last.XmlFolder = $XmlFolder
    $Last.CompareOutput = $Output

    [void](Invoke-ToolkitScript -Script 'Compare-GPOXml.ps1' -Parameters ([ordered]@{ XmlFolder = $XmlFolder; OutputFolder = $Output }))
}

function Invoke-CompareHtml
{
    Write-Host "Compare GPResult HTML reports (gpresult /h)." -ForegroundColor Cyan
    $HtmlFolder = Read-ExistingPath -Prompt 'Folder with the GPResult HTML reports' -Default $Last.HtmlFolder -Type Folder
    $Output = Read-OutputFolder -Prompt 'Output folder' -Default $(if ($Last.CompareOutput) { $Last.CompareOutput } else { Join-Path $HtmlFolder 'Output' })

    $Last.HtmlFolder = $HtmlFolder
    $Last.CompareOutput = $Output

    [void](Invoke-ToolkitScript -Script 'Compare-GPOHtml.ps1' -Parameters ([ordered]@{ HtmlFolder = $HtmlFolder; OutputFolder = $Output }))
}

function Invoke-IntunePlan
{
    Write-Host "Build an Intune policy plan from compare output (grouped by the GPOs a setting is in)." -ForegroundColor Cyan
    $InputPath = Read-ExistingPath -Prompt 'Compare output folder or workbook (.xlsx)' -Default $Last.CompareOutput
    $Parameters = [ordered]@{ InputPath = $InputPath }

    $DefaultOutput = if (Test-Path -LiteralPath $InputPath -PathType Container) { $InputPath } else { Split-Path $InputPath -Parent }
    $Output = Read-OutputFolder -Prompt 'Output folder' -Default $DefaultOutput

    if ($Output -ne $DefaultOutput)
    {
        $Parameters.OutputFolder = $Output
    }

    $Prefix = Read-Text -Prompt 'File name prefix of the compare run (only if the folder holds several runs; Enter for none)'
    if ($Prefix -ne '') { $Parameters.FilePrefix = $Prefix }

    $NamePrefix = Read-Text -Prompt 'Text to put before every policy name (for example "WIN - "; Enter for none)'
    if ($NamePrefix -ne '') { $Parameters.PolicyNamePrefix = $NamePrefix }

    $Last.CompareOutput = $InputPath
    $Last.PlanOutput = $Output

    [void](Invoke-ToolkitScript -Script 'New-IntunePolicyPlan.ps1' -Parameters $Parameters)
}

function Test-ConsolidationConfig
{
    # GpoRoles.csv and ConsolidationRules.json must exist in Config. Offers
    # to copy the example files. Returns $true when both exist.
    $Ready = $true

    foreach ($Pair in @(@{ File = 'GpoRoles.csv'; Example = 'GpoRoles.example.csv' }, @{ File = 'ConsolidationRules.json'; Example = 'ConsolidationRules.example.json' }))
    {
        $Path = Join-Path $ConfigFolder $Pair.File

        if (Test-Path -LiteralPath $Path -PathType Leaf)
        {
            continue
        }

        Write-Host "Missing: $Path" -ForegroundColor Yellow
        $Example = Join-Path $ConfigFolder $Pair.Example

        if ((Test-Path -LiteralPath $Example -PathType Leaf) -and (Read-YesNo -Prompt "Copy $($Pair.Example) to $($Pair.File) so you can edit it?" -Default $true))
        {
            Copy-Item -LiteralPath $Example -Destination $Path
            Write-Host "Created $Path" -ForegroundColor Green
        }

        $Ready = $false
    }

    if (-not $Ready)
    {
        Write-Host "Fill in your GPO names, sites and roles in the Config folder files, then run this action again." -ForegroundColor Yellow
    }

    return $Ready
}

function Invoke-ConsolidationPlan
{
    Write-Host "Build a GPO consolidation plan (baseline, hardening, branding per site) grouped by GPO role." -ForegroundColor Cyan
    Write-Host "Uses Config\GpoRoles.csv and Config\ConsolidationRules.json."

    if (-not (Test-ConsolidationConfig))
    {
        return
    }

    $Inputs = @(Read-PathList -Prompt 'Compare output: Compare-GPOXml workbooks or folders, and optionally Compare-GPOHtml output for GPOs without an XML export.' -Default $Last.CompareOutput)
    $FirstInput = $Inputs[0]
    $DefaultOutput = if (Test-Path -LiteralPath $FirstInput -PathType Container) { $FirstInput } else { Split-Path $FirstInput -Parent }
    $Output = Read-OutputFolder -Prompt 'Output folder' -Default $(if ($Last.PlanOutput) { $Last.PlanOutput } else { $DefaultOutput })
    $Prefix = Read-Text -Prompt 'Output file name prefix (Enter for none)'

    $Parameters = [ordered]@{
        InputPath  = $Inputs
        OutputPath = (Join-Path $Output "$($Prefix)GpoConsolidationPlan-$(Get-Date -Format 'yyyyMMdd-HHmmss').xlsx")
    }

    $Last.PlanOutput = $Output

    [void](Invoke-ToolkitScript -Script 'New-GpoConsolidationPlan.ps1' -Parameters $Parameters)
}

function Invoke-MappingImport
{
    Write-Host "Import manual GPO-to-Intune mapping workbooks into Data\IntunePolicyMappings.json." -ForegroundColor Cyan
    $Inputs = @(Read-PathList -Prompt 'Mapping workbooks (.xlsx) or folders of workbooks.' -Default $Last.MappingInput)
    $Parameters = [ordered]@{ Path = $Inputs }

    if (Read-YesNo -Prompt 'Rebuild the mapping file from these workbooks only (needed after changing a mapping)?' -Default $false)
    {
        $Parameters.Rebuild = $true
    }

    if (Read-YesNo -Prompt 'Keep sensitive data (internal file Config\IntunePolicyMappings.Internal.json with remarks; never commit it)?' -Default $false)
    {
        $Parameters.KeepSensitiveData = $true
    }

    $Report = ConvertTo-CleanPath (Read-Text -Prompt 'Optional import report CSV path (Enter for none)')
    if ($Report -ne '') { $Parameters.ReportPath = $Report }

    $Last.MappingInput = $Inputs[0]

    [void](Invoke-ToolkitScript -Script 'Import-IntuneMappingWorkbook.ps1' -Parameters $Parameters)
}

function Show-ToolkitCheck
{
    # Lists the expected files and whether each exists.
    Write-Host "Toolkit folder: $ToolkitRoot" -ForegroundColor Cyan

    $Expected = @(
        @{ Path = 'Scripts\Compare-GPOXml.ps1';                 Note = 'required for action 1' },
        @{ Path = 'Scripts\Compare-GPOHtml.ps1';                Note = 'required for action 2' },
        @{ Path = 'Scripts\New-IntunePolicyPlan.ps1';           Note = 'required for action 3' },
        @{ Path = 'Scripts\New-GpoConsolidationPlan.ps1';       Note = 'required for action 4' },
        @{ Path = 'Scripts\Import-IntuneMappingWorkbook.ps1';   Note = 'required for action 5' },
        @{ Path = 'Modules\GPOCompare.psm1';                    Note = 'required for actions 1 and 4' },
        @{ Path = 'Modules\GPOCompareHtml.psm1';                Note = 'required for action 2' },
        @{ Path = 'Modules\GPOConsolidation.psm1';              Note = 'required for action 4' },
        @{ Path = 'Data\DeprecatedPoliciesReference.md';        Note = 'optional; deprecated policy matches' },
        @{ Path = 'Data\intunemapping.json';                    Note = 'optional; general Intune mapping rules' },
        @{ Path = 'Data\IntunePolicyMappings.json';             Note = 'optional; per-policy Intune mappings' },
        @{ Path = 'Data\IntuneMigrationExclusions.json';        Note = 'optional; exclusions for the compare scripts' },
        @{ Path = 'Config\GpoRoles.csv';                        Note = 'required for action 4 (copy from GpoRoles.example.csv)' },
        @{ Path = 'Config\ConsolidationRules.json';             Note = 'required for action 4 (copy from ConsolidationRules.example.json)' },
        @{ Path = 'Config\IntuneMappingRedactions.txt';         Note = 'optional; organization terms for action 5' }
    )

    foreach ($Item in $Expected)
    {
        $Found = Test-Path -LiteralPath (Join-Path $ToolkitRoot $Item.Path) -PathType Leaf
        $Mark = if ($Found) { 'OK     ' } else { 'MISSING' }
        $Color = if ($Found) { 'Green' } elseif ($Item.Note -like 'required*') { 'Red' } else { 'Yellow' }
        Write-Host "  $Mark  $($Item.Path)  ($($Item.Note))" -ForegroundColor $Color
    }

    $Excel = Get-Module -ListAvailable -Name ImportExcel | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -ne $Excel)
    {
        Write-Host "  OK       ImportExcel module $($Excel.Version)" -ForegroundColor Green
    }
    else
    {
        Write-Host "  MISSING  ImportExcel module (needed for Excel output and actions 3-5; the scripts offer to install it)" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

$Actions = [ordered]@{
    '1' = @{ Text = 'Compare GPO XML exports';                    Run = { Invoke-CompareXml } }
    '2' = @{ Text = 'Compare GPResult HTML reports';              Run = { Invoke-CompareHtml } }
    '3' = @{ Text = 'Build an Intune policy plan';                Run = { Invoke-IntunePlan } }
    '4' = @{ Text = 'Build a GPO consolidation plan';             Run = { Invoke-ConsolidationPlan } }
    '5' = @{ Text = 'Import Intune mapping workbooks';            Run = { Invoke-MappingImport } }
    '6' = @{ Text = 'Check the toolkit files';                    Run = { Show-ToolkitCheck } }
}

while ($true)
{
    Write-Host ""
    Write-Host "GPO Evaluation Toolkit" -ForegroundColor Cyan
    Write-Host "======================" -ForegroundColor Cyan

    foreach ($Key in $Actions.Keys)
    {
        Write-Host "  $Key  $($Actions[$Key].Text)"
    }

    Write-Host "  Q  Quit"
    Write-Host ""

    $Choice = "$(Read-Host 'Choose an action')".Trim()

    if ($Choice -match '^(?i)(q|quit|exit)$')
    {
        break
    }

    if (-not $Actions.Contains($Choice))
    {
        # Read-Host returns nothing when input has ended (for example a
        # redirected input stream); stop instead of looping.
        if ([Console]::IsInputRedirected -and ($Choice -eq ''))
        {
            break
        }

        Write-Host "Choose 1-$($Actions.Count) or Q." -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    & $Actions[$Choice].Run
}
