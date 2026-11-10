#------------------------------------------------------------------------------------
# Script: RemoveAppAssignment.ps1
# Author: Siconic
# Date: 7/14/2025
# Modified: 9/29/2026
# Last Modified by: Siconic
#
# Version: 2.0.0
#
# Pre-Requisites: Requires MS Graph. To install: Install-Module Microsoft.Graph -Force
#
# Usage: Rolls back assignments made by IntuneAppAssignmentAutomation.ps1. The input
#        is that script's output CSV. Only rows whose Assigned value starts with
#        "Assigned" (for example "Assigned - required") and that have an AppID and an
#        AssignmentID are removed. Assignments that the other script's removal mode
#        deleted (column RemovedAssignmentID) are not restored by this script.
#
# 1.0.0 - Initial Creation
# 1.0.1 - Added Logging via CSV Output and user CSV Input
# 1.0.2 - Added Try/Catch block with error collection
# 1.0.3 - Added Script information and versioning
# 2.0.0 - Rows written by IntuneAppAssignmentAutomation.ps1 ("Assigned - <intent>")
#         are now recognized; before, no row matched and nothing was removed.
#         Removal errors are now caught; before, the status was "Removed" even when
#         the removal failed. Output column ScopeTag renamed to Owner; the input
#         accepts Owner or the old ScopeTag column. Y/N prompts ask again on other
#         answers. The CSV path may be given with quotes.
#-------------------------------------------------------------------------------------
$scriptver = "200"

#Tenant ID Information
$TenantId = ""
$ClientId = ""

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

Connect-MgGraph -NoWelcome -TenantId $TenantId -ClientID $ClientID

# Result rows for the output CSV
$results = [System.Collections.Generic.List[object]]::new()

# Path to your CSV file
Write-Host "Enter Rollback CSV path: " -ForegroundColor Cyan -NoNewline
$csvFilePath = "$(Read-Host)".Trim().Trim('"')

# Import the CSV data
$AppList = @(Import-Csv -Path $csvFilePath -ErrorAction Stop)

# Main Body
# Loop through CSV
foreach ($remove in $AppList) {
    $AppName = $remove.AppName
    $AppID = "$($remove.AppID)".Trim()
    $GroupName = $remove.GroupName
    $GroupID = $remove.GroupID
    # Owner column since IntuneAppAssignmentAutomation.ps1 4.0.0, ScopeTag before
    if ($remove.PSObject.Properties.Name -contains 'Owner') {
        $OwnerID = $remove.Owner
    }
    else {
        $OwnerID = $remove.ScopeTag
    }
    $AppAssignment = "$($remove.AssignmentID)".Trim()
    $ErrorMessage = ""

    # Only rows with an assignment that the assignment script created
    If ("$($remove.Assigned)" -notlike 'Assigned*') {
        Write-Host "`nApp: $($AppName), Group: $($GroupName) was not assigned by the script. Not removed." -ForegroundColor Magenta
        $RemovalStatus = "Not Removed - Not Assigned"
    }
    ElseIf ([string]::IsNullOrWhiteSpace($AppID) -or [string]::IsNullOrWhiteSpace($AppAssignment)) {
        Write-Host "`nApp: $($AppName), Group: $($GroupName) has no AppID or AssignmentID in the CSV. Not removed." -ForegroundColor Magenta
        $RemovalStatus = "Not Removed - No AppID or AssignmentID"
    }
    Else {
        Write-Host "`nProcessing assignment removal for App: $($AppName), Group: $($GroupName)" -ForegroundColor Green

        if (Read-YesNo -Prompt "Are you sure you want to remove this assignment? (Y/n): " -Default $true) {
            Write-Host "Removing assignment $($GroupName) for App: $($AppName)" -ForegroundColor Green
            try {
                Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppID -MobileAppAssignmentId $AppAssignment -Confirm:$false -ErrorAction Stop
                Write-Host "Assignment removed successfully." -ForegroundColor Cyan
                $RemovalStatus = "Removed"
            }
            catch {
                $ErrorMessage = "$($_.Exception.Message)"
                Write-Host "Failed to remove mobile app assignment. Error: $ErrorMessage" -ForegroundColor Red
                $RemovalStatus = "Not Removed - Error"
            }
        }
        Else {
            Write-Host "Assignment for $($AppName) not removed." -ForegroundColor Magenta
            $RemovalStatus = "Not Removed - User Input"
        }
    }

    $link = ""
    if (-not [string]::IsNullOrWhiteSpace($AppID)) {
        $link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($AppID)"
    }

    $results.Add([PSCustomObject]@{
        AppName      = $AppName
        AppID        = $AppID
        GroupName    = $GroupName
        GroupID      = $GroupID
        Owner        = $OwnerID
        Removed      = $RemovalStatus
        Link         = $link
        AssignmentID = $AppAssignment
        ErrorMessage = $ErrorMessage
    })
}

$SV = "SV" + $scriptver
$DateTS = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csvName = "AppRollback-" + $OwnerID + "-" + $DateTS + "-" + $SV +  ".csv"
$csvPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath $csvName

$results | Export-CSV -Path $csvPath -NoTypeInformation
Write-Host "Script execution completed. Results written to $csvPath"

# Disconnect from Microsoft Graph
# Disconnect-MgGraph
