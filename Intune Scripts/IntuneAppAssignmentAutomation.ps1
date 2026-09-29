#--------------------------------------------------------------------------------------
# Script: IntuneAppAssignmentAutomation.ps1
# Author: Siconic
# Date: 7/14/2025
# Modified: 9/29/2026
# Last Modified by: Siconic
#
# Version: 4.0.0
#
# Pre-Requisites: Requires MS Graph. To install: Install-Module Microsoft.Graph -Force
#
# CSV Format: Required headers: AppName, GroupName
#             Optional headers:
#               OwnerID - the app's Owner value in Intune. When blank, the app is found
#                         by display name only.
#               Intent  - required when $CSVIntent is $true. One of: required,
#                         available, uninstall, availableWithoutEnrollment
#             GroupName can hold several groups separated by commas.
#             Data must match what is in Intune. If a name is wrong, the app or group
#             is not found.
#
# Output: AppAssignments-<OwnerID>-<timestamp>-SV<version>.csv in Documents. One row
#         per app and group. Use it as the input of RemoveAppAssignment.ps1 to roll
#         back the assignments this script created.
#
# 2.0.1 - Added option for assignment group removal
# 2.1.0 - Made the intent automated for persoanl use
# 2.2.0 - Added more robust try/catch blocks
# 2.3.0 - Added $CSVIntent to allow for quick changing between CSV App Assignment
#         Intentand Default behavior of "Available"
# 3.0.0 - Added multiple entry for assignment name column.
# 4.0.0 - Output: exactly one row per app and group (rows were lost or duplicated
#         for multi-group rows, and values from the previous row could carry over).
#         Output column ScopeTag renamed to Owner (the value is the app's Owner
#         property, not a scope tag). New columns Removed and RemovedAssignmentID in
#         both modes.
#         Removal mode: the old group's assignment is now found and removed (before,
#         the assignment ID was always empty and every removal failed). Removal runs
#         once per app, only when the app has an assignment to one of the listed
#         groups, and asks for confirmation. The removal group is looked up once
#         before any change.
#         Existing assignments are matched on the target group ID instead of a
#         shortened assignment ID. Apps or groups with more than one match are
#         skipped. Apostrophes in names are escaped in Graph filters. The CSV columns
#         and the Intent values are checked. Y/N prompts ask again on other answers.
#         Corrected error messages.
#---------------------------------------------------------------------------------------
$scriptver = "4_0_0"


#Tenant Variables for GraphAPI to connect
$TenantId = ""
$ClientId = ""

# Allow assignment intent to be set by CSV data? If set to false, default for all apps will be available.
$CSVIntent = $true

$ValidIntents = @('required', 'available', 'uninstall', 'availableWithoutEnrollment')

# Result rows for the output CSV
$script:results = [System.Collections.Generic.List[object]]::new()
$script:OwnerId = ""

#region Functions
Function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default,
        [string]$Color = 'Yellow'
    )
    while ($true) {
        Write-Host $Prompt -ForegroundColor $Color -NoNewline
        $answer = "$(Read-Host)".Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -eq 'y' -or $answer -eq 'yes') { return $true }
        if ($answer -eq 'n' -or $answer -eq 'no') { return $false }
        Write-Host "Please answer Y or N." -ForegroundColor Red
    }
}

# Doubles apostrophes so a name can be used inside a quoted OData filter value
Function ConvertTo-ODataString {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

Function Find-IntuneApp {
    param([string]$Name, [string]$Owner)
    $filter = "displayName eq '$(ConvertTo-ODataString $Name)'"
    if (-not [string]::IsNullOrWhiteSpace($Owner)) {
        $filter = "$($filter) and Owner eq '$(ConvertTo-ODataString $Owner)'"
    }
    return @(Get-MgDeviceAppManagementMobileApp -Filter $filter)
}

Function Find-EntraGroup {
    param([string]$Name)
    return @(Get-MgGroup -Filter "displayName eq '$(ConvertTo-ODataString $Name)'")
}

# Returns the group ID an app assignment targets
Function Get-AssignmentGroupId {
    param($Assignment)
    $groupId = $null
    $properties = $null
    if ($Assignment.Target) { $properties = $Assignment.Target.AdditionalProperties }
    if ($properties -and $properties.ContainsKey('groupId')) {
        $groupId = "$($properties['groupId'])"
    }
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        # Fallback: assignment IDs have the form <groupId>_<n>_<n>
        $groupId = ("$($Assignment.Id)" -split '_')[0]
    }
    return $groupId
}

# Returns the intent for a CSV row, in the casing Graph expects, or $null if invalid
Function Get-AssignmentIntent {
    param($Row)
    if (-not $CSVIntent) { return 'available' }
    $value = "$($Row.Intent)".Trim()
    foreach ($intent in $ValidIntents) {
        if ($intent -eq $value) { return $intent }
    }
    return $null
}

Function New-ResultRow {
    param(
        [string]$AppName,
        [string]$AppId = "",
        [string]$GroupName,
        [string]$GroupId = "",
        [string]$Owner,
        [string]$Assigned,
        [string]$AssignmentId = "",
        [string]$ErrorMessage = ""
    )
    $link = ""
    if (-not [string]::IsNullOrWhiteSpace($AppId)) {
        $link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($AppId)"
    }
    return [PSCustomObject]@{
        AppName             = $AppName
        AppID               = $AppId
        GroupName           = $GroupName
        GroupID             = $GroupId
        Owner               = $Owner
        Assigned            = $Assigned
        Removed             = ""
        RemovedAssignmentID = ""
        Link                = $link
        AssignmentID        = $AssignmentId
        ErrorMessage        = $ErrorMessage
    }
}

# Assigns one CSV row's app to each of its groups. Returns the result rows and the
# data the removal step needs.
Function Invoke-AppAssignment {
    param($Row)

    $appName = "$($Row.AppName)".Trim()
    $ownerId = "$($Row.OwnerID)".Trim()
    $groupNames = @("$($Row.GroupName)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $assignmentIntent = Get-AssignmentIntent -Row $Row

    $outcome = [PSCustomObject]@{
        App                 = $null
        ExistingAssignments = @()
        TargetGroupIds      = [System.Collections.Generic.List[string]]::new()
        HasTargetAssignment = $false
        Rows                = [System.Collections.Generic.List[object]]::new()
    }

    if ($groupNames.Count -eq 0) {
        Write-Host "`n`nApp '$appName' has no group name in the CSV. Skipping." -ForegroundColor Yellow
        $outcome.Rows.Add((New-ResultRow -AppName $appName -GroupName "" -Owner $ownerId -Assigned "Not Assigned - No Group Name"))
        return $outcome
    }

    if ($null -eq $assignmentIntent) {
        Write-Host "`n`nApp '$appName' has the intent '$($Row.Intent)', which is not valid. Skipping." -ForegroundColor Yellow
        foreach ($gName in $groupNames) {
            $outcome.Rows.Add((New-ResultRow -AppName $appName -GroupName $gName -Owner $ownerId -Assigned "Not Assigned - Invalid Intent" `
                -ErrorMessage "Intent '$($Row.Intent)' is not one of: $($ValidIntents -join ', ')"))
        }
        return $outcome
    }

    # Get the Intune app
    $apps = @(Find-IntuneApp -Name $appName -Owner $ownerId)

    if ($apps.Count -eq 0) {
        Write-Host "`n`nApp '$appName' not found in Intune. Skipping." -ForegroundColor Yellow
        foreach ($gName in $groupNames) {
            $outcome.Rows.Add((New-ResultRow -AppName $appName -GroupName $gName -Owner $ownerId -Assigned "Not Assigned - App not Found"))
        }
        return $outcome
    }

    if ($apps.Count -gt 1) {
        Write-Host "`n`n$($apps.Count) apps named '$appName' found in Intune. Skipping." -ForegroundColor Yellow
        foreach ($gName in $groupNames) {
            $outcome.Rows.Add((New-ResultRow -AppName $appName -GroupName $gName -Owner $ownerId -Assigned "Not Assigned - Multiple Apps Found" `
                -ErrorMessage "Matching app IDs: $(@($apps | ForEach-Object { $_.Id }) -join ', ')"))
        }
        return $outcome
    }

    $app = $apps[0]
    $outcome.App = $app
    $outcome.ExistingAssignments = @(Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id)
    # Assignments created in this run, so a group listed twice is not assigned twice
    $createdAssignments = [System.Collections.Generic.List[object]]::new()

    foreach ($gName in $groupNames) {
        Write-Host "`n`nProcessing assignment: App '$appName' to Group '$gName' with Owner '$ownerId'" -ForegroundColor Green

        # Get the Entra ID group
        $groups = @(Find-EntraGroup -Name $gName)

        if ($groups.Count -eq 0) {
            Write-Host "Group '$gName' not found in Entra ID. Skipping." -ForegroundColor Yellow
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -Owner $ownerId -Assigned "Not Assigned - Group not Found"))
            continue
        }

        if ($groups.Count -gt 1) {
            Write-Host "$($groups.Count) groups named '$gName' found in Entra ID. Skipping." -ForegroundColor Yellow
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -Owner $ownerId -Assigned "Not Assigned - Multiple Groups Found" `
                -ErrorMessage "Matching group IDs: $(@($groups | ForEach-Object { $_.Id }) -join ', ')"))
            continue
        }

        $group = $groups[0]
        $outcome.TargetGroupIds.Add($group.Id)

        # Check if an assignment for this app and group already exists
        $existingAssignment = $null
        foreach ($candidate in @($outcome.ExistingAssignments) + @($createdAssignments)) {
            if ((Get-AssignmentGroupId -Assignment $candidate) -eq $group.Id) {
                $existingAssignment = $candidate
                break
            }
        }

        if ($existingAssignment) {
            Write-Host "Assignment for App '$appName' to Group '$gName' already exists. Skipping." -ForegroundColor Yellow
            $outcome.HasTargetAssignment = $true
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -GroupId $group.Id -Owner $ownerId `
                -Assigned "Not Assigned - Already has Assignment" -AssignmentId $existingAssignment.Id))
            continue
        }

        if (-not (Read-YesNo -Prompt "You are about to assign '$appName' to Group '$gName' with intent '$assignmentIntent'. Are you sure? (Y/n): " -Default $true)) {
            Write-Host "Skipping app assignment." -ForegroundColor Yellow
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -GroupId $group.Id -Owner $ownerId -Assigned "Not Assigned - User Skipped"))
            continue
        }

        # Create the assignment object for the Graph API
        $mobileAppAssignment = @{
            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
            "intent"      = $assignmentIntent
            "target"      = @{
                "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                "groupId"     = $group.Id
            }
        }

        try {
            $newAssignment = New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id -BodyParameter $mobileAppAssignment -ErrorAction Stop
            Write-Host "Successfully assigned App '$appName' to Group '$gName' with intent '$assignmentIntent'." -ForegroundColor Cyan
            $createdAssignments.Add($newAssignment)
            $outcome.HasTargetAssignment = $true
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -GroupId $group.Id -Owner $ownerId `
                -Assigned "Assigned - $($assignmentIntent)" -AssignmentId $newAssignment.Id))
        }
        catch {
            $errorMessage = "$($_.Exception.Message)"
            Write-Host "Failed to assign App '$appName' to Group '$gName'. Error: $errorMessage" -ForegroundColor Red
            $outcome.Rows.Add((New-ResultRow -AppName $appName -AppId $app.Id -GroupName $gName -GroupId $group.Id -Owner $ownerId `
                -Assigned "Not Assigned - Error" -ErrorMessage $errorMessage))
        }
    }

    return $outcome
}

# Removes the assignment of $RemoveGroup from the app in $Outcome. Returns the status.
Function Invoke-AssignmentRemoval {
    param($Outcome, $RemoveGroup)

    $removal = [PSCustomObject]@{
        Status       = "No assignments removed"
        AssignmentId = ""
        ErrorMessage = ""
    }

    if ($null -eq $Outcome.App) { return $removal }
    $appName = $Outcome.App.DisplayName

    $oldAssignment = $null
    foreach ($candidate in @($Outcome.ExistingAssignments)) {
        if ((Get-AssignmentGroupId -Assignment $candidate) -eq $RemoveGroup.Id) {
            $oldAssignment = $candidate
            break
        }
    }

    if (-not $oldAssignment) {
        Write-Host "App '$appName' has no assignment for '$($RemoveGroup.DisplayName)'. Nothing removed." -ForegroundColor Yellow
        $removal.Status = "No assignments removed - '$($RemoveGroup.DisplayName)' not assigned"
        return $removal
    }

    if ($Outcome.TargetGroupIds.Contains($RemoveGroup.Id)) {
        Write-Host "'$($RemoveGroup.DisplayName)' is also listed as a group to assign for '$appName'. Nothing removed." -ForegroundColor Yellow
        $removal.Status = "No assignments removed - group is also an assignment target"
        return $removal
    }

    if (-not $Outcome.HasTargetAssignment) {
        Write-Host "App '$appName' has no assignment to the listed groups, so '$($RemoveGroup.DisplayName)' is kept." -ForegroundColor Yellow
        $removal.Status = "No assignments removed - no assignment to the listed groups"
        return $removal
    }

    if (-not (Read-YesNo -Prompt "You are about to remove the '$($RemoveGroup.DisplayName)' assignment from '$appName'. Are you sure? (Y/n): " -Default $true)) {
        Write-Host "Skipping assignment removal." -ForegroundColor Yellow
        $removal.Status = "No assignments removed - User Skipped"
        return $removal
    }

    try {
        Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $Outcome.App.Id -MobileAppAssignmentId $oldAssignment.Id -Confirm:$false -ErrorAction Stop
        Write-Host "Successfully removed app assignment for '$($RemoveGroup.DisplayName)'." -ForegroundColor Cyan
        $removal.Status = "Removed '$($RemoveGroup.DisplayName)'"
        $removal.AssignmentId = $oldAssignment.Id
    }
    catch {
        $removal.ErrorMessage = "$($_.Exception.Message)"
        Write-Host "Failed to remove the '$($RemoveGroup.DisplayName)' assignment from '$appName'. Error: $($removal.ErrorMessage)" -ForegroundColor Red
        $removal.Status = "Not Removed - Error"
    }
    return $removal
}

# Processes every CSV row. $RemoveGroup is $null when no assignment is removed.
Function Invoke-AssignmentAutomation {
    param($RemoveGroup)

    foreach ($assignment in $appAssignments) {
        $script:OwnerId = "$($assignment.OwnerID)".Trim()
        $outcome = Invoke-AppAssignment -Row $assignment

        if ($null -ne $RemoveGroup) {
            $removal = Invoke-AssignmentRemoval -Outcome $outcome -RemoveGroup $RemoveGroup
            foreach ($row in $outcome.Rows) {
                $row.Removed = $removal.Status
                $row.RemovedAssignmentID = $removal.AssignmentId
                if ($removal.ErrorMessage) {
                    if ($row.ErrorMessage) {
                        $row.ErrorMessage = "$($row.ErrorMessage); Removal: $($removal.ErrorMessage)"
                    }
                    else {
                        $row.ErrorMessage = "Removal: $($removal.ErrorMessage)"
                    }
                }
            }
        }

        foreach ($row in $outcome.Rows) { $script:results.Add($row) }
    }
}
#endRegion Functions

#region Main Body
# Path to your CSV file
Write-Host "Enter CSV path to read from: " -ForegroundColor Cyan -NoNewline
$csvFilePath = "$(Read-Host)".Trim().Trim('"')

# Import the CSV file
$appAssignments = @(Import-Csv -Path $csvFilePath -ErrorAction Stop)

if ($appAssignments.Count -eq 0) {
    Write-Host "The CSV file has no rows. Nothing was changed." -ForegroundColor Red
    return
}

$requiredColumns = @('AppName', 'GroupName')
if ($CSVIntent) { $requiredColumns += 'Intent' }
$csvColumns = @($appAssignments[0].PSObject.Properties.Name)
$missingColumns = @($requiredColumns | Where-Object { $csvColumns -notcontains $_ })
if ($missingColumns.Count -gt 0) {
    Write-Host "The CSV file is missing the column(s): $($missingColumns -join ', '). Nothing was changed." -ForegroundColor Red
    return
}

$removeExisting = Read-YesNo -Prompt "Would you like to remove any existing app assignments? (y/N): " -Default $false -Color Cyan

# GraphAPI connection establishment
Connect-MgGraph -NoWelcome -TenantId $TenantId -ClientID $ClientID #-NoWelcome -ClientSecretCredential $credential -TenantId $TenantId #-Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"

$removeGroup = $null
if ($removeExisting) {
    Write-Host "What is the name of the assignment group to remove?: " -ForegroundColor Cyan -NoNewline
    $removeGroupName = "$(Read-Host)".Trim()
    $removeGroups = @(Find-EntraGroup -Name $removeGroupName)
    if ($removeGroups.Count -ne 1) {
        Write-Host "Found $($removeGroups.Count) groups named '$removeGroupName' in Entra ID; exactly one is required. Nothing was changed." -ForegroundColor Red
        Disconnect-MgGraph -InformationAction SilentlyContinue
        return
    }
    $removeGroup = $removeGroups[0]
}

Invoke-AssignmentAutomation -RemoveGroup $removeGroup

$SV = "SV" + $scriptver
$DateTS = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csvName = "AppAssignments-" + $script:OwnerId + "-" + $DateTS + "-" + $SV + ".csv"
$csvPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath $csvName

$script:results | Export-CSV -Path $csvPath -NoTypeInformation
Write-Host "`nResults written to $csvPath" -ForegroundColor Cyan

# Disconnect from Microsoft Graph
Disconnect-MgGraph -InformationAction SilentlyContinue
#endregion Main Body
