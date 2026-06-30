#------------------------------------------------------------------------------------
# Script: RemoveAppAssigment.ps1
# Author: Earl Estrada 
# Date: 7/14/2025
# Modified: 7/28/2025
# Last Modified by: Earl Estrada
#
# Version: 1.0.3
#
# Pre-Requisits: Requires MS Graph. To install: Install-Module Microsoft.Graph -Force
#
# Usage: To be used with the AppAssigmentAutomation script if rollback is necessary.
# 
# 1.0.0 - Initial Creation
# 1.0.1 - Added Logging via CSV Output and user CSV Input
# 1.0.2 - Added Try/Catch block with error collection
# 1.0.3 - Added Script information and versioning
#-------------------------------------------------------------------------------------
$scriptver = "103"

#Tenant ID Information
$TenantId = ""
$ClientId = ""
Connect-MgGraph -NoWelcome -TenantId $TenantId -ClientID $ClientID 

# initialize array
$results = @() 

# Path to your CSV file
# $csvFilePath = "C:\Temp\AppAssignments.csv"
$csvFilePath = Read-Host "Enter Rollback CSV path (without quotes)"

# Import the CSV data
$AppList = Import-Csv -Path $CsvFilePath

# Main Body
# Loop through CSV
foreach ($remove in $Applist) {
    $AppName = $remove.AppName
    $AppID = $remove.AppID
    $GroupName = $remove.GroupName
    $GroupID = $remove.GroupID
    $OwnerID = $remove.ScopeTag
    $AppAssignment = $remove.AssignmentID
    $ErrorMessage = ""

    #Only runs if it finds a valid assignment
    If ($remove.Assigned -eq "Assigned") {
        Write-Host "`nProcessing assignment removal for App: $($AppName), Group: $($GroupName)" -ForegroundColor Green
        Write-Host "Are you sure you want to remove this assignment (Y/n)?" -ForegroundColor Yellow -NoNewline
        $confirmRemoval = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($confirmRemoval) -or $confirmRemoval -eq 'Y') {
            Write-Host "Removing assignment $($GroupName) for App: $($AppName)" -ForegroundColor Green
            try {
                Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppID -MobileAppAssignmentId $AppAssignment -Confirm:$false -PassThru
                Write-Host "Assignment removed successfully." -ForegroundColor Cyan
                $RemovalStatus = "Removed"
            }
            catch {
                $ErrorMessage = "$($_.Exception.Message)"
                Write-Error "Failed to remove mobile app assignment. Error: $ErrorMessage"
                $RemovalStatus = "Not Removed - Error"
            }
        }
        
        Else {
            Write-Host "`nNo app assignments for $($AppName) not removed." -ForegroundColor Magenta
            $RemovalStatus = "Not Removed - User Input"
        }

        $obj = [PSCustomObject]@{
            AppName = $appName
            AppID = $appID
            GroupName = $groupName
            GroupID = $GroupID
            ScopeTag = $ownerID
            Removed = $RemovalStatus
            Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
            ErrorMessage = $ErrorMessage
        }
	
        $results += $obj # Adds objects to array

        }
    Else {
        Write-Host "`nNo app assignments for $($AppName) not removed." -ForegroundColor Magenta
        $RemovalStatus = "Not Removed - Not Assigned"
        $obj = [PSCustomObject]@{
            AppName = $appName
            AppID = $appID
            GroupName = $groupName
            GroupID = $GroupID
            ScopeTag = $ownerID
            Removed = $RemovalStatus
            Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
            ErrorMessage = $ErrorMessage
        }
	
        $results += $obj # Adds objects to array
    }
}
    
$SV = "SV" + $scriptver
$DateTS = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csvName = "AppRollback-" + $OwnerID + "-" + $DateTS + "-" + $SV +  ".csv"
$csvPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath $csvName

$results | Export-CSV -Path $csvPath -NoTypeInformation
Write-Host "Script execution completed."

# Disconnect from Microsoft Graph
# Disconnect-MgGraph
