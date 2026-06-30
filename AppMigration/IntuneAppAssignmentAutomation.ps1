#--------------------------------------------------------------------------------------
# Script: AppAssignmentAutomation.ps1
# Author: Earl Estrada 
# Date: 7/14/2025
# Modified: 7/25/2025
# Last Modified by: Earl Estrada
#
# Version: 2.0.2
#
# Pre-Requisits: Requires MS Graph. To install: Install-Module Microsoft.Graph -Force
# 
# CSV Format: CSV should have headers labeled: AppName GroupName OwnerID
#             Data must match what is in Intune for best results. If your import names 
#             are wrong, the app wont be found.
#
# 2.0.1 - Added option for assignment group removal
# 2.1.0 - Made the intent automated for persoanl use
# 2.2.0 - Added more robust try/catch blocks
# 2.3.0 - Added $CSVIntent to allow for quick changing between CSV App Assignment 
#         Intentand Default behavior of "Available"
# 3.0.0 - Added multiple entry for assignment name column.
#---------------------------------------------------------------------------------------
$scriptver = "3_0_0"


#Tenant Variables for GraphAPI to connect
$TenantId = ""
$ClientId = ""

# Allow assignment intent to be set by CSV data? If set to false, default for all apps will be available.
$CSVIntent = $true

# initialize array
$global:results = @() 

#region Functions
Function Invoke-AssignmentAutomation {
    foreach ($assignment in $appAssignments) {
        $appName = $assignment.AppName
        #$groupName = $assignment.GroupName -split ","
        $Script:ownerid = $assignment.OwnerID
        foreach ($gname in ($Assignment.GroupName -Split ',')) {
            $gname = $gname.Trim()
            If ($CSVIntent -eq $true) {
                $AssignmentIntent = $assignment.Intent
            }
            ElseIf ($CSVIntent -eq $False) {
                $AssignmentIntent = "available"
            }

            Write-Host "`n`nProcessing assignment: App '$appName' to Group '$gName' with ScopeTag '$ownerID'" -ForegroundColor Green

            # Get the Intune app
            $app = Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '$appName' and Owner eq '$ownerId'"

            if (-not $app) {
                Write-Host "App '$appName' not found in Intune. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - App not Found"
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = ""
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Link = ""
                    AssignmentID = ""
                    ErrorMessage = ""
                }
                $Script:results += $obj # Adds objects to array
                continue
            }

            # Get the Azure AD group
            $group = Get-MgGroup -Filter "displayName eq '$gName'"

            if (-not $group) {
                Write-Host "Group '$gName' not found in Azure AD. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - Group not Found"
                $AppID = $App.id
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = $appID
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
                    AssignmentID = ""
                    ErrorMessage = ""
                }
                $script:results += $obj # Adds objects to array
                continue
            }

            # Create the assignment object for the Graph API
            $mobileAppAssignment = @{
                "@odata.type" = "#microsoft.graph.mobileAppAssignment"
                "intent" = $assignmentIntent
                "target" = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    "groupId" = $group.Id
                }
            }   

            # Check if an assignment for this app and group already exists
            $existingAssignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id
            $assignmentExists = $false
        
            foreach ($existingAssignment in $existingAssignments) {
                $oldID = $ExistingAssignment.ID
                $TrimmedID = $oldID.Substring(0, $OldID.Length - 4)       
                if ($TrimmedID -eq $group.Id) {
                    $assignmentExists = $true
                    break
                }
            }

            if ($assignmentExists) {
                Write-Host "Assignment for App '$appName' to Group '$gName' already exists. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - Already has Assignment"
                $AppID = $App.ID
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = ""
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
                    AssignmentID = $ExistingAssignment.ID
                    ErrorMessage = ""
                }
                $script:results += $obj # Adds objects to array
                continue
            }
        
            elseif (-not $assignmentExists -and $group -and $app) {
                # Assign the app to the group
                $ErrorMessage = ""
                $AppID = $App.ID
                try {
                    Write-Host "You are about to assign '$appName' to Group '$gName' with intent '$assignmentIntent'. Are you sure? (Y/n)" -ForegroundColor Yellow -NoNewline
                    $confirmAssignment = Read-Host 
                    if ([string]::IsNullOrWhiteSpace($confirmAssignment) -or $confirmAssignment -eq 'Y') {
                        try {
                            $NewAppAssignID = New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id -BodyParameter $mobileAppAssignment -Erroraction stop
                            Write-Host "Successfully assigned App '$appName' to Group '$gName' with intent '$assignmentIntent'." -ForegroundColor Cyan
                            $AppAssignStatus = "Assigned - " + $AssignmentIntent 
                            }
                        catch {
                            $ErrorMessage = "$($_.Exception.Message)"
                            Write-Error "Failed to remove mobile app assignment. Error: $ErrorMessage"
                            $AppAssignStatus = "Not Assigned/Removed - Error"
                            }
                        }
                    else {
                        Write-Host "Skipping app assignment." -ForegroundColor Yellow
                        $AppAssignStatus = "Not Assigned - User Skipped"
                        }
                }
                catch {
                    Write-Error "Error assigning App '$appName' to Group '$gName': $($_.Exception.Message)" -ForegroundColor Red
                    $AppAssignStatus = "Not Assigned - Error During Assignment"
                } 
            }
        }    
        
        $obj = [PSCustomObject]@{
            AppName = $appName
            AppID = $app.id
            GroupName = $gName
            GroupID = $group.Id
            ScopeTag = $ownerID
            Assigned = $AppAssignStatus
            Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
            AssignmentID = $NewAppAssignID.Id
            ErrorMessage = $ErrorMessage
        }
	
        $Script:results += $obj # Adds objects to array
    }
}

Function Invoke-AssignmentRemovalAutomation {
    foreach ($assignment in $appAssignments) {
        $appName = $assignment.AppName
        #$groupName = $assignment.GroupName
        $script:ownerid = $assignment.OwnerID
        $RemoveAssignmentGroup = $RemoveAssignmentGroupName

        foreach ($gname in ($Assignment.GroupName -Split ',')) {
            $gname = $gname.Trim()
            If ($CSVIntent -eq $true) {
                $AssignmentIntent = $assignment.Intent
            }
            ElseIf ($CSVIntent -eq $False) {
                $AssignmentIntent = "available"
            }
            
            Write-Host "`n`nProcessing assignment: App '$appName' to Group '$gName' with ScopeTag '$ownerID'" -ForegroundColor Green

            # Get the Intune app
            $app = Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '$appName' and Owner eq '$ownerId'"

            if (-not $app) {
                Write-Host "App '$appName' not found in Intune. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - App not Found"
                $AppRemovedStatus = "No assignments removed"
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = ""
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Removed = $AppRemovedStatus
                    Link = ""
                    AssignmentID = ""
                    ErrorMessage = ""
                }
                $results += $obj # Adds objects to array
                continue
            }

            # Get the Azure AD group
            $group = Get-MgGroup -Filter "displayName eq '$gName'"
            $remGroup = Get-MgGroup -Filter "displayName eq '$RemoveAssignmentGroup'"

            if (-not $group) {
                Write-Host "Group '$gName' not found in Azure AD. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - Group not Found"
                $AppRemovedStatus = "No assignments removed"
                $AppID = $App.id
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = $appID
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Removed = $AppRemovedStatus
                    Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
                    AssignmentID = ""
                    ErrorMessage = ""
                }
                $script:results += $obj # Adds objects to array
                continue
            }

            # Create the assignment object for the Graph API
            $mobileAppAssignment = @{
                "@odata.type" = "#microsoft.graph.mobileAppAssignment"
                "intent" = $assignmentIntent
                "target" = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    "groupId" = $group.Id
                }
            }   

            # Check if an assignment for this app and group already exists
            $existingAssignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id
            $assignmentExists = $false
        
            foreach ($existingAssignment in $existingAssignments) {
                $oldID = $ExistingAssignment.ID
                $TrimmedID = $oldID.Substring(0, $OldID.Length - 4)       
                if ($TrimmedID -eq $group.Id) {
                    $assignmentExists = $true
                }
                if ($TrimmedID -eq $remgroup.id) {
                    $RemAssignmentID = $oldID1
                    }
            }

    <#       foreach ($existingAssignment1 in $existingAssignments) {
                $oldID1 = $ExistingAssignment1.ID
                $global:TrimmedID1 = $oldID1.Substring(0, $OldID1.Length - 4)       
                if ($TrimmedID1 -eq $remgroup.Id) {
                    $global:RemAssignmentID = $oldID1
                    break
                }
            }
    #>
            if ($assignmentExists) {
                Write-Host "Assignment for App '$appName' to Group '$gName' already exists. Skipping." -ForegroundColor Yellow
                $AppAssignStatus = "Not Assigned - Already has Assignment"
                $AppRemovedStatus = "No assignments removed"
                $AppID = $App.ID
                $obj = [PSCustomObject]@{
                    AppName = $appName
                    AppID = ""
                    GroupName = $gName
                    GroupID = ""
                    ScopeTag = $ownerID
                    Assigned = $AppAssignStatus
                    Removed = $AppRemovedStatus
                    Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
                    AssignmentID = $ExistingAssignment.ID
                    ErrorMessage = ""
                }
                $script:results += $obj # Adds objects to array
            }

            if (-not $assignmentExists -and $group -and $app) {
                    # Assign the app to the group
                    $errorMessage = ""
                    $AppID = $App.ID
                    try {
                        Write-Host "You are about to assign '$appName' to Group '$gName' with intent '$assignmentIntent'." -ForegroundColor Yellow
                        Write-Host "You are also about to remove the '$RemoveAssignmentGroup' app assignment from '$appname'." -ForegroundColor Yellow
                        Write-Host "Are you sure? (Y/n): " -ForegroundColor Yellow -NoNewline
                        $confirmAssignment = Read-Host
                        if ([string]::IsNullOrWhiteSpace($confirmAssignment) -or $confirmAssignment -eq 'Y') {
                            try {
                                $NewAppAssignID = New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppID -BodyParameter $mobileAppAssignment -ErrorAction stop
                                Write-Host "Successfully assigned App '$appName' to Group '$gName' with intent '$assignmentIntent'" -ForegroundColor Cyan
                                $AppAssignStatus = "Assigned - " + $AssignmentIntent
                                Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $AppID -MobileAppAssignmentId $RemAssignmentID -Confirm:$false  -ErrorAction stop
                                Write-Host "Successfully removed app assignment for '$RemoveAssignmentGroup'." -ForegroundColor Cyan
                                $AppRemovedStatus = "Removed '$RemoveAssignmentGroup'"
                                }
                            Catch {
                                $ErrorMessage = "$($_.Exception.Message)"
                                Write-Error "Failed to remove mobile app assignment. Error: $ErrorMessage"
                                $AppAssignStatus = "Not Assigned/Removed - Error"
                                }
                            }
                        else {
                            Write-Host "Skipping app assignment." -ForegroundColor Yellow
                            $AppAssignStatus = "Not Assigned - User Skipped"
                            $AppRemovedStatus = "No assignments removed"
                            }
                    }
                    catch {
                        Write-Error "Error assigning App '$appName' to Group '$gName': $($_.Exception.Message)"
                        $AppAssignStatus = "Not Assigned - Error During Assignment"
                        $AppRemovedStatus = "No assignments removed"
                    } 
            }
            
            if ($assignmentExists -and $group -and $app) {
                    Try {
                        Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $App.ID -MobileAppAssignmentId $RemAssignmentID -Confirm:$false -ErrorAction Stop
                        Write-Host "Successfully removed app assignment for '$RemoveAssignmentGroup'." -ForegroundColor Cyan
                        $AppRemovedStatus = "Removed '$RemoveAssignmentGroup'"
                        }
                    Catch {
                        Write-Host "Assignment group $RemoveAssignmentGroup not found. Skipping." -ForegroundColor Red
                        $AppRemovedStatus = "No assignments removed"
                        }
                    }
        }

        $obj = [PSCustomObject]@{
            AppName = $appName
            AppID = $app.id
            GroupName = $gName
            GroupID = $group.Id
            ScopeTag = $ownerID
            Assigned = $AppAssignStatus
            Removed = $AppRemovedStatus
            Link = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppID"
            AssignmentID = $NewAppAssignID.Id
            ErrorMessage = $ErrorMessage
        }
	
        $script:results += $obj # Adds objects to array
    }
}
#endRegion Functions

#region Main Body
# Path to your CSV file
Write-Host "Enter CSV path to read from: " -ForegroundColor Cyan -NoNewline
$csvFilePath = Read-Host
$csvFilePath = $csvFilePath.Trim('"')

# Import the CSV file
$appAssignments = Import-Csv -Path $csvFilePath

# 
Write-Host "Would you like to remove any existing app assignments?(y/N): " -ForegroundColor Cyan -NoNewline
$confirmRemoveAssignment = Read-Host 

if ([string]::IsNullOrWhiteSpace($confirmRemoveAssignment) -or $confirmRemoveAssignment -eq 'N') {
    # GraphAPI connection establishment
    Connect-MgGraph -NoWelcome -TenantId $TenantId -ClientID $ClientID #-NoWelcome -ClientSecretCredential $credential -TenantId $TenantId #-Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"

    Invoke-AssignmentAutomation
}

ElseIf ($confirmRemoveAssignment -eq 'Y') {
    # GraphAPI connection establishment
    Connect-MgGraph -NoWelcome -TenantId $TenantId -ClientID $ClientID #-NoWelcome -ClientSecretCredential $credential -TenantId $TenantId #-Scopes "DeviceManagementApps.ReadWrite.All", "Group.Read.All"

    Write-Host "What is the name of the assignment group?: " -ForegroundColor Cyan -NoNewline
    $Global:RemoveAssignmentGroupName = Read-Host
    Invoke-AssignmentRemovalAutomation
}

$SV = "SV" + $scriptver
$DateTS = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csvName = "AppAssignments-" + $OwnerID + "-" + $DateTS + "-" + $SV + ".csv"
$csvPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath $csvName

$results | Export-CSV -Path $csvPath -NoTypeInformation

# Disconnect from Microsoft Graph
Disconnect-MgGraph -InformationAction SilentlyContinue
#endregion Main Body
