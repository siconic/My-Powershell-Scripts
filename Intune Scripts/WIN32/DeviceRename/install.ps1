# Check if the folder exists and create folder

$Folders =@(
        "C:\ProgramData\COMPANY"
        "C:\ProgramData\COMPANY\RenameHost"
        "C:\ProgramData\COMPANY\Log"
        )

         foreach ($LogFolder in $Folders)
         {
            if(!(Test-Path -Path $LogFolder))
            {
              New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
              Write-Output "Folder '$LogFolder' created successfully."
            }

            else 
            {
                Write-Output "Folder '$LogFolder' already exists. No action taken."
                
            }
           
         }
$LogPath = "C:\ProgramData\COMPANY\Log\RenameInstall.log"

# Start logging
Start-Transcript -Path $LogPath -Append

# Copy the XML file
Copy-Item ".\RenameHost.xml" "C:\ProgramData\COMPANY\RenameHost\"

# Copy the ps1 file
Copy-Item ".\RenameComputer.ps1" "C:\ProgramData\COMPANY\RenameHost\"

# Copy the ps1 file
Copy-Item ".\ServiceUI.exe" "C:\ProgramData\COMPANY\RenameHost\"

Write-Output "renamehost.xml, renamecomputer.ps1 and ServiceUI.exe are copied successfully C:\ProgramData\COMPANY\RenameHost\"


Write-Output "Creating a task Scheduler for Host Rename"

# Register a new Scheduled Task using the XML
Register-ScheduledTask -xml (Get-Content C:\ProgramData\COMPANY\RenameHost\RenameHost.xml | Out-String) -TaskName "RenameHost" -TaskPath "\" -User system

Write-Output "Triggering Task Scheduler"

Start-ScheduledTask -TaskName "RenameHost"

# Stop logging
Stop-Transcript
