<#
.SYNOPSIS
    Renames this computer to a name that you type in.

.DESCRIPTION
    Standalone script, run on the device in an elevated PowerShell window.
    It is the manual counterpart of the DeviceRename Win32 app, which builds
    the name from a prefix and the BIOS serial number.

    The script:
      1. Shows the current name, the name after the next restart (if a rename
         is already pending), the serial number and the join type.
      2. Asks for the new name and checks it:
           - 1 to 15 characters
           - only A to Z, 0 to 9 and the hyphen (no spaces)
           - not only digits, does not start or end with a hyphen
           - does not start with DESKTOP-, LAPTOP-, WIN- or MININT-
           - starts with -RequiredPrefix, when it is given
         An invalid name is rejected with the reason and asked again.
         Letters are converted to capitals.
      3. Asks for confirmation.
      4. Domain-joined device only: asks whether to use a different domain
         account for the rename of the AD computer object (No = the account
         that runs the script). Skipped when -DomainCredential is given.
      5. Runs Rename-Computer.
      6. Asks whether to restart now. The new name is active after the restart.

    In a console window the questions are asked in the console. In PowerShell
    ISE they are shown in a small window that stays on top of other windows.
    The password is hidden in both: Read-Host -AsSecureString in the console,
    a masked password box in ISE. It is kept only as a SecureString in memory.

    Intune shows the new device name after the device restarts and syncs.

.PARAMETER NewName
    The new computer name. When not given, the script asks.

.PARAMETER RequiredPrefix
    Optional. The new name must start with this text, for example a site code.

.PARAMETER DomainCredential
    Optional. Domain account used to rename the AD computer object, for
    example (Get-Credential). Used only on a domain-joined device. When not
    given on a domain-joined device, the script asks whether to enter one.

.EXAMPLE
    .\Rename-DeviceCustom.ps1

.EXAMPLE
    .\Rename-DeviceCustom.ps1 -NewName NYC-LAB-07

.EXAMPLE
    .\Rename-DeviceCustom.ps1 -RequiredPrefix NYC

.EXAMPLE
    .\Rename-DeviceCustom.ps1 -DomainCredential (Get-Credential)

.NOTES
    Version 1.1
    1.1 - New parameter -DomainCredential. On a domain-joined device the
          script asks whether to use a different domain account for the AD
          rename, and asks for user name and password (hidden; in ISE a
          window with a masked password box).
    1.0 - First version. Replaces the DeviceRenameCustom Win32 app (scheduled
          task and ServiceUI) with one script that is run directly.
#>
[CmdletBinding()]
param(
    [string]$NewName,

    [ValidatePattern('^[A-Za-z0-9-]{0,14}$')]
    [string]$RequiredPrefix = '',

    [System.Management.Automation.PSCredential]$DomainCredential
)

$ErrorActionPreference = 'Stop'

# Windows default names that may not be used
$DefaultNamePatterns = @('^DESKTOP-', '^LAPTOP-', '^WIN-', '^MININT-')

# --- Question helpers --------------------------------------------------------
# PowerShell ISE: a small window that stays on top. Console: Read-Host.

$script:UseDialog = ($Host.Name -eq 'Windows PowerShell ISE Host')

function Show-InputDialog {
    param(
        [string]$Message,
        [string]$DefaultText
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Rename computer'
    $form.TopMost         = $true
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox     = $false
    $form.MaximizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(420, 150)

    $label          = New-Object System.Windows.Forms.Label
    $label.Text     = $Message
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(396, 60)
    $form.Controls.Add($label)

    $textBox                 = New-Object System.Windows.Forms.TextBox
    $textBox.Location        = New-Object System.Drawing.Point(12, 76)
    $textBox.Size            = New-Object System.Drawing.Size(396, 22)
    $textBox.MaxLength       = 15
    $textBox.CharacterCasing = 'Upper'
    $textBox.Text            = $DefaultText
    $form.Controls.Add($textBox)

    $okButton              = New-Object System.Windows.Forms.Button
    $okButton.Text         = 'OK'
    $okButton.Size         = New-Object System.Drawing.Size(90, 28)
    $okButton.Location     = New-Object System.Drawing.Point(222, 110)
    $okButton.DialogResult = 'OK'
    $form.Controls.Add($okButton)

    $cancelButton              = New-Object System.Windows.Forms.Button
    $cancelButton.Text         = 'Cancel'
    $cancelButton.Size         = New-Object System.Drawing.Size(90, 28)
    $cancelButton.Location     = New-Object System.Drawing.Point(318, 110)
    $cancelButton.DialogResult = 'Cancel'
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({
        $this.Activate()
        $textBox.Focus() | Out-Null
        $textBox.SelectionStart = $textBox.Text.Length
    })

    $result = $form.ShowDialog()
    $text   = $textBox.Text
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $text
}

function Show-CredentialDialog {
    # ISE only. Window with a user name box and a masked password box.
    # Returns @{ UserName; Password (SecureString) }, or $null when the user cancels.
    param([string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Domain account'
    $form.TopMost         = $true
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MinimizeBox     = $false
    $form.MaximizeBox     = $false
    $form.ClientSize      = New-Object System.Drawing.Size(420, 190)

    $label          = New-Object System.Windows.Forms.Label
    $label.Text     = $Message
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(396, 48)
    $form.Controls.Add($label)

    $userLabel          = New-Object System.Windows.Forms.Label
    $userLabel.Text     = 'User name:'
    $userLabel.Location = New-Object System.Drawing.Point(12, 70)
    $userLabel.Size     = New-Object System.Drawing.Size(80, 22)
    $form.Controls.Add($userLabel)

    $userBox          = New-Object System.Windows.Forms.TextBox
    $userBox.Location = New-Object System.Drawing.Point(96, 67)
    $userBox.Size     = New-Object System.Drawing.Size(312, 22)
    $form.Controls.Add($userBox)

    $passwordLabel          = New-Object System.Windows.Forms.Label
    $passwordLabel.Text     = 'Password:'
    $passwordLabel.Location = New-Object System.Drawing.Point(12, 106)
    $passwordLabel.Size     = New-Object System.Drawing.Size(80, 22)
    $form.Controls.Add($passwordLabel)

    $passwordBox                       = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location              = New-Object System.Drawing.Point(96, 103)
    $passwordBox.Size                  = New-Object System.Drawing.Size(312, 22)
    $passwordBox.UseSystemPasswordChar = $true
    $form.Controls.Add($passwordBox)

    $okButton              = New-Object System.Windows.Forms.Button
    $okButton.Text         = 'OK'
    $okButton.Size         = New-Object System.Drawing.Size(90, 28)
    $okButton.Location     = New-Object System.Drawing.Point(222, 148)
    $okButton.DialogResult = 'OK'
    $form.Controls.Add($okButton)

    $cancelButton              = New-Object System.Windows.Forms.Button
    $cancelButton.Text         = 'Cancel'
    $cancelButton.Size         = New-Object System.Drawing.Size(90, 28)
    $cancelButton.Location     = New-Object System.Drawing.Point(318, 148)
    $cancelButton.DialogResult = 'Cancel'
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({
        $this.Activate()
        $userBox.Focus() | Out-Null
    })

    $result = $form.ShowDialog()

    # Copy the password into a SecureString one character at a time, then clear the box.
    $securePassword = New-Object System.Security.SecureString
    foreach ($character in $passwordBox.Text.ToCharArray()) { $securePassword.AppendChar($character) }
    $securePassword.MakeReadOnly()
    $passwordBox.Clear()
    $userName = $userBox.Text
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [PSCustomObject]@{ UserName = $userName; Password = $securePassword }
}

function Show-Warning {
    param([string]$Text)
    if ($script:UseDialog) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Text, 'Rename computer', 'OK', 'Warning') | Out-Null
    }
    else {
        Write-Host $Text -ForegroundColor Yellow
    }
}

function Read-DomainCredential {
    # Asks for a domain user name and password. Returns a PSCredential, or $null when the user cancels.
    # A user name without a domain part gets the device's domain: <domain>\<user>.
    param([string]$DomainName)

    $message = "Domain account that may rename computer objects in AD.`nUser name as DOMAIN\user or user@domain."
    while ($true) {
        if ($script:UseDialog) {
            $answer = Show-CredentialDialog -Message $message
            if ($null -eq $answer) { return $null }
            $userName = "$($answer.UserName)".Trim()
            $password = $answer.Password
        }
        else {
            Write-Host $message
            $userName = "$(Read-Host 'User name, or Q to quit')".Trim()
            if ($userName.ToUpper() -eq 'Q') { return $null }
            if (-not $userName) {
                Show-Warning -Text 'Enter a user name.'
                continue
            }
            $password = Read-Host 'Password' -AsSecureString
        }

        if (-not $userName) {
            Show-Warning -Text 'Enter a user name.'
            continue
        }
        if ($null -eq $password -or $password.Length -eq 0) {
            Show-Warning -Text 'Enter a password.'
            continue
        }

        if ($userName -notmatch '[\\@]') { $userName = "$($DomainName)\$($userName)" }
        return New-Object System.Management.Automation.PSCredential($userName, $password)
    }
}

function Read-YesNo {
    # Returns $true for Yes, $false for No.
    param([string]$Question)

    if ($script:UseDialog) {
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show($Question, 'Rename computer', 'YesNo', 'Question')
        return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    while ($true) {
        $answer = "$(Read-Host "$($Question) (Y/N)")".Trim().ToUpper()
        if (@('Y', 'YES') -contains $answer) { return $true }
        if (@('N', 'NO') -contains $answer)  { return $false }
        Write-Host 'Please enter Y or N.' -ForegroundColor Yellow
    }
}

function Test-HostName {
    # Returns an empty string when the name is valid, otherwise the reason why it is not valid.
    param(
        [string]$Name,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Enter a computer name.' }
    if ($Name.Length -gt 15) { return "The name has $($Name.Length) characters. The maximum is 15." }
    if ($Name -notmatch '^[A-Z0-9-]+$') { return 'Use only the letters A to Z, the digits 0 to 9 and the hyphen (-). No spaces.' }
    if ($Name -match '^[0-9]+$') { return 'The name cannot contain only digits.' }
    if ($Name.StartsWith('-') -or $Name.EndsWith('-')) { return 'The name cannot start or end with a hyphen.' }
    foreach ($pattern in $DefaultNamePatterns) {
        if ($Name -match $pattern) { return 'The name cannot start with a Windows default name such as DESKTOP- or LAPTOP-.' }
    }
    if ($Prefix -and -not $Name.StartsWith($Prefix.ToUpper())) { return "The name must start with '$($Prefix.ToUpper())'." }
    return ''
}

function Read-NewName {
    # Asks until a valid name is entered. Returns $null when the user cancels (ISE window) or enters Q.
    param(
        [string]$CurrentName,
        [string]$Prefix
    )

    $question = 'Enter the new computer name (up to 15 characters: letters, digits and hyphens)'
    if ($Prefix) { $question = "$($question). It must start with '$($Prefix.ToUpper())'" }

    while ($true) {
        if ($script:UseDialog) {
            $entered = Show-InputDialog -Message "Current name: $($CurrentName)`n`n$($question)." -DefaultText $Prefix.ToUpper()
            if ($null -eq $entered) { return $null }
        }
        else {
            $entered = Read-Host "$($question), or Q to quit"
            if ("$entered".Trim().ToUpper() -eq 'Q') { return $null }
        }

        $name   = "$entered".Trim().ToUpper()
        $reason = Test-HostName -Name $name -Prefix $Prefix
        if (-not $reason) { return $name }

        Show-Warning -Text $reason
    }
}

# --- Administrator check (Rename-Computer needs administrator rights) --------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as administrator. Right-click PowerShell and choose 'Run as administrator'." -ForegroundColor Red
    exit 1
}

# --- Current state -----------------------------------------------------------
# Active name = name in use now. Pending name = name after the next restart.
$activeName  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
$pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
$computer    = Get-CimInstance -ClassName Win32_ComputerSystem
$serial      = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber

$joinType = 'Not joined to a domain (Entra ID joined or workgroup)'
if ($computer.PartOfDomain) { $joinType = "Joined to domain $($computer.Domain)" }

Write-Host ''
Write-Host "Current name:   $activeName"
if ($pendingName -ne $activeName) {
    Write-Host "Pending name:   $pendingName (active after the next restart)" -ForegroundColor Yellow
}
Write-Host "Serial number:  $serial"
Write-Host "Join type:      $joinType"
Write-Host ''

# --- New name ----------------------------------------------------------------
if ($NewName) {
    $targetName = $NewName.Trim().ToUpper()
    $reason = Test-HostName -Name $targetName -Prefix $RequiredPrefix
    if ($reason) {
        Write-Host "'$targetName' is not a valid name: $reason" -ForegroundColor Red
        exit 1
    }
}
else {
    $targetName = Read-NewName -CurrentName $activeName -Prefix $RequiredPrefix
    if (-not $targetName) {
        Write-Host 'Cancelled. The computer name was not changed.'
        exit 0
    }
}

if ($targetName -eq $activeName -and $pendingName -eq $activeName) {
    Write-Host "'$targetName' is already the name of this computer. Nothing to do."
    exit 0
}

# --- Confirm and rename ------------------------------------------------------
if ($targetName -eq $pendingName) {
    Write-Host "The rename to '$targetName' is already done and waits for a restart."
}
else {
    if (-not (Read-YesNo -Question "Rename this computer from '$activeName' to '$targetName'?")) {
        Write-Host 'Cancelled. The computer name was not changed.'
        exit 0
    }

    $renameParams = @{
        NewName       = $targetName
        Force         = $true
        WarningAction = 'SilentlyContinue'
    }

    if ($computer.PartOfDomain) {
        Write-Host 'The device is domain joined. The rename also renames the AD computer object and needs a reachable domain controller.'
        $credential = $DomainCredential
        if (-not $credential) {
            $useOtherAccount = Read-YesNo -Question "Use a different domain account to rename the computer object in AD? Choose No to use the account that runs this script ($($identity.Name))."
            if ($useOtherAccount) {
                $credential = Read-DomainCredential -DomainName $computer.Domain
                if (-not $credential) {
                    Write-Host 'Cancelled. The computer name was not changed.'
                    exit 0
                }
            }
        }
        if ($credential) {
            $renameParams['DomainCredential'] = $credential
            Write-Host "AD rename uses the account $($credential.UserName)."
        }
        else {
            Write-Host "AD rename uses the account $($identity.Name)."
        }
    }
    elseif ($DomainCredential) {
        Write-Host 'The device is not domain joined. -DomainCredential is not used.'
    }

    try {
        Rename-Computer @renameParams
    }
    catch {
        Write-Host "The computer could not be renamed: $($_.Exception.Message)" -ForegroundColor Red
        if ($computer.PartOfDomain) {
            Write-Host 'If the error is "Access is denied", run the script again and use a domain account that may rename computer objects in AD.' -ForegroundColor Yellow
        }
        exit 1
    }
    Write-Host "Computer renamed to '$targetName'. The new name is active after a restart." -ForegroundColor Green
}

# --- Restart -----------------------------------------------------------------
if (Read-YesNo -Question 'Restart now? Save your work first.') {
    Restart-Computer -Force
}
else {
    Write-Host 'Restart later. Intune shows the new name after the restart and the next sync.'
}
exit 0
