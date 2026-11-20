# Renames the computer to a name that the logged-on user types in a dialog.
# Run by the RenameHostCustom scheduled task (as SYSTEM, shown to the user through ServiceUI.exe).
#
# Each run:
#   1. If a name chosen earlier is now active, the task is disabled (finished).
#   2. If a name chosen earlier waits for a restart, the user is asked to restart.
#   3. Otherwise the user is asked for the new name, the name is checked, the user confirms,
#      the computer is renamed and the user is asked to restart.
# If the user cancels, postpones the restart, or the rename fails, the task stays enabled and
# asks again at its next run (every 15 minutes for one day after each logon).

# Settings (OrgName, RequiredPrefix) are read from Settings.psd1 in the same folder as this script.
# Installer.ps1 copies both files to C:\ProgramData\<OrgName>\RenameHostCustom.
# The log goes to the Log folder next to that folder: C:\ProgramData\<OrgName>\Log\RenameCustom.log.

$TaskName = "RenameHostCustom"
$LogFolder = Join-Path (Split-Path $PSScriptRoot -Parent) "Log"
$LogPath = Join-Path $LogFolder "RenameCustom.log"
$RegistryPath = "HKLM:\SOFTWARE\Packages\HostRenameCustom"

# Windows default names that the user may not choose
$DefaultNamePatterns = @('^DESKTOP-', '^LAPTOP-', '^WIN-', '^MININT-')

function Test-HostName
{
    # Returns an empty string when the name is valid, otherwise the reason why it is not valid.
    param(
        [string]$Name,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Name))
    {
        return "Enter a computer name."
    }

    if ($Name.Length -gt 15)
    {
        return "The name has $($Name.Length) characters. The maximum is 15."
    }

    if ($Name -notmatch '^[A-Z0-9-]+$')
    {
        return "Use only the letters A to Z, the digits 0 to 9 and the hyphen (-). No spaces."
    }

    if ($Name -match '^[0-9]+$')
    {
        return "The name cannot contain only digits."
    }

    if ($Name.StartsWith('-') -or $Name.EndsWith('-'))
    {
        return "The name cannot start or end with a hyphen."
    }

    foreach ($Pattern in $DefaultNamePatterns)
    {
        if ($Name -match $Pattern)
        {
            return "The name cannot start with a Windows default name such as DESKTOP- or LAPTOP-."
        }
    }

    if (![string]::IsNullOrWhiteSpace($Prefix) -and !$Name.StartsWith($Prefix.ToUpper()))
    {
        return "The name must start with '$($Prefix.ToUpper())'."
    }

    return ""
}

function Show-NameDialog
{
    # Shows the input dialog. Returns the checked name in capitals, or $null when the user cancels.
    param(
        [string]$CurrentName,
        [string]$Prefix
    )

    $IntroText = "The $OrgName IT department asks you to give this computer a new name.`r`n" +
        "Current name: $CurrentName`r`n`r`n" +
        "Enter the new name (up to 15 characters: letters, digits and hyphens)."
    if (![string]::IsNullOrWhiteSpace($Prefix))
    {
        $IntroText = "$IntroText It must start with '$($Prefix.ToUpper())'."
    }

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = "Rename this computer"
    $Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.TopMost = $true
    $Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $Form.ClientSize = New-Object System.Drawing.Size(440, 220)

    $IntroLabel = New-Object System.Windows.Forms.Label
    $IntroLabel.Location = New-Object System.Drawing.Point(12, 12)
    $IntroLabel.Size = New-Object System.Drawing.Size(416, 80)
    $IntroLabel.Text = $IntroText

    $NameBox = New-Object System.Windows.Forms.TextBox
    $NameBox.Location = New-Object System.Drawing.Point(12, 98)
    $NameBox.Size = New-Object System.Drawing.Size(416, 24)
    $NameBox.MaxLength = 15
    $NameBox.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Upper
    $NameBox.Text = $Prefix.ToUpper()

    $ErrorLabel = New-Object System.Windows.Forms.Label
    $ErrorLabel.Location = New-Object System.Drawing.Point(12, 130)
    $ErrorLabel.Size = New-Object System.Drawing.Size(416, 40)
    $ErrorLabel.ForeColor = [System.Drawing.Color]::DarkRed

    $OkButton = New-Object System.Windows.Forms.Button
    $OkButton.Location = New-Object System.Drawing.Point(252, 180)
    $OkButton.Size = New-Object System.Drawing.Size(85, 28)
    $OkButton.Text = "OK"

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Location = New-Object System.Drawing.Point(343, 180)
    $CancelButton.Size = New-Object System.Drawing.Size(85, 28)
    $CancelButton.Text = "Cancel"
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # OK closes the dialog only when the name passes Test-HostName; otherwise the reason is shown.
    $OkButton.Add_Click({
        $Candidate = $NameBox.Text.Trim().ToUpper()
        $Reason = Test-HostName -Name $Candidate -Prefix $Prefix
        if ($Reason)
        {
            $ErrorLabel.Text = $Reason
            $NameBox.Focus() | Out-Null
        }
        else
        {
            $NameBox.Text = $Candidate
            $Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
    })

    $Form.Controls.AddRange(@($IntroLabel, $NameBox, $ErrorLabel, $OkButton, $CancelButton))
    $Form.AcceptButton = $OkButton
    $Form.CancelButton = $CancelButton
    $Form.Add_Shown({
        $Form.Activate()
        $NameBox.Focus() | Out-Null
        $NameBox.SelectionStart = $NameBox.Text.Length
    })

    $DialogResult = $Form.ShowDialog()
    $EnteredName = $NameBox.Text.Trim().ToUpper()
    $Form.Dispose()

    if ($DialogResult -ne [System.Windows.Forms.DialogResult]::OK)
    {
        return $null
    }

    return $EnteredName
}

function Show-Message
{
    param(
        [string]$Text,
        [string]$Title,
        $Buttons = $null,
        $Icon = $null
    )

    # Defaults are set here, not in param(), because the Windows Forms types exist only after Add-Type
    if ($null -eq $Buttons) { $Buttons = [System.Windows.Forms.MessageBoxButtons]::OK }
    if ($null -eq $Icon) { $Icon = [System.Windows.Forms.MessageBoxIcon]::Information }

    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Disable-RenameTask
{
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task)
    {
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
        Write-Output "Task '$TaskName' has been disabled."
    }
}

function Request-Restart
{
    param([string]$NewName)

    $Message = "Your computer name has been changed to '$NewName'.`r`n`r`n" +
        "A restart is required. Save your work, then click Yes to restart now.`r`n" +
        "Click No to restart later; you will be asked again in 15 minutes."

    $Result = Show-Message -Text $Message -Title "Restart required" `
        -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($Result -eq [System.Windows.Forms.DialogResult]::Yes)
    {
        Write-Output "User chose to restart now."
        Disable-RenameTask
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit 0
    }

    Write-Output "User postponed the restart. The task stays enabled and will ask again."
}

# Create the log folder if it does not exist
if (!(Test-Path $LogFolder))
{
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath -Append | Out-Null

$FormsLoaded = $false

try
{
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $FormsLoaded = $true

    $Settings = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "Settings.psd1") -ErrorAction Stop
    $OrgName = $Settings.OrgName
    $RequiredPrefix = [string]$Settings.RequiredPrefix
    Write-Output "Settings: OrgName '$OrgName', RequiredPrefix '$RequiredPrefix'"

    # Active name = name in use now. Pending name = name after the next restart.
    $ActiveName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -ErrorAction Stop).ComputerName
    $PendingName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -ErrorAction Stop).ComputerName
    Write-Output "Current hostname: $ActiveName"
    if ($PendingName -ne $ActiveName)
    {
        Write-Output "Pending hostname (after restart): $PendingName"
    }

    if (!(Test-Path $RegistryPath))
    {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    # A name chosen in an earlier run is stored in NewHostname after a successful rename
    $ChosenName = (Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue).NewHostname

    if ($ChosenName -and $ActiveName -eq $ChosenName)
    {
        Write-Output "Hostname '$ActiveName' is the name the user chose. Rename is finished."
        Disable-RenameTask
        Stop-Transcript | Out-Null
        exit 0
    }

    if ($ChosenName -and $PendingName -eq $ChosenName)
    {
        Write-Output "Rename to '$ChosenName' is already done and waits for a restart."
        Request-Restart -NewName $ChosenName
        Stop-Transcript | Out-Null
        exit 0
    }

    $NewHostName = Show-NameDialog -CurrentName $ActiveName -Prefix $RequiredPrefix
    if (!$NewHostName)
    {
        Write-Output "User cancelled the name dialog. The task stays enabled and will ask again."
        Stop-Transcript | Out-Null
        exit 0
    }
    Write-Output "User entered hostname: $NewHostName"

    if ($NewHostName -eq $ActiveName)
    {
        $Answer = Show-Message -Text "'$NewHostName' is already the name of this computer. Keep this name?" -Title "Rename this computer" `
            -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) -Icon ([System.Windows.Forms.MessageBoxIcon]::Question)
        if ($Answer -eq [System.Windows.Forms.DialogResult]::Yes)
        {
            New-ItemProperty -Path $RegistryPath -Name "NewHostname" -Value $NewHostName -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $RegistryPath -Name "Rename" -Value "1" -PropertyType String -Force | Out-Null
            Write-Output "User kept the current name '$NewHostName'."
            Disable-RenameTask
        }
        else
        {
            Write-Output "User did not keep the current name. The task stays enabled and will ask again."
        }
        Stop-Transcript | Out-Null
        exit 0
    }

    $Confirm = Show-Message -Text "Rename this computer from '$ActiveName' to '$NewHostName'?`r`n`r`nA restart is required after the rename." `
        -Title "Confirm new computer name" `
        -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) -Icon ([System.Windows.Forms.MessageBoxIcon]::Question)
    if ($Confirm -ne [System.Windows.Forms.DialogResult]::Yes)
    {
        Write-Output "User did not confirm '$NewHostName'. The task stays enabled and will ask again."
        Stop-Transcript | Out-Null
        exit 0
    }

    if ($PendingName -ne $NewHostName)
    {
        $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($ComputerSystem.PartOfDomain)
        {
            Write-Output "Device is joined to domain '$($ComputerSystem.Domain)'. The rename needs a reachable domain controller."
        }

        New-ItemProperty -Path $RegistryPath -Name "OldHostname" -Value $ActiveName -PropertyType String -Force | Out-Null

        Rename-Computer -NewName $NewHostName -Force -ErrorAction Stop -WarningAction SilentlyContinue
    }
    else
    {
        Write-Output "Pending hostname is already '$NewHostName'; Rename-Computer is not needed."
    }

    New-ItemProperty -Path $RegistryPath -Name "NewHostname" -Value $NewHostName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name "Rename" -Value "1" -PropertyType String -Force | Out-Null
    Write-Output "Computer renamed to '$NewHostName'. A restart is required."

    Request-Restart -NewName $NewHostName
}
catch
{
    $ErrorText = $_.Exception.Message
    Write-Output "ERROR: $ErrorText"
    Write-Output "Computer rename was NOT completed. The task stays enabled and tries again at the next run."
    if ($FormsLoaded)
    {
        try
        {
            Show-Message -Text "The computer could not be renamed:`r`n$ErrorText`r`n`r`nYou will be asked again later. Contact IT if this message repeats." `
                -Title "Rename failed" -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        catch { }
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

try { Stop-Transcript | Out-Null } catch { }
exit 0
