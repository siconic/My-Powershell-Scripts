#==========================================================
# Module Globals
#==========================================================
Set-StrictMode -Version Latest

$script:Settings        = $null
$script:FirewallRules   = $null
$script:Unclassified    = $null
$script:ExcludeFirewallRulesFromComparison = $true
$script:ASRRuleMap = @{}

$script:DeprecatedPolicyReference = @{
    Policies      = @()
    RegistryPaths = @()
}
#==========================================================
# Core Framework
#==========================================================

function New-GPOParseResult {

    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Settings      = New-Object System.Collections.ArrayList
        FirewallRules = New-Object System.Collections.ArrayList
        Unclassified  = New-Object System.Collections.ArrayList
    }
}

function Get-CleanText {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Text
    )

    if ($null -eq $Text)
    {
        return ""
    }

    $Value =
        $Text.ToString()

    $Value =
        $Value -replace '\r',' '

    $Value =
        $Value -replace '\n',' '

    $Value =
        $Value -replace '\s+',' '

    $Value.Trim()
}

function Convert-ToBooleanString {

    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value)
    {
        return ""
    }

    switch ($Value.ToString().ToLower())
    {
        "true"  { return "True" }
        "false" { return "False" }
        default { return $Value.ToString() }
    }
}

function Get-NodeValue {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Node
    )

    if (
        Test-Property `
            $Node `
            'SettingBoolean'
    )
    {
        return (
            Get-CleanText `
                $Node.SettingBoolean
        )
    }

    if (
        Test-Property `
            $Node `
            'SettingNumber'
    )
    {
        return (
            Get-CleanText `
                $Node.SettingNumber
        )
    }

    if (
        Test-Property `
            $Node `
            'SettingString'
    )
    {
        return (
            Get-CleanText `
                $Node.SettingString
        )
    }

    if (
        Test-Property `
            $Node `
            'SettingStrings'
    )
    {
        return (
            @($Node.SettingStrings.Value) |
            ForEach-Object {
                Get-CleanText $_
            }
        ) -join "; "
    }

    if (
        Test-Property `
            $Node `
            'SettingValue'
    )
    {
        return (
            Get-CleanText `
                $Node.SettingValue
        )
    }

    return (
        Get-CleanText `
            $Node.InnerText
    )
}

function Get-NodeState {

    [CmdletBinding()]
    param(
        [AllowNull()]
        $Node
    )

    if ($null -eq $Node)
    {
        return "Configured"
    }

    if ($Node.State)
    {
        return (
            Get-CleanText `
                $Node.State
        )
    }

    return "Configured"
}

function Convert-AuditValue {

    [CmdletBinding()]
    param(
        [int]$Value
    )

    switch ($Value)
    {
        0 { "No Auditing" }
        1 { "Success" }
        2 { "Failure" }
        3 { "Success and Failure" }
        default { $Value }
    }
}

function New-GPOSetting {

    [CmdletBinding()]
    param(
        [string]$GPOName,

        [string]$Class,

        [string]$Extension,

        [string]$Category,

        [string]$SettingName,

        [string]$Value,

        [string]$State
    )

    [PSCustomObject]@{
        GPOName      = $GPOName
        Class        = $Class
        Extension    = $Extension
        Category     = $Category
        SettingName  = $SettingName
        Value        = $Value
        State        = $State
    }
}

function Add-NormalizedSetting {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref]$Result,

        [string]$GPOName,

        [string]$Class,

        [string]$Extension,

        [string]$Category,

        [string]$SettingName,

        [string]$Value,

        [string]$State
    )

    $SettingName =
        Get-CleanText $SettingName

    $Value =
        Get-CleanText $Value

    $State =
        Get-CleanText $State

    $Category =
        Get-CleanText $Category

    $Extension =
        Get-CleanText $Extension

    if ([string]::IsNullOrWhiteSpace($SettingName))
    {
        [void]$Result.Value.Unclassified.Add(
            [PSCustomObject]@{
                GPOName   = $GPOName
                Extension = $Extension
                Category  = $Category
                Value     = $Value
                State     = $State
                Reason    = "Missing Setting Name"
            }
        )

        return
    }

    if ([string]::IsNullOrWhiteSpace($Category))
    {
        $Category = "<NoCategory>"
    }

    if ([string]::IsNullOrWhiteSpace($Extension))
    {
        $Extension = "<UnknownExtension>"
    }

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        $Value = "<NoValue>"
    }

    if ([string]::IsNullOrWhiteSpace($State))
    {
        $State = "Configured"
    }

    [void]$Result.Value.Settings.Add(
        (
            New-GPOSetting `
                -GPOName $GPOName `
                -Class $Class `
                -Extension $Extension `
                -Category $Category `
                -SettingName $SettingName `
                -Value $Value `
                -State $State
        )
    )
}

function Add-FirewallRule {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref]$Result,

        [string]$GPOName,

        [string]$Profile,

        [string]$Name,

        [string]$Action,

        [string]$Direction,

        [string]$Application,

        [string]$Protocol
    )

    [void]$Result.Value.FirewallRules.Add(
        [PSCustomObject]@{
            GPOName     = $GPOName
            Profile     = $Profile
            Name        = $Name
            Action      = $Action
            Direction   = $Direction
            Application = $Application
            Protocol    = $Protocol
        }
    )
}

function New-GPONamespaceManager {

    [CmdletBinding()]
    param(
        [xml]$Xml
    )

    $Ns =
        New-Object System.Xml.XmlNamespaceManager(
            $Xml.NameTable
        )

    $Ns.AddNamespace(
        "gp",
        "http://www.microsoft.com/GroupPolicy/Settings"
    )

    return $Ns
}

function Test-Property {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object)
    {
        return $false
    }

    try
    {
        return (
            $null -ne $Object.PSObject.Properties[$PropertyName]
        )
    }
    catch
    {
        return $false
    }
}

function Get-PropertyValue {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if (
        Test-Property `
            -Object $Object `
            -PropertyName $PropertyName
    )
    {
        return $Object.$PropertyName
    }

    return $null
}

function Get-XmlProperty {
    param(
        $Object,
        [string]$PropertyName
    )

    if ($null -eq $Object)
    {
        return $null
    }

    $Property =
        $Object.PSObject.Properties[$PropertyName]

    if ($null -ne $Property)
    {
        return $Property.Value
    }

    return $null
}

function Get-SafeArray {

    [CmdletBinding()]
    param(
        [AllowNull()]
        $Object
    )

    if ($null -eq $Object)
    {
        return @()
    }

    if ($Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string]))
    {
        return @($Object)
    }

    return @($Object)
}

<#function Get-SafeArray {
    param($Object)

    if ($null -eq $Object)
    {
        return @()
    }

    if ($Object -is [System.Array])
    {
        return $Object
    }

    return @($Object)
}#>


#==========================================================
# Security Parser Sections
#==========================================================
function Parse-SecuritySettings {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    Parse-AccountPolicies `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName `
        -Class $Class

    Parse-UserRightsAssignments `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName `
        -Class $Class

    Parse-SecurityOptions `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName `
        -Class $Class

    Parse-SystemServices `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName `
        -Class $Class
}

function Parse-AccountPolicies {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    $Accounts =
        Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'Account'
        )

    foreach ($Account in $Accounts)
    {
        $SettingName =
            Get-CleanText (
                Get-XmlProperty `
                    -Object $Account `
                    -PropertyName 'Name'
            )

        $Category =
            Get-CleanText (
                Get-XmlProperty `
                    -Object $Account `
                    -PropertyName 'Type'
            )

        $Value = $null

        #
        # Boolean
        #

        $BooleanValue =
            Get-XmlProperty `
                -Object $Account `
                -PropertyName 'SettingBoolean'

        if ($null -ne $BooleanValue)
        {
            $Value =
                Convert-ToBooleanString `
                    $BooleanValue
        }

        #
        # Number
        #

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            $NumberValue =
                Get-XmlProperty `
                    -Object $Account `
                    -PropertyName 'SettingNumber'

            if ($null -ne $NumberValue)
            {
                $Value =
                    Get-CleanText `
                        $NumberValue
            }
        }

        #
        # String
        #

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            $StringValue =
                Get-XmlProperty `
                    -Object $Account `
                    -PropertyName 'SettingString'

            if ($null -ne $StringValue)
            {
                $Value =
                    Get-CleanText `
                        $StringValue
            }
        }

        #
        # Final fallback
        #

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            $Value = "<NoValue>"
        }

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Security" `
            -Category $Category `
            -SettingName $SettingName `
            -Value $Value `
            -State "Configured"
    }
}

function Parse-UserRightsAssignments {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    foreach (
        $Assignment in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'UserRightsAssignment'
        ))
    )
    {
        $Members = @()

        foreach (
            $Member in
            (Get-SafeArray (
                Get-XmlProperty `
                    -Object $Assignment `
                    -PropertyName 'Member'
            ))
        )
        {
            $MemberName =
                Get-CleanText `
                    (Get-XmlProperty `
                        -Object $Member `
                        -PropertyName 'Name')

            if (-not [string]::IsNullOrWhiteSpace($MemberName))
            {
                $Members += $MemberName
            }
        }

        if (@($Members).Count -eq 0)
        {
            $Members = @("<NoAssignments>")
        }

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Security" `
            -Category "User Rights Assignment" `
            -SettingName (
                Get-CleanText `
                    (Get-XmlProperty `
                        -Object $Assignment `
                        -PropertyName 'Name')
            ) `
            -Value ($Members -join "; ") `
            -State "Configured"
    }
}

function Parse-SecurityOptions {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

        $SecurityOptions =
            Get-SafeArray (
                Get-XmlProperty `
                    -Object $Extension `
                    -PropertyName 'SecurityOptions'
            )

        foreach ($Option in $SecurityOptions)
        {
        #--------------------------------------------------
        # Determine Friendly Setting Name
        #--------------------------------------------------

        $SettingName = $null

        if (
            Test-Property `
                -Object $Option `
                -PropertyName 'Display'
        )
        {
            if (
                Test-Property `
                    -Object $Option.Display `
                    -PropertyName 'Name'
            )
            {
                $SettingName =
                    Get-CleanText `
                        $Option.Display.Name
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $SettingName
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'SystemAccessPolicyName'
            )
            {
                $SettingName =
                    Get-CleanText `
                        $Option.SystemAccessPolicyName
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $SettingName
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'KeyName'
            )
            {
                $SettingName =
                    Get-CleanText `
                        $Option.KeyName
            }
        }

        #--------------------------------------------------
        # Determine Best Value
        #--------------------------------------------------

        $Value = $null

        if (
            Test-Property `
                -Object $Option `
                -PropertyName 'Display'
        )
        {
            $Display = $Option.Display

            #------------------------------------------
            # Friendly String
            #------------------------------------------

            if (
                Test-Property `
                    -Object $Display `
                    -PropertyName 'DisplayString'
            )
            {
                $Value =
                    Get-CleanText `
                        $Display.DisplayString
            }

            #------------------------------------------
            # Friendly Boolean
            #------------------------------------------

            elseif (
                Test-Property `
                    -Object $Display `
                    -PropertyName 'DisplayBoolean'
            )
            {
                $Value =
                    Convert-ToBooleanString `
                        $Display.DisplayBoolean
            }

            #------------------------------------------
            # Friendly Number
            #------------------------------------------

            elseif (
                Test-Property `
                    -Object $Display `
                    -PropertyName 'DisplayNumber'
            )
            {
                $Value =
                    Get-CleanText `
                        $Display.DisplayNumber
            }

            #------------------------------------------
            # Friendly String Lists
            #------------------------------------------

            elseif (
                Test-Property `
                    -Object $Display `
                    -PropertyName 'DisplayStrings'
            )
            {
                $Entries = @()

                if (
                    Test-Property `
                        -Object $Display.DisplayStrings `
                        -PropertyName 'Value'
                )
                {
                    $Entries =
                        @($Display.DisplayStrings.Value) |
                        ForEach-Object {
                            Get-CleanText $_
                        }
                }

                $Value =
                    $Entries -join "; "
            }

            #------------------------------------------
            # Complex Display Fields
            #------------------------------------------

            elseif (
                Test-Property `
                    -Object $Display `
                    -PropertyName 'DisplayFields'
            )
            {
                $Fields = @()

                if (
                    Test-Property `
                        -Object $Display.DisplayFields `
                        -PropertyName 'Field'
                )
                {
                    foreach (
                        $Field in
                        @($Display.DisplayFields.Field)
                    )
                    {
                        $Fields += (
                            "{0}={1}" -f
                            (
                                Get-CleanText `
                                    $Field.Name
                            ),
                            (
                                Get-CleanText `
                                    $Field.Value
                            )
                        )
                    }
                }

                $Value =
                    $Fields -join "; "
            }
        }

        #--------------------------------------------------
        # Raw Setting Fallbacks
        #--------------------------------------------------

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'SettingStrings'
            )
            {
                $Entries = @()

                if (
                    Test-Property `
                        -Object $Option.SettingStrings `
                        -PropertyName 'Value'
                )
                {
                    $Entries =
                        @($Option.SettingStrings.Value) |
                        ForEach-Object {
                            Get-CleanText $_
                        }
                }

                $Value =
                    $Entries -join "; "
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'SettingString'
            )
            {
                $Value =
                    Get-CleanText `
                        $Option.SettingString
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'SettingNumber'
            )
            {
                $Value =
                    Get-CleanText `
                        $Option.SettingNumber
            }
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            if (
                Test-Property `
                    -Object $Option `
                    -PropertyName 'SettingBoolean'
            )
            {
                $Value =
                    Convert-ToBooleanString `
                        $Option.SettingBoolean
            }
        }

        #--------------------------------------------------
        # Absolute Fallback
        #--------------------------------------------------

        if (
            [string]::IsNullOrWhiteSpace(
                $Value
            )
        )
        {
            $Value = "<NoValue>"
        }

        if (
            [string]::IsNullOrWhiteSpace(
                $SettingName
            )
        )
        {
            $SettingName = "<UnknownSecurityOption>"
        }

        #--------------------------------------------------
        # Add Normalized Record
        #--------------------------------------------------

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Security" `
            -Category "Security Options" `
            -SettingName $SettingName `
            -Value $Value `
            -State "Configured"
    }
}

function Parse-SystemServices {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    $SystemServices =
        Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'SystemServices'
        )

    foreach ($Service in $SystemServices)
    {
        $ServiceName =
            Get-CleanText (
                Get-XmlProperty `
                    -Object $Service `
                    -PropertyName 'Name'
            )

        $StartupMode =
            Get-CleanText (
                Get-XmlProperty `
                    -Object $Service `
                    -PropertyName 'StartupMode'
            )

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Security" `
            -Category "System Services" `
            -SettingName $ServiceName `
            -Value $StartupMode `
            -State "Configured"

        #
        # Optional ACL Collection
        #

        $SecurityDescriptor =
            Get-XmlProperty `
                -Object $Service `
                -PropertyName 'SecurityDescriptor'

        if ($null -ne $SecurityDescriptor)
        {
            $Sddl =
                Get-XmlProperty `
                    -Object $SecurityDescriptor `
                    -PropertyName 'SDDL'

            if (
                -not [string]::IsNullOrWhiteSpace($Sddl)
            )
            {
                Add-NormalizedSetting `
                    -Result $Result `
                    -GPOName $GPOName `
                    -Class $Class `
                    -Extension "Security" `
                    -Category "Service Permissions" `
                    -SettingName (
                        "$ServiceName ACL"
                    ) `
                    -Value (
                        Get-CleanText $Sddl
                    ) `
                    -State "Configured"
            }
        }
    }
}
#==========================================================
# Advanced Audit Policy Parser
#==========================================================
function Parse-AdvancedAuditPolicies {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    $AuditSettings =
        Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'AuditSetting'
        )

    foreach ($Audit in $AuditSettings)
    {
        Parse-AuditSetting `
            -Result $Result `
            -Audit $Audit `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Parse-AuditSetting {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Audit,

        [string]$GPOName,

        [string]$Class
    )

    $SettingName =
        Get-CleanText `
            $Audit.SubcategoryName

    $PolicyTarget =
        Get-CleanText `
            $Audit.PolicyTarget

    $AuditValue =
        Get-CleanText `
            $Audit.SettingValue
        

    $Value =
        Convert-AuditValue `
            $AuditValue

    Add-NormalizedSetting `
        -Result $Result `
        -GPOName $GPOName `
        -Class $Class `
        -Extension "Advanced Audit Policy" `
        -Category $PolicyTarget `
        -SettingName $SettingName `
        -Value $Value `
        -State "Configured"
}

function Convert-AuditValue {

    [CmdletBinding()]
    param(
        [int]$Value
    )

    switch ($Value)
    {
        0 { "No Auditing" }

        1 { "Success" }

        2 { "Failure" }

        3 { "Success and Failure" }

        default { "Unknown ($Value)" }
    }
}

function Get-AuditCategory {

    param(
        [string]$SubCategory
    )

    switch -Regex ($SubCategory)
    {
        "Credential" {
            "Logon/Logoff"
        }

        "Logon" {
            "Logon/Logoff"
        }

        "Account" {
            "Account Management"
        }

        "Policy" {
            "Policy Change"
        }

        "File Share" {
            "Object Access"
        }

        "Object" {
            "Object Access"
        }

        "Privilege" {
            "Privilege Use"
        }

        "System" {
            "System"
        }

        default {
            "Advanced Audit"
        }
    }
}

#==========================================================
# Administrative Templates Parser
#==========================================================

function Parse-AdministrativeTemplates {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    $Policies =
        Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'Policy'
        )

    foreach ($Policy in $Policies)
    {
        Parse-AdministrativeTemplatePolicy `
            -Result $Result `
            -Policy $Policy `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Parse-AdministrativeTemplatePolicy {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Policy,

        [string]$GPOName,

        [string]$Class
    )

    $SettingName =
        Get-CleanText $Policy.Name

    $Category =
        Get-CleanText $Policy.Category

    $State =
        Get-CleanText $Policy.State

    $Value =
        Get-AdministrativeTemplateValue `
            -Policy $Policy

    #
    # Fallback for simple Enable/Disable policies
    #
    if (
        $Value -eq "<NoPolicyOptions>" -and
        -not [string]::IsNullOrWhiteSpace($State)
    )
    {
        $Value = $State
    }

    #
    # Final fallback
    #
    if ([string]::IsNullOrWhiteSpace($Value))
    {
        $Value = "<NoValue>"
    }

    Add-NormalizedSetting `
        -Result $Result `
        -GPOName $GPOName `
        -Class $Class `
        -Extension "Administrative Templates" `
        -Category $Category `
        -SettingName $SettingName `
        -Value $Value `
        -State $State
}

function Get-AdministrativeTemplateValue {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Policy
    )

    $Values = [System.Collections.ArrayList]::new()

    #
    # CheckBox
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'CheckBox')))
    {
        [void]$Values.Add(
            ("{0}={1}" -f
                (Get-CleanText (Get-XmlProperty $Item 'Name')),
                (Get-CleanText (Get-XmlProperty $Item 'State')))
        )
    }

    #
    # EditText
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'EditText')))
    {
        [void]$Values.Add(
            ("{0}={1}" -f
                (Get-CleanText (Get-XmlProperty $Item 'Name')),
                (Get-CleanText (Get-XmlProperty $Item 'Value')))
        )
    }

    #
    # Numeric
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'Numeric')))
    {
        [void]$Values.Add(
            ("{0}={1}" -f
                (Get-CleanText (Get-XmlProperty $Item 'Name')),
                (Get-CleanText (Get-XmlProperty $Item 'Value')))
        )
    }

    #
    # DropDownList
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'DropDownList')))
    {
        $SelectedValue = ""

        $ValueNode =
            Get-XmlProperty $Item 'Value'

        if ($null -ne $ValueNode)
        {
            $SelectedValue =
                Get-CleanText (
                    Get-XmlProperty `
                        $ValueNode `
                        'Name'
                )
        }

        if ([string]::IsNullOrWhiteSpace($SelectedValue))
        {
            $SelectedValue =
                Get-CleanText (
                    Get-XmlProperty `
                        $Item `
                        'State'
                )
        }

        [void]$Values.Add(
            ("{0}={1}" -f
                (Get-CleanText (Get-XmlProperty $Item 'Name')),
                $SelectedValue)
        )
    }

    #
    # ListBox
    #

    foreach ($ListBox in (Get-SafeArray (Get-XmlProperty $Policy 'ListBox')))
    {
        $Entries = @()

        $ValueNode =
            Get-XmlProperty `
                $ListBox `
                'Value'

        $Elements =
            Get-SafeArray (
                Get-XmlProperty `
                    $ValueNode `
                    'Element'
            )

        foreach ($Element in $Elements)
        {
            $Name =
                Get-CleanText (
                    Get-XmlProperty `
                        $Element `
                        'Name'
                )

            $Data =
                Get-CleanText (
                    Get-XmlProperty `
                        $Element `
                        'Data'
                )

            #
            # Optional ASR translation
            #

            if (
                (Get-Variable `
                    -Name ASRRuleMap `
                    -Scope Script `
                    -ErrorAction SilentlyContinue
                ) -and
                $script:ASRRuleMap.ContainsKey($Name)
            )
            {
                $Name =
                    $script:ASRRuleMap[$Name]
            }

            if (
                -not [string]::IsNullOrWhiteSpace($Name) -and
                -not [string]::IsNullOrWhiteSpace($Data)
            )
            {
                $Entries += ("{0}={1}" -f $Name,$Data)
            }
            elseif (
                -not [string]::IsNullOrWhiteSpace($Data)
            )
            {
                $Entries += $Data
            }
        }

        if (@($Entries).Count -gt 0)
        {
            [void]$Values.Add(
                ("{0}={1}" -f
                    (Get-CleanText (Get-XmlProperty $ListBox 'Name')),
                    ($Entries -join '; '))
            )
        }
    }

    #
    # MultiText
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'MultiText')))
    {
        $Entries =
            (Get-SafeArray (
                Get-XmlProperty `
                    $Item `
                    'Value'
            )) |
            ForEach-Object {
                Get-CleanText $_
            }

        if (@($Entries).Count -gt 0)
        {
            [void]$Values.Add(
                ("{0}={1}" -f
                    (Get-CleanText (Get-XmlProperty $Item 'Name')),
                    ($Entries -join '; '))
            )
        }
    }

    #
    # Text
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'Text')))
    {
        $TextValue =
            Get-CleanText (
                Get-XmlProperty `
                    $Item `
                    'Name'
            )

        if (-not [string]::IsNullOrWhiteSpace($TextValue))
        {
            [void]$Values.Add(
                "Text=$TextValue"
            )
        }
    }

    #
    # Unknown Child Nodes
    #

    foreach ($Child in (Get-SafeArray $Policy.ChildNodes))
    {
        if ($Child.Name -in @(
            'Name',
            'State',
            'Explain',
            'Supported',
            'Category',
            'CheckBox',
            'EditText',
            'Numeric',
            'DropDownList',
            'ListBox',
            'MultiText',
            'Text'
        ))
        {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($Child.InnerText))
        {
            [void]$Values.Add(
                ("{0}={1}" -f
                    $Child.Name,
                    (Get-CleanText $Child.InnerText))
            )
        }
    }

    #
    # No values found
    #

    if ($Values.Count -eq 0)
    {
        return "<NoPolicyOptions>"
    }

    return ($Values -join " | ")
}

#===========================================================
# REGISTRY SETTINGS PARSERS
#===========================================================

function Parse-RegistrySettings {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    foreach (
        $Entry in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'RegistrySetting'
        ))
    )
    {
        Parse-RegistrySetting `
            -Result $Result `
            -RegistryEntry $Entry `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Parse-RegistrySetting {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$RegistryEntry,

        [string]$GPOName,

        [string]$Class
    )

    $KeyPath =
        Get-CleanText (
            Get-XmlProperty `
                -Object $RegistryEntry `
                -PropertyName 'KeyPath'
        )

    $ValueNode =
        Get-XmlProperty `
            -Object $RegistryEntry `
            -PropertyName 'Value'

    if ($null -eq $ValueNode)
    {
        return
    }

    $SettingName =
        Get-CleanText (
            Get-XmlProperty `
                -Object $ValueNode `
                -PropertyName 'Name'
        )

    $Value = $null

    #
    # Number
    #

    $Number =
        Get-XmlProperty `
            -Object $ValueNode `
            -PropertyName 'Number'

    if ($null -ne $Number)
    {
        $Value =
            Get-CleanText $Number
    }

    #
    # String
    #

    if (
        [string]::IsNullOrWhiteSpace(
            $Value
        )
    )
    {
        $String =
            Get-XmlProperty `
                -Object $ValueNode `
                -PropertyName 'String'

        if ($null -ne $String)
        {
            $Value =
                Get-CleanText $String
        }
    }

    #
    # Binary
    #

    if (
        [string]::IsNullOrWhiteSpace(
            $Value
        )
    )
    {
        $Binary =
            Get-XmlProperty `
                -Object $ValueNode `
                -PropertyName 'Binary'

        if ($null -ne $Binary)
        {
            $Value =
                Get-CleanText $Binary
        }
    }

    #
    # MultiString
    #

    if (
        [string]::IsNullOrWhiteSpace(
            $Value
        )
    )
    {
        $MultiString =
            Get-XmlProperty `
                -Object $ValueNode `
                -PropertyName 'MultiString'

        if ($null -ne $MultiString)
        {
            $Value =
                (
                    Get-SafeArray $MultiString |
                    ForEach-Object {
                        Get-CleanText $_
                    }
                ) -join "; "
        }
    }

    #
    # Fallback
    #

    if (
        [string]::IsNullOrWhiteSpace(
            $Value
        )
    )
    {
        $Value = "<NoValue>"
    }

    Add-NormalizedSetting `
        -Result $Result `
        -GPOName $GPOName `
        -Class $Class `
        -Extension "Registry Settings" `
        -Category $KeyPath `
        -SettingName $SettingName `
        -Value $Value `
        -State "Configured"
}

#==========================================================
# Windows Firewall Parser
#==========================================================

function Parse-WindowsFirewall {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    Parse-FirewallProfile `
        -Result $Result `
        -ProfileNode $Extension.DomainProfile `
        -ProfileName "Domain" `
        -GPOName $GPOName `
        -Class $Class

    Parse-FirewallProfile `
        -Result $Result `
        -ProfileNode $Extension.PrivateProfile `
        -ProfileName "Private" `
        -GPOName $GPOName `
        -Class $Class

    Parse-FirewallProfile `
        -Result $Result `
        -ProfileNode $Extension.PublicProfile `
        -ProfileName "Public" `
        -GPOName $GPOName `
        -Class $Class

    Parse-FirewallRules `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName
}

function Parse-FirewallProfile {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$ProfileNode,

        [string]$ProfileName,

        [string]$GPOName,

        [string]$Class
    )

    if (-not $ProfileNode)
    {
        return
    }

    foreach ($Child in $ProfileNode.ChildNodes)
    {
        if (-not $Child.Name)
        {
            continue
        }

        $SettingName =
            Get-CleanText $Child.Name

        $Value =
            Get-CleanText $Child.Value

        if (
            $Child.Value -eq "true" -or
            $Child.Value -eq "false"
        )
        {
            $Value =
                Convert-ToBooleanString `
                    $Child.Value
        }

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Windows Firewall" `
            -Category "$ProfileName Profile" `
            -SettingName $SettingName `
            -Value $Value `
            -State "Configured"
    }
}

function Parse-FirewallRules {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName
    )

    foreach ($Rule in @($Extension.InboundFirewallRules))
    {
        Parse-FirewallRule `
            -Result $Result `
            -Rule $Rule `
            -Direction "Inbound" `
            -GPOName $GPOName
    }
}

function Parse-FirewallRule {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Rule,

        [string]$Direction,

        [string]$GPOName
    )

    #
    # Profiles
    #

    $Profiles = @()

    $ProfileProperty =
        Get-XmlProperty `
            -Object $Rule `
            -PropertyName 'Profile'

    if ($null -ne $ProfileProperty)
    {
        $Profiles =
            (Get-SafeArray $ProfileProperty) |
            ForEach-Object {
                Get-CleanText $_
            }
    }

    if (@($Profiles).Count -eq 0)
    {
        $Profiles = @("<NotSpecified>")
    }

    #
    # Collect values safely
    #

    $Name =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Name')

    $Action =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Action')

    $Application =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'App')

    $Protocol =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Protocol')

    $LocalPort =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'LPort')

    $RemotePort =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'RPort')

    $Service =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Svc')

    $Description =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Desc')

    $Active =
        Get-CleanText `
            (Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Active')

    #
    # Add firewall rule record
    #

    Add-FirewallRule `
        -Result $Result `
        -GPOName $GPOName `
        -Profile ($Profiles -join "; ") `
        -Name $Name `
        -Action $Action `
        -Direction $Direction `
        -Application $Application `
        -Protocol $Protocol `
        -LocalPort $LocalPort `
        -RemotePort $RemotePort `
        -Service $Service `
        -Description $Description `
        -Active $Active
}

function Add-FirewallRule {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [string]$GPOName,

        [string]$Profile,

        [string]$Name,

        [string]$Action,

        [string]$Direction,

        [string]$Application,

        [string]$Protocol,

        [string]$LocalPort,

        [string]$RemotePort,

        [string]$Service,

        [string]$Description,

        [string]$Active
    )

    [void]$Result.Value.FirewallRules.Add(
        [PSCustomObject]@{
            GPOName     = $GPOName
            Profile     = $Profile
            Name        = $Name
            Action      = $Action
            Direction   = $Direction
            Application = $Application
            Protocol    = $Protocol
            LocalPort   = $LocalPort
            RemotePort  = $RemotePort
            Service     = $Service
            Description = $Description
            Active      = $Active
        }
    )
}

#==========================================================
# Local Users and Groups Parser
#==========================================================

function Parse-LocalUsersAndGroups {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    $Container =
        $Extension.LocalUsersAndGroups

    if (-not $Container)
    {
        return
    }

    foreach ($Group in @($Container.Group))
    {
        Parse-LUGGroup `
            -Result $Result `
            -Group $Group `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Parse-LUGGroup {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Group,

        [string]$GPOName,

        [string]$Class
    )

    $GroupName =
        Get-CleanText $Group.name

    if (-not $GroupName)
    {
        $GroupName =
            Get-CleanText `
                $Group.Properties.groupName
    }

    $Members = Get-LUGMembers -Group $Group

    Add-NormalizedSetting `
        -Result $Result `
        -GPOName $GPOName `
        -Class $Class `
        -Extension "Local Users and Groups" `
        -Category "Local Group Membership" `
        -SettingName $GroupName `
        -Value $Members `
        -State "Configured"

    #
    # Optional individual membership records
    #

    Parse-LUGMemberActions `
        -Result $Result `
        -Group $Group `
        -GroupName $GroupName `
        -GPOName $GPOName `
        -Class $Class
}

function Get-LUGMembers {

    [CmdletBinding()]
    param(
        [object]$Group
    )

    $Items = @()

    $Properties =
        Get-XmlProperty `
            -Object $Group `
            -PropertyName 'Properties'

    if ($Properties)
    {
        $MembersNode =
            Get-XmlProperty `
                -Object $Properties `
                -PropertyName 'Members'

        if ($MembersNode)
        {
            foreach (
                $Member in
                (Get-SafeArray (
                    Get-XmlProperty `
                        -Object $MembersNode `
                        -PropertyName 'Member'
                ))
            )
            {
                $Action = ""

                if (
                    Test-Property `
                        -Object $Member `
                        -PropertyName 'action'
                )
                {
                    $Action =
                        Get-CleanText `
                            $Member.action
                }

                $Name = ""

                if (
                    Test-Property `
                        -Object $Member `
                        -PropertyName 'name'
                )
                {
                    $Name =
                        Get-CleanText `
                            $Member.name
                }

                $Items += (
                    "{0}: {1}" -f
                    $Action,
                    $Name
                )
            }
        }
    }

    if (
        @($Items).Count -eq 0
    )
    {
        return "<NoMembers>"
    }

    return (
        $Items -join "; "
    )
}

function Parse-LUGMemberActions {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Group,

        [string]$GroupName,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($Member in @($Group.Properties.Members.Member))
    {
        $Action =
            Get-CleanText `
                $Member.action

        $MemberName =
            Get-CleanText `
                $Member.name

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Local Users and Groups" `
            -Category "Membership Actions" `
            -SettingName (
                "$GroupName [$Action]"
            ) `
            -Value $MemberName `
            -State "Configured"
    }
}

#=====================================================
# NRPT Parsers
#=====================================================

function Parse-NRPT {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    if ($null -eq $Extension)
    {
        return
    }

    #
    # Global Settings
    #

    if (
        Test-Property `
            -Object $Extension `
            -PropertyName 'Global'
    )
    {
        Parse-NRPTGlobal `
            -Result $Result `
            -Node $Extension.Global `
            -GPOName $GPOName `
            -Class $Class
    }

    #
    # Rule Nodes
    #

    foreach (
        $Rule in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'Rule'
        ))
    )
    {
        Parse-NRPTRule `
            -Result $Result `
            -Rule $Rule `
            -GPOName $GPOName `
            -Class $Class
    }

    #
    # NamespaceRule Nodes
    #

    foreach (
        $Rule in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'NamespaceRule'
        ))
    )
    {
        Parse-NRPTRule `
            -Result $Result `
            -Rule $Rule `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Parse-NRPTGlobal {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Node,

        [string]$GPOName,

        [string]$Class
    )

    if ($null -eq $Node)
    {
        return
    }

    foreach ($Child in (Get-SafeArray $Node.ChildNodes))
    {
        if (
            [string]::IsNullOrWhiteSpace(
                $Child.Name
            )
        )
        {
            continue
        }

        $Value = "<NotConfigured>"

        if (-not [string]::IsNullOrWhiteSpace($Child.InnerText))
        {
            $Value =
                Get-CleanText `
                    $Child.InnerText
        }

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "NRPT" `
            -Category "Global Settings" `
            -SettingName (
                Get-CleanText $Child.Name
            ) `
            -Value $Value `
            -State "Configured"
    }
}

function Parse-NRPTRule {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Rule,

        [string]$GPOName,

        [string]$Class
    )

    $Namespace = $null

    if ($Rule.Namespace)
    {
        $Namespace =
            Get-CleanText $Rule.Namespace
    }

    if (-not $Namespace)
    {
        $Namespace =
            "<UnknownNamespace>"
    }

    $Values =
        New-Object System.Collections.ArrayList

    foreach ($Child in $Rule.ChildNodes)
    {
        if (-not $Child.Name)
        {
            continue
        }

        if ($Child.Name -eq "Namespace")
        {
            continue
        }

        [void]$Values.Add(
            "{0}={1}" -f
            (Get-CleanText $Child.Name),
            (Get-CleanText $Child.InnerText)
        )
    }

    Add-NormalizedSetting `
        -Result $Result `
        -GPOName $GPOName `
        -Class $Class `
        -Extension "NRPT" `
        -Category "Namespace Rules" `
        -SettingName $Namespace `
        -Value ($Values -join "; ") `
        -State "Configured"
}

#=====================================================
# Deprecated Rules Parsers
#=====================================================

function Import-DeprecatedPolicyReference {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Policies      = @()
    $RegistryPaths = @()

    if (-not (Test-Path $Path))
    {
        Write-Warning "Deprecated policy file not found: $Path"

        $script:DeprecatedPolicyReference = @{
            Policies      = @()
            RegistryPaths = @()
        }

        return
    }

    foreach ($Line in (Get-Content $Path))
    {
        $CurrentLine = $Line.Trim()

        if ([string]::IsNullOrWhiteSpace($CurrentLine))
        {
            continue
        }

        if ($CurrentLine.StartsWith("- "))
        {
            $Value = $CurrentLine.Substring(2)

            if ($Value -match '^Software\\')
            {
                $RegistryPaths += $Value
            }
            else
            {
                $Policies += $Value
            }
        }
    }

    $script:DeprecatedPolicyReference = @{
        Policies      = $Policies
        RegistryPaths = $RegistryPaths
    }
}

function Get-DeprecatedPolicyMatches {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Settings
    )

    foreach ($Setting in $Settings)
    {
        if (
            $script:DeprecatedPolicyReference.Policies `
                -contains `
                $Setting.SettingName
        )
        {
            [PSCustomObject]@{
                GPOName     = $Setting.GPOName
                Class       = $Setting.Class
                Category    = $Setting.Category
                SettingName = $Setting.SettingName
                Value       = $Setting.Value
                Reason      = "Deprecated Policy"
            }

            continue
        }

        foreach (
            $RegistryPath in
            $script:DeprecatedPolicyReference.RegistryPaths
        )
        {
            if (
                $Setting.Category -like "*$RegistryPath*"
            )
            {
                [PSCustomObject]@{
                    GPOName     = $Setting.GPOName
                    Class       = $Setting.Class
                    Category    = $Setting.Category
                    SettingName = $Setting.SettingName
                    Value       = $Setting.Value
                    Reason      = "Deprecated Registry Technology"
                }

                break
            }
        }
    }
}

#=====================================================
# Extension Discovery Wrappers
#=====================================================

function Invoke-SecurityParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        $Section,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($ExtensionData in $Section.ExtensionData)
    {
        if (
            $ExtensionData.Name -eq "Security"
        )
        {
            Parse-SecuritySettings `
                -Result $Result `
                -Extension $ExtensionData.Extension `
                -GPOName $GPOName `
                -Class $Class
        }
    }
}

function Invoke-AuditParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        $Section,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($ExtensionData in @($Section.ExtensionData))
    {
        if (-not $ExtensionData)
        {
            continue
        }

        if (
            $ExtensionData.Name -like "*Audit*"
        )
        {
            Parse-AdvancedAuditPolicies `
                -Result $Result `
                -Extension $ExtensionData.Extension `
                -GPOName $GPOName `
                -Class $Class
        }
    }
}

function Invoke-RegistryParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        $Section,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($ExtensionData in @($Section.ExtensionData))
    {
        if ($ExtensionData.Name -ne "Registry")
        {
            continue
        }

        Parse-AdministrativeTemplates `
            -Result $Result `
            -Extension $ExtensionData.Extension `
            -GPOName $GPOName `
            -Class $Class

        Parse-RegistrySettings `
            -Result $Result `
            -Extension $ExtensionData.Extension `
            -GPOName $GPOName `
            -Class $Class
    }
}

function Invoke-FirewallParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        $Section,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($ExtensionData in @($Section.ExtensionData))
    {
        if (
            $ExtensionData.Name -eq
            "Windows Firewall"
        )
        {
            Parse-WindowsFirewall `
                -Result $Result `
                -Extension $ExtensionData.Extension `
                -GPOName $GPOName `
                -Class $Class
        }
    }
}

function Invoke-LUGParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        $Section,

        [string]$GPOName,

        [string]$Class
    )

    foreach ($ExtensionData in @($Section.ExtensionData))
    {
        if (
            $ExtensionData.Name -eq
            "Local Users and Groups"
        )
        {
            Parse-LocalUsersAndGroups `
                -Result $Result `
                -Extension $ExtensionData.Extension `
                -GPOName $GPOName `
                -Class $Class
        }
    }
}

function Invoke-NRPTParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Extension,

        [string]$GPOName,

        [string]$Class
    )

    Parse-NRPT `
        -Result $Result `
        -Extension $Extension `
        -GPOName $GPOName `
        -Class $Class
}

#=====================================================
# Main Orchestration
#=====================================================

function Invoke-GPOSectionParser {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$Section,

        [string]$Class,

        [string]$GPOName
    )

    $ExtensionDataCollection =
        Get-SafeArray (
            Get-XmlProperty `
                -Object $Section `
                -PropertyName 'ExtensionData'
        )

    foreach ($ExtensionData in $ExtensionDataCollection)
    {
        if ($null -eq $ExtensionData)
        {
            continue
        }

        $ExtensionName =
            Get-CleanText (
                Get-XmlProperty `
                    -Object $ExtensionData `
                    -PropertyName 'Name'
            )

        $Extension =
            Get-XmlProperty `
                -Object $ExtensionData `
                -PropertyName 'Extension'

        switch ($ExtensionName)
        {
            "Security" {
                Parse-SecuritySettings `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }

            "Advanced Audit Configuration" {
                Parse-AdvancedAuditPolicies `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }

            "Registry" {
                Parse-AdministrativeTemplates `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class

                Parse-RegistrySettings `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }

            "Windows Firewall" {
                Parse-WindowsFirewall `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }

            "Local Users and Groups" {
                Parse-LocalUsersAndGroups `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }

            "Name Resolution Policy" {
                Parse-NRPT `
                    -Result $Result `
                    -Extension $Extension `
                    -GPOName $GPOName `
                    -Class $Class
            }
        }
    }
}

function Parse-UnknownExtension {

    [CmdletBinding()]
    param(
        [ref]$Result,

        [object]$ExtensionData,

        [string]$Class,

        [string]$GPOName
    )

    [void]$Result.Value.Unclassified.Add(
        [PSCustomObject]@{
            GPOName   = $GPOName
            Class     = $Class
            Extension = (
                Get-CleanText `
                    $ExtensionData.Name
            )
            Reason    = "Unsupported Extension"
        }
    )
}

function Get-GPOSettingsFromXml {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$GPOName
    )

    if (-not (Test-Path $Path))
    {
        throw "File not found: $Path"
    }

    $Result =
        New-GPOParseResult

    try
    {
        [xml]$Xml =
            Get-Content `
                -Path $Path `
                -Encoding Unicode
    }
    catch
    {
        throw "Failed to load XML: $($_.Exception.Message)"
    }

    if (-not $Xml.GPO)
    {
        throw "Invalid GPO XML format."
    }

    try
    {
        #
        # Computer Configuration
        #

        if ($Xml.GPO.Computer)
        {
            Invoke-GPOSectionParser `
                -Result ([ref]$Result) `
                -Section $Xml.GPO.Computer `
                -Class "Computer" `
                -GPOName $GPOName
        }

        #
        # User Configuration
        #

        if ($Xml.GPO.User)
        {
            Invoke-GPOSectionParser `
                -Result ([ref]$Result) `
                -Section $Xml.GPO.User `
                -Class "User" `
                -GPOName $GPOName
        }
    }
    catch
    {
        Write-Host ""
        Write-Host "======================================="
        Write-Host "ERROR PROCESSING GPO"
        Write-Host "======================================="
        Write-Host ""

        Write-Host "GPO:"
        Write-Host $GPOName

        Write-Host ""
        Write-Host "XML:"
        Write-Host $Path

        Write-Host ""
        Write-Host "Exception:"
        Write-Host $_.Exception.Message

        Write-Host ""
        Write-Host "Script Line:"
        Write-Host $_.InvocationInfo.ScriptLineNumber

        Write-Host ""
        Write-Host "Position:"
        Write-Host $_.InvocationInfo.PositionMessage

        throw
    }

    return $Result
}

<#function Get-GPOSettingsFromXml {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$GPOName
    )

    trap
    {
        Write-Host ""
        Write-Host "======================================="
        Write-Host "PARSER EXCEPTION"
        Write-Host "======================================="
        Write-Host ""

        Write-Host "Exception:"
        Write-Host $_.Exception.Message

        Write-Host ""

        Write-Host "Line Number:"
        Write-Host $_.InvocationInfo.ScriptLineNumber

        Write-Host ""

        Write-Host "Position:"
        Write-Host $_.InvocationInfo.PositionMessage

        Write-Host ""

        Write-Host "Stack Trace:"
        Write-Host $_.ScriptStackTrace

        Write-Host ""

        continue
    }

    if (-not (Test-Path $Path))
    {
        throw "File not found: $Path"
    }

    $Result =
        New-GPOParseResult

    [xml]$Xml =
        Get-Content `
            -Path $Path `
            -Encoding Unicode

    if ($Xml.GPO.Computer)
    {
        Invoke-GPOSectionParser `
            -Result ([ref]$Result) `
            -Section $Xml.GPO.Computer `
            -Class "Computer" `
            -GPOName $GPOName
    }

    if ($Xml.GPO.User)
    {
        Invoke-GPOSectionParser `
            -Result ([ref]$Result) `
            -Section $Xml.GPO.User `
            -Class "User" `
            -GPOName $GPOName
    }

    return $Result
}#>

Export-ModuleMember -Function @(
    'Get-GPOSettingsFromXml',
    'Import-DeprecatedPolicyReference',
    'Get-DeprecatedPolicyMatches'
)
