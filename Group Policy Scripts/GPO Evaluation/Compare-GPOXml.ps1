<#
.SYNOPSIS
    Pre-production GPO XML parser validation script

.DESCRIPTION
    Validates GPOCompare.psm1 functionality before
    running full comparison reporting.

.NOTES
    Intended for parser testing and troubleshooting.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$XmlFolder,

    [Parameter(Mandatory)]
    [string]$OutputFolder,

    [string]$ModulePath = ".\GPOCompare.psm1"
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if (-not (Test-Path $XmlFolder))
{
    throw "XML folder not found: $XmlFolder"
}

if (-not (Test-Path $OutputFolder))
{
    New-Item `
        -Path $OutputFolder `
        -ItemType Directory `
        -Force | Out-Null
}

Import-Module $ModulePath -Force

# ------------------------------------------------------------
# Files
# ------------------------------------------------------------

$XmlFiles =
    Get-ChildItem `
        -Path $XmlFolder `
        -Filter *.xml

if ($XmlFiles.Count -lt 2)
{
    throw "At least two XML files are required."
}

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

$AllSettings     = [System.Collections.ArrayList]::new()
$AllFirewall     = [System.Collections.ArrayList]::new()
$AllUnclassified = [System.Collections.ArrayList]::new()

# ------------------------------------------------------------
# Parse XML Files
# ------------------------------------------------------------

foreach ($XmlFile in $XmlFiles)
{
    Write-Host ""
    Write-Host "Processing: $($XmlFile.Name)"
    Write-Host ""

    try
    {
        $Result =
            Get-GPOSettingsFromXml `
                -Path $XmlFile.FullName `
                -GPOName $XmlFile.BaseName

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

        Write-Host "Settings      : $($Result.Settings.Count)"
        Write-Host "FirewallRules : $($Result.FirewallRules.Count)"
        Write-Host "Unclassified  : $($Result.Unclassified.Count)"
    }
    catch
    {
        Write-Warning $_.Exception.Message
    }
}

# ------------------------------------------------------------
# Build Comparison Maps
# ------------------------------------------------------------

$TotalGPOs =
    (
        $AllSettings.GPOName |
        Sort-Object -Unique
    ).Count

$ExactMap = @{}
$NameMap  = @{}

foreach ($Setting in $AllSettings)
{
    $ExactKey = @(
        $Setting.Class
        $Setting.Extension
        $Setting.Category
        $Setting.SettingName
        $Setting.Value
        $Setting.State
    ) -join "|"

    $NameKey = @(
        $Setting.Class
        $Setting.Extension
        $Setting.Category
        $Setting.SettingName
    ) -join "|"

    if (-not $ExactMap.ContainsKey($ExactKey))
    {
        $ExactMap[$ExactKey] = @{
            Item = $Setting
            GPOs = [System.Collections.Generic.HashSet[string]]::new()
        }
    }

    $null =
        $ExactMap[$ExactKey].GPOs.Add(
            $Setting.GPOName
        )

    if (-not $NameMap.ContainsKey($NameKey))
    {
        $NameMap[$NameKey] =
            [System.Collections.ArrayList]::new()
    }

    [void]$NameMap[$NameKey].Add(
        $Setting
    )
}

# ------------------------------------------------------------
# Common (Exact)
# ------------------------------------------------------------

$CommonSettings =
foreach ($Key in $ExactMap.Keys)
{
    $Item = $ExactMap[$Key]

    if ($Item.GPOs.Count -eq $TotalGPOs)
    {
        $Item.Item
    }
}

# ------------------------------------------------------------
# Common (By Name)
# ------------------------------------------------------------

$CommonSettingsByName =
foreach ($Key in $NameMap.Keys)
{
    $Items =
        $NameMap[$Key]

    $DistinctGPOs =
        $Items.GPOName |
        Sort-Object -Unique

    if (@($DistinctGPOs).Count -eq $TotalGPOs)
    {
        $Items[0]
    }
}

# ------------------------------------------------------------
# Unique
# ------------------------------------------------------------

$UniqueSettings =
foreach ($Key in $ExactMap.Keys)
{
    $Item = $ExactMap[$Key]

    if ($Item.GPOs.Count -lt $TotalGPOs)
    {
        [PSCustomObject]@{

            Class =
                $Item.Item.Class

            Extension =
                $Item.Item.Extension

            Category =
                $Item.Item.Category

            SettingName =
                $Item.Item.SettingName

            Value =
                $Item.Item.Value

            State =
                $Item.Item.State

            PresentIn =
                ($Item.GPOs -join '; ')
        }
    }
}

# ------------------------------------------------------------
# Conflicts
# ------------------------------------------------------------

$ConflictingSettings =
foreach ($Key in $NameMap.Keys)
{
    $Items =
        $NameMap[$Key]

    $Configs =
        $Items |
        Select-Object Value,State -Unique

    if (@($Configs).Count -gt 1)
    {
        $Items
    }
}

# ------------------------------------------------------------
# Duplicates
# ------------------------------------------------------------

$DuplicateSettings =
foreach ($Key in $NameMap.Keys)
{
    $Items =
        $NameMap[$Key]

    $Configs =
        $Items |
        Select-Object Value,State -Unique

    if (@($Configs).Count -eq 1)
    {
        $DistinctGPOs =
            $Items.GPOName |
            Sort-Object -Unique

        if (@($DistinctGPOs).Count -gt 1)
        {
            [PSCustomObject]@{

                Class =
                    $Items[0].Class

                Extension =
                    $Items[0].Extension

                Category =
                    $Items[0].Category

                SettingName =
                    $Items[0].SettingName

                Value =
                    $Items[0].Value

                State =
                    $Items[0].State

                GPOs =
                    ($DistinctGPOs -join '; ')
            }
        }
    }
}

# ------------------------------------------------------------
# Missing Matrix
# ------------------------------------------------------------

$AllGPOs =
    $AllSettings.GPOName |
    Sort-Object -Unique

$Matrix =
foreach ($Key in $NameMap.Keys)
{
    $Items = $NameMap[$Key]

    $Row = [ordered]@{}

    $Row["Setting"] = $Key

    foreach ($GPO in $AllGPOs)
    {
        $Row[$GPO] = "Missing"
    }

    foreach ($Item in $Items)
    {
        $Row[$Item.GPOName] = "Present"
    }

    [PSCustomObject]$Row
}

# ------------------------------------------------------------
# Intune Migration Candidates
# ------------------------------------------------------------

$MigrationCandidates =
$AllSettings |
Select-Object `
    GPOName,
    Class,
    Extension,
    Category,
    SettingName,
    Value,
    State

# ------------------------------------------------------------
# Export Reports
# ------------------------------------------------------------

$CommonSettings |
Export-Csv (
    Join-Path $OutputFolder "CommonSettings.csv"
) -NoTypeInformation

$CommonSettingsByName |
Export-Csv (
    Join-Path $OutputFolder "CommonSettingsByName.csv"
) -NoTypeInformation

$UniqueSettings |
Export-Csv (
    Join-Path $OutputFolder "UniqueSettings.csv"
) -NoTypeInformation

$ConflictingSettings |
Export-Csv (
    Join-Path $OutputFolder "ConflictingSettings.csv"
) -NoTypeInformation

$DuplicateSettings |
Export-Csv (
    Join-Path $OutputFolder "DuplicateSettings.csv"
) -NoTypeInformation

$Matrix |
Export-Csv (
    Join-Path $OutputFolder "MissingSettingsMatrix.csv"
) -NoTypeInformation

$AllFirewall |
Export-Csv (
    Join-Path $OutputFolder "FirewallRules.csv"
) -NoTypeInformation

$MigrationCandidates |
Export-Csv (
    Join-Path $OutputFolder "IntuneMigrationCandidates.csv"
) -NoTypeInformation

$AllUnclassified |
Export-Csv (
    Join-Path $OutputFolder "UnclassifiedSettings.csv"
) -NoTypeInformation

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "====================================="
Write-Host "Report Generation Complete"
Write-Host "====================================="
Write-Host ""

Write-Host "Common Exact      : $($CommonSettings.Count)"
Write-Host "Common By Name    : $($CommonSettingsByName.Count)"
Write-Host "Unique            : $($UniqueSettings.Count)"
Write-Host "Conflicting       : $($ConflictingSettings.Count)"
Write-Host "Duplicate         : $($DuplicateSettings.Count)"
Write-Host "Firewall Rules    : $($AllFirewall.Count)"
Write-Host "Unclassified      : $($AllUnclassified.Count)"
Write-Host ""

Write-Host "Reports written to:"
Write-Host $OutputFolder
