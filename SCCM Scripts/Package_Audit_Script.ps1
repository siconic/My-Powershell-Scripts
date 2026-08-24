<#
.SYNOPSIS
    SCCM / Microsoft Configuration Manager Package Audit Report

.DESCRIPTION
    Connects to the SCCM SMS Provider and audits legacy Packages / Programs.

    Generates reports for:

        1. Undeployed packages
        2. Deployed packages whose target collections contain zero members
        3. Packages referenced by Task Sequences
        4. Packages/programs used as dependencies
        5. Master package inventory

    The script is READ-ONLY. It does not modify SCCM.

.AUTHOR
    Siconic

.VERSION
    1.0

.DATE
    2026-08-24

.REQUIREMENTS
    - Windows PowerShell 5.1 or PowerShell 7+
    - Network connectivity to the SCCM SMS Provider
    - RPC/DCOM connectivity to the SMS Provider
    - Account with sufficient ConfigMgr RBAC permissions to read:
        * Packages
        * Programs
        * Deployments
        * Collections
        * Task Sequences
        * Deployment status
    - Local Administrator is NOT necessarily required.
      SCCM RBAC permissions are what matter for SMS Provider access.

.NOTES
    PACKAGE CREATOR:
    SMS_Package does not expose a reliable "CreatedBy" property.
    Therefore this script reports "Not exposed by SMS_Package" rather
    than fabricating an owner.

    DATE PUBLISHED:
    Legacy packages also don't have an exact "Published Date" property.
    This script reports:
        - SourceDate
        - LastRefreshTime
        - FirstDeploymentDate
        - LastDeploymentDate

    INSTALL COUNT:
    UniqueSuccessfulDevices is derived from successful records in
    SMS_ClassicDeploymentAssetDetails. This represents SCCM's summarized
    classic deployment status, not an independent software inventory
    confirmation that the software remains installed today.
#>


# ============================================================================
# CONFIGURATION
# ============================================================================

# SCCM Site Code
$SiteCode = "ABC"

# SCCM SMS Provider server.
# This is commonly the Primary Site Server, but your environment may have
# remote SMS Providers.
$ProviderMachineName = "SCCM01.contoso.com"

# Directory where CSV reports will be created
$ExportPath = "C:\SCCM_Package_Audit"

# Set to $false if your environment is very large and deployment asset
# status takes too long to retrieve.
$IncludeInstallCounts = $true

# CSV delimiter
$Delimiter = ","

# ============================================================================
# INITIALIZATION
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SCCM Package Audit Report" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Site Code        : $SiteCode"
Write-Host "SMS Provider     : $ProviderMachineName"
Write-Host "Export Directory : $ExportPath"
Write-Host ""

if (-not (Test-Path $ExportPath)) {

    Write-Host "Creating export directory..." -ForegroundColor Yellow

    New-Item `
        -Path $ExportPath `
        -ItemType Directory `
        -Force | Out-Null
}


# ============================================================================
# FUNCTIONS
# ============================================================================

function Convert-ToReadableDate {

    param (
        [Parameter(ValueFromPipeline = $true)]
        $Date
    )

    if ($null -eq $Date) {
        return $null
    }

    try {
        return ([datetime]$Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return $Date
    }
}


function Convert-PackageSize {

    param (
        [long]$SizeKB
    )

    if ($null -eq $SizeKB) {
        return $null
    }

    # SMS_Package.PackageSize is represented in KB.
    if ($SizeKB -ge 1MB) {
        return "{0:N2} GB" -f ($SizeKB / 1MB)
    }
    elseif ($SizeKB -ge 1KB) {
        return "{0:N2} MB" -f ($SizeKB / 1KB)
    }
    else {
        return "{0:N0} KB" -f $SizeKB
    }
}


function Get-PackagePriorityName {

    param (
        [int]$Priority
    )

    switch ($Priority) {
        1       { "High" }
        2       { "Medium" }
        3       { "Low" }
        default { $Priority }
    }
}


function Join-Values {

    param (
        [object[]]$Values
    )

    if (-not $Values) {
        return $null
    }

    return (
        $Values |
            Where-Object { $_ -ne $null -and "$_".Trim() -ne "" } |
            Select-Object -Unique
    ) -join "; "
}


# ============================================================================
# CONNECT TO SMS PROVIDER
# ============================================================================

Write-Host "Connecting to SCCM SMS Provider..." -ForegroundColor Cyan

try {

    # DCOM avoids requiring PowerShell Remoting / WinRM on the Provider.
    $CimOption = New-CimSessionOption -Protocol Dcom

    $CimSession = New-CimSession `
        -ComputerName $ProviderMachineName `
        -SessionOption $CimOption

    $Namespace = "root\sms\site_$SiteCode"

    # Verify connectivity
    $Site = Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_Site `
        -ErrorAction Stop |
        Where-Object {
            $_.SiteCode -eq $SiteCode
        } |
        Select-Object -First 1

    if (-not $Site) {
        throw "Site $SiteCode was not found through SMS Provider $ProviderMachineName."
    }

    Write-Host "Connected successfully to SCCM site $SiteCode." -ForegroundColor Green
}
catch {

    Write-Host ""
    Write-Host "ERROR: Could not connect to SCCM." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    throw
}


# ============================================================================
# GATHER PACKAGE INFORMATION
# ============================================================================

Write-Host ""
Write-Host "Gathering legacy package information..." -ForegroundColor Cyan

# SMS_Package represents classic/legacy software distribution packages.
$Packages = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_Package |
    Where-Object {
        $_.ActionInProgress -ne 3
    }
)

Write-Host "Packages found: $($Packages.Count)" -ForegroundColor Green


# Create fast package lookup table
$PackageLookup = @{}

foreach ($Package in $Packages) {
    $PackageLookup[$Package.PackageID] = $Package
}


# ============================================================================
# GATHER PROGRAM INFORMATION
# ============================================================================

Write-Host "Gathering package programs..." -ForegroundColor Cyan

$Programs = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_Program |
    Where-Object {
        $_.ActionInProgress -ne 3
    }
)

Write-Host "Programs found: $($Programs.Count)" -ForegroundColor Green


# Group programs by package
$ProgramsByPackage = @{}

foreach ($Program in $Programs) {

    if (-not $ProgramsByPackage.ContainsKey($Program.PackageID)) {
        $ProgramsByPackage[$Program.PackageID] = @()
    }

    $ProgramsByPackage[$Program.PackageID] += $Program
}


# ============================================================================
# GATHER PACKAGE DEPLOYMENTS
# ============================================================================

Write-Host "Gathering package deployments..." -ForegroundColor Cyan

$Advertisements = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_Advertisement
)

Write-Host "Package deployments found: $($Advertisements.Count)" -ForegroundColor Green


$DeploymentsByPackage = @{}

foreach ($Advertisement in $Advertisements) {

    if (-not $DeploymentsByPackage.ContainsKey($Advertisement.PackageID)) {
        $DeploymentsByPackage[$Advertisement.PackageID] = @()
    }

    $DeploymentsByPackage[$Advertisement.PackageID] += $Advertisement
}


# ============================================================================
# DEPLOYMENT SUMMARIES
# ============================================================================

Write-Host "Gathering deployment summaries..." -ForegroundColor Cyan

$DeploymentSummaries = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_DeploymentSummary |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.PackageID)
    }
)


$SummaryByPackage = @{}

foreach ($Summary in $DeploymentSummaries) {

    if (-not $SummaryByPackage.ContainsKey($Summary.PackageID)) {
        $SummaryByPackage[$Summary.PackageID] = @()
    }

    $SummaryByPackage[$Summary.PackageID] += $Summary
}


# ============================================================================
# COLLECTION INFORMATION
# ============================================================================

Write-Host "Gathering collection information..." -ForegroundColor Cyan

$Collections = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_Collection
)

$CollectionLookup = @{}

foreach ($Collection in $Collections) {
    $CollectionLookup[$Collection.CollectionID] = $Collection
}

Write-Host "Collections found: $($Collections.Count)" -ForegroundColor Green


# ============================================================================
# TASK SEQUENCE REFERENCES
# ============================================================================

Write-Host "Gathering Task Sequence package references..." -ForegroundColor Cyan

$TaskSequenceReferences = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_TaskSequencePackageReference
)


# Get TS package names
$TaskSequences = @(
    Get-CimInstance `
        -CimSession $CimSession `
        -Namespace $Namespace `
        -ClassName SMS_TaskSequencePackage
)

$TaskSequenceLookup = @{}

foreach ($TS in $TaskSequences) {
    $TaskSequenceLookup[$TS.PackageID] = $TS
}


# Build lookup:
# referenced PackageID -> TS references
$TSReferencesByPackage = @{}

foreach ($Reference in $TaskSequenceReferences) {

    # ObjectType 0 = Regular Package
    if ($Reference.ObjectType -eq 0) {

        $ReferencedPackageID = $Reference.ObjectID

        if (-not $TSReferencesByPackage.ContainsKey($ReferencedPackageID)) {
            $TSReferencesByPackage[$ReferencedPackageID] = @()
        }

        $TSReferencesByPackage[$ReferencedPackageID] += $Reference
    }
}


# ============================================================================
# SUCCESSFUL INSTALL / EXECUTION COUNTS
# ============================================================================

$SuccessfulDeviceLookup = @{}

if ($IncludeInstallCounts) {

    Write-Host ""
    Write-Host "Gathering successful classic deployment asset status..." -ForegroundColor Cyan
    Write-Host "This may take some time in large SCCM environments." -ForegroundColor Yellow

    try {

        $SuccessfulAssets = @(
            Get-CimInstance `
                -CimSession $CimSession `
                -Namespace $Namespace `
                -ClassName SMS_ClassicDeploymentAssetDetails `
                -Filter "StatusType = 1"
        )

        Write-Host "Successful deployment status records: $($SuccessfulAssets.Count)" `
            -ForegroundColor Green


        # Calculate unique DeviceIDs for each PackageID.
        foreach ($Group in ($SuccessfulAssets | Group-Object PackageID)) {

            if ([string]::IsNullOrWhiteSpace($Group.Name)) {
                continue
            }

            $UniqueDevices = @(
                $Group.Group |
                    Select-Object -ExpandProperty DeviceID -Unique
            )

            $SuccessfulDeviceLookup[$Group.Name] = $UniqueDevices.Count
        }
    }
    catch {

        Write-Warning "Could not retrieve SMS_ClassicDeploymentAssetDetails."
        Write-Warning $_.Exception.Message
    }
}


# ============================================================================
# MASTER PACKAGE REPORT
# ============================================================================

Write-Host ""
Write-Host "Building master package inventory..." -ForegroundColor Cyan

$MasterReport = foreach ($Package in $Packages) {

    $PackageID = $Package.PackageID


    # ------------------------------------------------------------------------
    # Programs
    # ------------------------------------------------------------------------

    $PackagePrograms = @()

    if ($ProgramsByPackage.ContainsKey($PackageID)) {
        $PackagePrograms = @($ProgramsByPackage[$PackageID])
    }


    # ------------------------------------------------------------------------
    # Deployments
    # ------------------------------------------------------------------------

    $PackageDeployments = @()

    if ($DeploymentsByPackage.ContainsKey($PackageID)) {
        $PackageDeployments = @($DeploymentsByPackage[$PackageID])
    }


    # ------------------------------------------------------------------------
    # Deployment summaries
    # ------------------------------------------------------------------------

    $PackageSummaries = @()

    if ($SummaryByPackage.ContainsKey($PackageID)) {
        $PackageSummaries = @($SummaryByPackage[$PackageID])
    }


    # ------------------------------------------------------------------------
    # Target collections
    # ------------------------------------------------------------------------

    $TargetCollectionNames = @()
    $TargetCollectionIDs   = @()
    $EmptyCollectionCount  = 0

    foreach ($Deployment in $PackageDeployments) {

        $CollectionID = $Deployment.CollectionID

        $TargetCollectionIDs += $CollectionID

        if ($CollectionLookup.ContainsKey($CollectionID)) {

            $Collection = $CollectionLookup[$CollectionID]

            $TargetCollectionNames += $Collection.Name

            if ([int]$Collection.MemberCount -eq 0) {
                $EmptyCollectionCount++
            }
        }
        else {

            $TargetCollectionNames += "[Collection Missing: $CollectionID]"
        }
    }


    # ------------------------------------------------------------------------
    # Task Sequences
    # ------------------------------------------------------------------------

    $TSNames = @()
    $TSIDs   = @()

    if ($TSReferencesByPackage.ContainsKey($PackageID)) {

        foreach ($Reference in $TSReferencesByPackage[$PackageID]) {

            $TaskSequenceID = $Reference.PackageID

            $TSIDs += $TaskSequenceID

            if ($TaskSequenceLookup.ContainsKey($TaskSequenceID)) {
                $TSNames += $TaskSequenceLookup[$TaskSequenceID].Name
            }
            else {
                $TSNames += "[Unknown TS: $TaskSequenceID]"
            }
        }
    }


    # ------------------------------------------------------------------------
    # Dependency determination
    #
    # Does another program reference this package as its dependency?
    # ------------------------------------------------------------------------

    $DependentByPrograms = @()

    foreach ($Program in $Programs) {

        if ([string]::IsNullOrWhiteSpace($Program.DependentProgram)) {
            continue
        }

        $DependentText = $Program.DependentProgram

        # Expected:
        # ABC00001;;Install
        #
        # Same package dependency:
        # ;;Install

        $Parts = $DependentText -split ";;", 2

        $DependentPackageID = $Parts[0]

        if ([string]::IsNullOrWhiteSpace($DependentPackageID)) {
            $DependentPackageID = $Program.PackageID
        }

        if ($DependentPackageID -eq $PackageID) {

            $DependentByPrograms += `
                "$($Program.PackageID) / $($Program.ProgramName)"
        }
    }


    # ------------------------------------------------------------------------
    # Deployment dates
    # ------------------------------------------------------------------------

    $DeploymentCreationDates = @(
        $PackageSummaries |
        Where-Object {
            $_.CreationTime
        } |
        Select-Object -ExpandProperty CreationTime
    )

    $FirstDeploymentDate = $null
    $LastDeploymentDate  = $null

    if ($DeploymentCreationDates.Count -gt 0) {

        $SortedDates = @(
            $DeploymentCreationDates |
            Sort-Object
        )

        $FirstDeploymentDate = $SortedDates[0]
        $LastDeploymentDate  = $SortedDates[-1]
    }


    # ------------------------------------------------------------------------
    # Deployment status
    # ------------------------------------------------------------------------

    $SuccessfulStateCount = (
        $PackageSummaries |
        Measure-Object -Property NumberSuccess -Sum
    ).Sum

    $ErrorStateCount = (
        $PackageSummaries |
        Measure-Object -Property NumberErrors -Sum
    ).Sum

    $InProgressStateCount = (
        $PackageSummaries |
        Measure-Object -Property NumberInProgress -Sum
    ).Sum

    $UnknownStateCount = (
        $PackageSummaries |
        Measure-Object -Property NumberUnknown -Sum
    ).Sum

    $TargetedStateCount = (
        $PackageSummaries |
        Measure-Object -Property NumberTargeted -Sum
    ).Sum


    $UniqueSuccessfulDevices = 0

    if ($SuccessfulDeviceLookup.ContainsKey($PackageID)) {
        $UniqueSuccessfulDevices = $SuccessfulDeviceLookup[$PackageID]
    }


    # ------------------------------------------------------------------------
    # Output object
    # ------------------------------------------------------------------------

    [PSCustomObject]@{

        PackageID                    = $PackageID
        PackageName                  = $Package.Name
        Manufacturer                 = $Package.Manufacturer
        Version                      = $Package.Version
        Language                     = $Package.Language
        Description                  = $Package.Description

        ContentSource                = $Package.PkgSourcePath

        PackageSize                  = Convert-PackageSize $Package.PackageSize
        PackageSizeKB                = $Package.PackageSize

        SourceDate                   = Convert-ToReadableDate $Package.SourceDate
        LastContentRefresh           = Convert-ToReadableDate $Package.LastRefreshTime
        SourceVersion                = $Package.SourceVersion
        SourceSite                   = $Package.SourceSite

        FirstDeploymentDate          = Convert-ToReadableDate $FirstDeploymentDate
        LastDeploymentDate           = Convert-ToReadableDate $LastDeploymentDate

        CreatedBy                    = "Not exposed by SMS_Package"

        ProgramCount                 = $PackagePrograms.Count

        ProgramNames                 = Join-Values `
            ($PackagePrograms | Select-Object -ExpandProperty ProgramName)

        DeploymentCount              = $PackageDeployments.Count

        IsDeployed                   = ($PackageDeployments.Count -gt 0)

        TargetCollectionIDs          = Join-Values $TargetCollectionIDs
        TargetCollections            = Join-Values $TargetCollectionNames

        EmptyTargetCollectionCount   = $EmptyCollectionCount

        HasEmptyTargetCollection     = ($EmptyCollectionCount -gt 0)

        InTaskSequence               = $TSReferencesByPackage.ContainsKey($PackageID)

        TaskSequenceIDs              = Join-Values $TSIDs
        TaskSequenceNames            = Join-Values $TSNames

        IsDependency                 = ($DependentByPrograms.Count -gt 0)

        DependedOnBy                 = Join-Values $DependentByPrograms

        UniqueSuccessfulDevices      = $UniqueSuccessfulDevices

        DeploymentSuccessStates      = $SuccessfulStateCount
        DeploymentErrorStates        = $ErrorStateCount
        DeploymentInProgressStates   = $InProgressStateCount
        DeploymentUnknownStates      = $UnknownStateCount
        DeploymentTargetedStates     = $TargetedStateCount

        Priority                     = Get-PackagePriorityName $Package.Priority

        SecurityScopes               = Join-Values $Package.SecuredScopeNames

        PackageStatus                = switch ($Package.ActionInProgress) {
            0       { "Normal" }
            1       { "Updating" }
            2       { "Adding" }
            3       { "Deleting" }
            default { $Package.ActionInProgress }
        }
    }
}


# ============================================================================
# REPORT 1
# UNDEPLOYED PACKAGES
# ============================================================================

Write-Host "Building undeployed package report..." -ForegroundColor Cyan

$UndeployedPackages = @(
    $MasterReport |
    Where-Object {
        $_.IsDeployed -eq $false
    } |
    Sort-Object PackageName
)


# ============================================================================
# REPORT 2
# DEPLOYMENTS TARGETING EMPTY COLLECTIONS
# ============================================================================

Write-Host "Building empty collection deployment report..." -ForegroundColor Cyan

$EmptyCollectionReport = foreach ($Deployment in $Advertisements) {

    $PackageID = $Deployment.PackageID

    if (-not $PackageLookup.ContainsKey($PackageID)) {
        continue
    }

    $Package = $PackageLookup[$PackageID]

    $CollectionID = $Deployment.CollectionID

    $CollectionName = $null
    $MemberCount    = $null
    $CollectionExists = $false

    if ($CollectionLookup.ContainsKey($CollectionID)) {

        $Collection = $CollectionLookup[$CollectionID]

        $CollectionExists = $true
        $CollectionName   = $Collection.Name
        $MemberCount      = $Collection.MemberCount
    }


    if (($CollectionExists -and $MemberCount -eq 0) -or (-not $CollectionExists)) {

        $Summary = @(
            $DeploymentSummaries |
            Where-Object {
                $_.DeploymentID -eq $Deployment.AdvertisementID
            }
        )

        [PSCustomObject]@{

            PackageID              = $Package.PackageID
            PackageName            = $Package.Name
            Manufacturer           = $Package.Manufacturer
            Version                = $Package.Version

            ContentSource          = $Package.PkgSourcePath
            SourceDate             = Convert-ToReadableDate $Package.SourceDate

            DeploymentID           = $Deployment.AdvertisementID
            DeploymentName         = $Deployment.AdvertisementName

            ProgramName            = $Deployment.ProgramName

            CollectionID           = $CollectionID
            CollectionName         = $CollectionName
            CollectionExists       = $CollectionExists
            CollectionMemberCount  = $MemberCount

            DeploymentSuccess      = (
                $Summary |
                Measure-Object NumberSuccess -Sum
            ).Sum

            DeploymentErrors       = (
                $Summary |
                Measure-Object NumberErrors -Sum
            ).Sum

            DeploymentTargeted     = (
                $Summary |
                Measure-Object NumberTargeted -Sum
            ).Sum

            Issue = if (-not $CollectionExists) {
                "Target collection no longer exists"
            }
            else {
                "Target collection contains zero members"
            }
        }
    }
}


# ============================================================================
# REPORT 3
# PACKAGES REFERENCED BY TASK SEQUENCES
# ============================================================================

Write-Host "Building Task Sequence reference report..." -ForegroundColor Cyan

$TaskSequencePackageReport = foreach ($Reference in $TaskSequenceReferences) {

    # ObjectType 0 = regular package
    if ($Reference.ObjectType -ne 0) {
        continue
    }

    $PackageID      = $Reference.ObjectID
    $TaskSequenceID = $Reference.PackageID

    $Package = $null
    $TS      = $null

    if ($PackageLookup.ContainsKey($PackageID)) {
        $Package = $PackageLookup[$PackageID]
    }

    if ($TaskSequenceLookup.ContainsKey($TaskSequenceID)) {
        $TS = $TaskSequenceLookup[$TaskSequenceID]
    }


    [PSCustomObject]@{

        PackageID          = $PackageID

        PackageName        = if ($Package) {
                                $Package.Name
                             }
                             else {
                                $Reference.ObjectName
                             }

        Manufacturer       = if ($Package) {
                                $Package.Manufacturer
                             }

        Version            = if ($Package) {
                                $Package.Version
                             }

        ContentSource      = if ($Package) {
                                $Package.PkgSourcePath
                             }

        SourceDate         = if ($Package) {
                                Convert-ToReadableDate $Package.SourceDate
                             }

        TaskSequenceID     = $TaskSequenceID

        TaskSequenceName   = if ($TS) {
                                $TS.Name
                             }
                             else {
                                "[Unknown Task Sequence]"
                             }

        ReferenceName      = $Reference.ObjectName
        ReferenceVersion   = $Reference.Version
        ReferenceDescription = $Reference.Description
    }
}


# ============================================================================
# REPORT 4
# PACKAGE / PROGRAM DEPENDENCIES
# ============================================================================

Write-Host "Building package dependency report..." -ForegroundColor Cyan

$DependencyReport = foreach ($Program in $Programs) {

    if ([string]::IsNullOrWhiteSpace($Program.DependentProgram)) {
        continue
    }


    $Parts = $Program.DependentProgram -split ";;", 2

    $DependencyPackageID = $Parts[0]
    $DependencyProgram   = $null

    if ($Parts.Count -gt 1) {
        $DependencyProgram = $Parts[1]
    }


    # ;;ProgramName means dependency is inside the same package.
    if ([string]::IsNullOrWhiteSpace($DependencyPackageID)) {
        $DependencyPackageID = $Program.PackageID
    }


    $ParentPackage     = $null
    $DependencyPackage = $null

    if ($PackageLookup.ContainsKey($Program.PackageID)) {
        $ParentPackage = $PackageLookup[$Program.PackageID]
    }

    if ($PackageLookup.ContainsKey($DependencyPackageID)) {
        $DependencyPackage = $PackageLookup[$DependencyPackageID]
    }


    [PSCustomObject]@{

        # Program that requires the dependency
        ParentPackageID       = $Program.PackageID

        ParentPackageName     = if ($ParentPackage) {
                                    $ParentPackage.Name
                                }

        ParentProgramName     = $Program.ProgramName


        # Required dependency
        DependencyPackageID   = $DependencyPackageID

        DependencyPackageName = if ($DependencyPackage) {
                                    $DependencyPackage.Name
                                }
                                else {
                                    "[Package not found]"
                                }

        DependencyProgramName = $DependencyProgram

        DependencyContentSource = if ($DependencyPackage) {
                                      $DependencyPackage.PkgSourcePath
                                  }

        DependencySourceDate = if ($DependencyPackage) {
                                   Convert-ToReadableDate `
                                       $DependencyPackage.SourceDate
                               }

        DependencyManufacturer = if ($DependencyPackage) {
                                     $DependencyPackage.Manufacturer
                                 }

        DependencyVersion = if ($DependencyPackage) {
                                $DependencyPackage.Version
                            }

        DependencyExists = [bool]$DependencyPackage

        RawDependencyValue = $Program.DependentProgram
    }
}


# ============================================================================
# EXPORT REPORTS
# ============================================================================

Write-Host ""
Write-Host "Exporting CSV reports..." -ForegroundColor Cyan


$UndeployedFile = Join-Path `
    $ExportPath `
    "01_UndeployedPackages.csv"

$EmptyCollectionFile = Join-Path `
    $ExportPath `
    "02_DeployedPackages_EmptyCollections.csv"

$TaskSequenceFile = Join-Path `
    $ExportPath `
    "03_Packages_In_TaskSequences.csv"

$DependencyFile = Join-Path `
    $ExportPath `
    "04_Package_Dependencies.csv"

$MasterFile = Join-Path `
    $ExportPath `
    "05_AllPackages_Master.csv"


$UndeployedPackages |
    Export-Csv `
        -Path $UndeployedFile `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Delimiter $Delimiter


$EmptyCollectionReport |
    Sort-Object PackageName, CollectionName |
    Export-Csv `
        -Path $EmptyCollectionFile `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Delimiter $Delimiter


$TaskSequencePackageReport |
    Sort-Object PackageName, TaskSequenceName |
    Export-Csv `
        -Path $TaskSequenceFile `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Delimiter $Delimiter


$DependencyReport |
    Sort-Object DependencyPackageName, ParentPackageName |
    Export-Csv `
        -Path $DependencyFile `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Delimiter $Delimiter


$MasterReport |
    Sort-Object PackageName |
    Export-Csv `
        -Path $MasterFile `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Delimiter $Delimiter


# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " SCCM PACKAGE AUDIT COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Total packages                 : $($Packages.Count)"
Write-Host "Undeployed packages            : $($UndeployedPackages.Count)"
Write-Host "Empty collection deployments   : $($EmptyCollectionReport.Count)"
Write-Host "Task Sequence package refs     : $($TaskSequencePackageReport.Count)"
Write-Host "Program dependencies           : $($DependencyReport.Count)"

Write-Host ""
Write-Host "Reports:" -ForegroundColor Cyan
Write-Host "  $UndeployedFile"
Write-Host "  $EmptyCollectionFile"
Write-Host "  $TaskSequenceFile"
Write-Host "  $DependencyFile"
Write-Host "  $MasterFile"

Write-Host ""


# ============================================================================
# CLEANUP
# ============================================================================

if ($CimSession) {
    Remove-CimSession $CimSession
}

Write-Host "Finished." -ForegroundColor Green
