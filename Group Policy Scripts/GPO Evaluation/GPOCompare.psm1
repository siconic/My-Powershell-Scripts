#==========================================================
# Version 3.4
#
# Changelog:
#   3.4 - No changes to this module. Version kept in lockstep with
#         Compare-GPOXml.ps1 (-ExcelOutput workbook added).
#   3.3 - No changes to this module. Version kept in lockstep with
#         Compare-GPOXml.ps1 (output file name prefix added).
#   3.2 - Replaced all 13 uses of the "{0}={1}" -f composite-format
#         operator with plain string interpolation. This was the reported
#         source of "error formatting a string: index (zero based) must be
#         greater than or equal to zero..." - string interpolation cannot
#         throw that exception (there is no template/argument-list
#         mechanism involved), so this removes the entire exception class
#         regardless of which of the 13 call sites was actually failing.
#   3.1 - Unsupported-extension Unclassified rows now carry a SettingName,
#         Value, and State per item (Get-UnknownExtensionItems), instead of
#         one blank row per whole extension; parser-error Reason text now
#         includes the module line number that threw.
#   3.0 - Full rework - see Compare-GPOXml.ps1's changelog for the paired
#         script-level changes shipped alongside this version.
#
# Module Globals
#==========================================================
Set-StrictMode -Version Latest

$script:ASRRuleMap = @{}

$script:DeprecatedPolicyReference = @{
    Entries = @()
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

    # XML nodes: use their text content. ToString() on an XmlElement that has
    # attributes or child nodes returns the type name instead of the text.
    if ($Text -is [System.Xml.XmlNode])
    {
        $Value = $Text.InnerText
    }
    else
    {
        $Value = $Text.ToString()
    }

    $Value = $Value -replace '\s+',' '

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

function New-UnclassifiedRecord {

    [CmdletBinding()]
    param(
        [string]$GPOName,
        [string]$Class,
        [string]$Extension,
        [string]$Category,
        [string]$SettingName,
        [string]$Value,
        [string]$State,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    # Single schema for every Unclassified record so Export-Csv keeps all columns.
    [PSCustomObject]@{
        GPOName     = $GPOName
        Class       = $Class
        Extension   = $Extension
        Category    = $Category
        SettingName = $SettingName
        Value       = $Value
        State       = $State
        Reason      = $Reason
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

    $SettingName = Get-CleanText $SettingName
    $Value       = Get-CleanText $Value
    $State       = Get-CleanText $State
    $Category    = Get-CleanText $Category
    $Extension   = Get-CleanText $Extension

    if ([string]::IsNullOrWhiteSpace($SettingName))
    {
        [void]$Result.Value.Unclassified.Add(
            (
                New-UnclassifiedRecord `
                    -GPOName $GPOName `
                    -Class $Class `
                    -Extension $Extension `
                    -Category $Category `
                    -Value $Value `
                    -State $State `
                    -Reason "Missing Setting Name"
            )
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

    return @($Object)
}

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

    #
    # Report any Security sub-section this module does not parse
    # (for example legacy audit policy, event log, restricted groups,
    # file system or registry permissions) instead of dropping it silently.
    #
    if ($Extension -is [System.Xml.XmlNode])
    {
        $Handled = @(
            'Account',
            'UserRightsAssignment',
            'SecurityOptions',
            'SystemServices'
        )

        $Reported = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($Child in $Extension.ChildNodes)
        {
            if ($Child.NodeType -ne [System.Xml.XmlNodeType]::Element)
            {
                continue
            }

            $ChildName = $Child.LocalName

            if ($Handled -contains $ChildName)
            {
                continue
            }

            if (-not $Reported.Add($ChildName))
            {
                continue
            }

            [void]$Result.Value.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -GPOName $GPOName `
                        -Class $Class `
                        -Extension "Security" `
                        -Category $ChildName `
                        -SettingName $ChildName `
                        -Reason "Unsupported Security section"
                )
            )
        }
    }
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
        $Members = [System.Collections.ArrayList]::new()

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
                Get-CleanText (
                    Get-XmlProperty `
                        -Object $Member `
                        -PropertyName 'Name'
                )

            # Unresolved accounts may have no name; fall back to the SID.
            if ([string]::IsNullOrWhiteSpace($MemberName))
            {
                $MemberName =
                    Get-CleanText (
                        Get-XmlProperty `
                            -Object $Member `
                            -PropertyName 'SID'
                    )
            }

            if (-not [string]::IsNullOrWhiteSpace($MemberName))
            {
                [void]$Members.Add($MemberName)
            }
        }

        if ($Members.Count -eq 0)
        {
            [void]$Members.Add("<NoAssignments>")
        }

        # Sorted so the same members in a different order compare as equal.
        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Security" `
            -Category "User Rights Assignment" `
            -SettingName (
                Get-CleanText (
                    Get-XmlProperty `
                        -Object $Assignment `
                        -PropertyName 'Name'
                )
            ) `
            -Value ((@($Members) | Sort-Object) -join "; ") `
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
                    (@($Entries) | Sort-Object) -join "; "
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
                        $Fields += "$(Get-CleanText $Field.Name)=$(Get-CleanText $Field.Value)"
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
                    (@($Entries) | Sort-Object) -join "; "
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

        # A blank name is reported by Add-NormalizedSetting as Unclassified.

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
        Get-CleanText (
            Get-XmlProperty `
                -Object $Audit `
                -PropertyName 'SubcategoryName'
        )

    $PolicyTarget =
        Get-CleanText (
            Get-XmlProperty `
                -Object $Audit `
                -PropertyName 'PolicyTarget'
        )

    $AuditValue =
        Get-CleanText (
            Get-XmlProperty `
                -Object $Audit `
                -PropertyName 'SettingValue'
        )

    $Value = Convert-AuditValue $AuditValue

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
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        return "<NoValue>"
    }

    $Number = 0

    if (-not [int]::TryParse($Value, [ref]$Number))
    {
        return "Unknown ($Value)"
    }

    switch ($Number)
    {
        0 { "No Auditing" }

        1 { "Success" }

        2 { "Failure" }

        3 { "Success and Failure" }

        default { "Unknown ($Number)" }
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
        Get-CleanText (
            Get-XmlProperty `
                -Object $Policy `
                -PropertyName 'Name'
        )

    $Category =
        Get-CleanText (
            Get-XmlProperty `
                -Object $Policy `
                -PropertyName 'Category'
        )

    $State =
        Get-CleanText (
            Get-XmlProperty `
                -Object $Policy `
                -PropertyName 'State'
        )

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
            "$(Get-CleanText (Get-XmlProperty $Item 'Name'))=$(Get-CleanText (Get-XmlProperty $Item 'State'))"
        )
    }

    #
    # EditText
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'EditText')))
    {
        [void]$Values.Add(
            "$(Get-CleanText (Get-XmlProperty $Item 'Name'))=$(Get-CleanText (Get-XmlProperty $Item 'Value'))"
        )
    }

    #
    # Numeric
    #

    foreach ($Item in (Get-SafeArray (Get-XmlProperty $Policy 'Numeric')))
    {
        [void]$Values.Add(
            "$(Get-CleanText (Get-XmlProperty $Item 'Name'))=$(Get-CleanText (Get-XmlProperty $Item 'Value'))"
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
            "$(Get-CleanText (Get-XmlProperty $Item 'Name'))=$SelectedValue"
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
                $Entries += "$Name=$Data"
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
                "$(Get-CleanText (Get-XmlProperty $ListBox 'Name'))=$((@($Entries) | Sort-Object) -join '; ')"
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
                "$(Get-CleanText (Get-XmlProperty $Item 'Name'))=$((@($Entries) | Sort-Object) -join '; ')"
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
                "$($Child.Name)=$(Get-CleanText $Child.InnerText)"
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
                    Get-SafeArray $MultiString | ForEach-Object { Get-CleanText $_ } | Sort-Object
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
        -ProfileNode (Get-XmlProperty -Object $Extension -PropertyName 'DomainProfile') `
        -ProfileName "Domain" `
        -GPOName $GPOName `
        -Class $Class

    Parse-FirewallProfile `
        -Result $Result `
        -ProfileNode (Get-XmlProperty -Object $Extension -PropertyName 'PrivateProfile') `
        -ProfileName "Private" `
        -GPOName $GPOName `
        -Class $Class

    Parse-FirewallProfile `
        -Result $Result `
        -ProfileNode (Get-XmlProperty -Object $Extension -PropertyName 'PublicProfile') `
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

    foreach (
        $Rule in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'InboundFirewallRules'
        ))
    )
    {
        Parse-FirewallRule `
            -Result $Result `
            -Rule $Rule `
            -Direction "Inbound" `
            -GPOName $GPOName
    }

    foreach (
        $Rule in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Extension `
                -PropertyName 'OutboundFirewallRules'
        ))
    )
    {
        Parse-FirewallRule `
            -Result $Result `
            -Rule $Rule `
            -Direction "Outbound" `
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
        Get-XmlProperty `
            -Object $Extension `
            -PropertyName 'LocalUsersAndGroups'

    if ($null -eq $Container)
    {
        return
    }

    foreach (
        $Group in
        (Get-SafeArray (
            Get-XmlProperty `
                -Object $Container `
                -PropertyName 'Group'
        ))
    )
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

    $GroupName = ""

    if (Test-Property -Object $Group -PropertyName 'name')
    {
        $GroupName = Get-CleanText $Group.name
    }

    if ([string]::IsNullOrWhiteSpace($GroupName))
    {
        $Properties =
            Get-XmlProperty `
                -Object $Group `
                -PropertyName 'Properties'

        if (
            $null -ne $Properties -and
            (Test-Property -Object $Properties -PropertyName 'groupName')
        )
        {
            $GroupName = Get-CleanText $Properties.groupName
        }
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
    # Individual membership records
    #
    Parse-LUGMemberActions `
        -Result $Result `
        -Group $Group `
        -GroupName $GroupName `
        -GPOName $GPOName `
        -Class $Class
}

function Get-LUGMemberList {

    [CmdletBinding()]
    param(
        [object]$Group
    )

    $List = [System.Collections.ArrayList]::new()

    $Properties =
        Get-XmlProperty `
            -Object $Group `
            -PropertyName 'Properties'

    if ($null -eq $Properties)
    {
        return @()
    }

    $MembersNode =
        Get-XmlProperty `
            -Object $Properties `
            -PropertyName 'Members'

    if ($null -eq $MembersNode)
    {
        return @()
    }

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
        $Name   = ""

        if (Test-Property -Object $Member -PropertyName 'action')
        {
            $Action = Get-CleanText $Member.action
        }

        if (Test-Property -Object $Member -PropertyName 'name')
        {
            $Name = Get-CleanText $Member.name
        }

        [void]$List.Add(
            [PSCustomObject]@{
                Action = $Action
                Name   = $Name
            }
        )
    }

    return $List
}

function Get-LUGMembers {

    [CmdletBinding()]
    param(
        [object]$Group
    )

    # Sorted so member order in the XML does not affect comparisons.
    $Items = @(
        @(Get-LUGMemberList -Group $Group) |
        ForEach-Object {
            "$($_.Action): $($_.Name)"
        } |
        Sort-Object
    )

    if ($Items.Count -eq 0)
    {
        return "<NoMembers>"
    }

    return ($Items -join "; ")
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

    # One record per member. The member is part of the setting name and the
    # action is the value, so several members with the same action are separate
    # settings (not one setting with conflicting values), and the same member
    # with a different action in another GPO is a real conflict.
    foreach ($Member in @(Get-LUGMemberList -Group $Group))
    {
        if ([string]::IsNullOrWhiteSpace($Member.Name))
        {
            continue
        }

        $Action = $Member.Action

        if ([string]::IsNullOrWhiteSpace($Action))
        {
            $Action = "<NoAction>"
        }

        Add-NormalizedSetting `
            -Result $Result `
            -GPOName $GPOName `
            -Class $Class `
            -Extension "Local Users and Groups" `
            -Category "Membership Actions" `
            -SettingName "$GroupName member: $($Member.Name)" `
            -Value $Action `
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

    $Namespace =
        Get-CleanText (
            Get-XmlProperty `
                -Object $Rule `
                -PropertyName 'Namespace'
        )

    if ([string]::IsNullOrWhiteSpace($Namespace))
    {
        $Namespace = "<UnknownNamespace>"
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
            "$(Get-CleanText $Child.Name)=$(Get-CleanText $Child.InnerText)"
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

    # Reads the table rows of DeprecatedPoliciesReference.md:
    #
    # | Technology | MatchType | Pattern | Status | Replacement | CategoryFilter |
    #
    # MatchType:
    #   Name          SettingName equals Pattern (case-insensitive).
    #                 If CategoryFilter is set, Category must equal it as well.
    #   Category      Category contains Pattern (case-insensitive).
    #   RegistryPath  Registry Settings key path contains Pattern (case-insensitive).
    #
    # Everything that is not a table row is ignored.

    $script:DeprecatedPolicyReference = @{
        Entries = @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        Write-Warning "Deprecated policy reference file not found: $Path"
        return
    }

    $ValidMatchTypes = @('Name', 'Category', 'RegistryPath')
    $Entries = [System.Collections.ArrayList]::new()

    foreach ($Line in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $CurrentLine = $Line.Trim()

        if (-not $CurrentLine.StartsWith('|'))
        {
            continue
        }

        $Cells = @(
            $CurrentLine.Trim('|').Split('|') |
            ForEach-Object { $_.Trim() }
        )

        if ($Cells.Count -lt 5)
        {
            continue
        }

        # Header row and separator row
        if ($Cells[0] -eq 'Technology')
        {
            continue
        }

        if ($Cells[0] -match '^:?-{3,}:?$')
        {
            continue
        }

        $MatchType = $Cells[1]
        $Pattern   = $Cells[2]

        if ($ValidMatchTypes -notcontains $MatchType)
        {
            Write-Warning "Deprecated policy reference: unknown MatchType '$MatchType' for '$($Cells[0])'. Row skipped."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Pattern))
        {
            continue
        }

        $CategoryFilter = ''

        if ($Cells.Count -ge 6)
        {
            $CategoryFilter = $Cells[5]
        }

        if ($MatchType -eq 'RegistryPath')
        {
            $Pattern = $Pattern -replace '^(HKLM|HKCU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER)\\', ''
        }

        [void]$Entries.Add(
            [PSCustomObject]@{
                Technology     = $Cells[0]
                MatchType      = $MatchType
                Pattern        = $Pattern
                Status         = $Cells[3]
                Replacement    = $Cells[4]
                CategoryFilter = $CategoryFilter
            }
        )
    }

    $script:DeprecatedPolicyReference = @{
        Entries = @($Entries)
    }
}

function Get-DeprecatedPolicyMatches {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Settings
    )

    $Entries = @($script:DeprecatedPolicyReference.Entries)

    if ($Entries.Count -eq 0)
    {
        return
    }

    $Ignore = [System.StringComparison]::OrdinalIgnoreCase

    foreach ($Setting in $Settings)
    {
        $SettingName = [string]$Setting.SettingName
        $Category    = [string]$Setting.Category

        foreach ($Entry in $Entries)
        {
            $IsMatch = $false

            switch ($Entry.MatchType)
            {
                'Name' {
                    if ([string]::Equals($SettingName, $Entry.Pattern, $Ignore))
                    {
                        $IsMatch = $true

                        if (
                            -not [string]::IsNullOrWhiteSpace($Entry.CategoryFilter) -and
                            -not [string]::Equals($Category, $Entry.CategoryFilter, $Ignore)
                        )
                        {
                            $IsMatch = $false
                        }
                    }
                }

                'Category' {
                    if ($Category.IndexOf($Entry.Pattern, $Ignore) -ge 0)
                    {
                        $IsMatch = $true
                    }
                }

                'RegistryPath' {
                    if (
                        $Setting.Extension -eq 'Registry Settings' -and
                        $Category.IndexOf($Entry.Pattern, $Ignore) -ge 0
                    )
                    {
                        $IsMatch = $true
                    }
                }
            }

            if ($IsMatch)
            {
                [PSCustomObject]@{
                    GPOName                = $Setting.GPOName
                    Class                  = $Setting.Class
                    Extension              = $Setting.Extension
                    Category               = $Setting.Category
                    SettingName            = $Setting.SettingName
                    Value                  = $Setting.Value
                    Technology             = $Entry.Technology
                    MatchType              = $Entry.MatchType
                    Status                 = $Entry.Status
                    RecommendedReplacement = $Entry.Replacement
                    Reason                 = "Deprecated: $($Entry.Technology)"
                }

                break
            }
        }
    }
}

#=====================================================
# Extension Discovery Wrappers
#=====================================================

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

        # An error in one extension is recorded and does not discard the
        # rest of the GPO.
        try
        {
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

                default {
                    Parse-UnknownExtension `
                        -Result $Result `
                        -ExtensionData $ExtensionData `
                        -Class $Class `
                        -GPOName $GPOName
                }
            }
        }
        catch
        {
            $ErrorText = $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber

            [void]$Result.Value.Unclassified.Add(
                (
                    New-UnclassifiedRecord `
                        -GPOName $GPOName `
                        -Class $Class `
                        -Extension $ExtensionName `
                        -SettingName $ExtensionName `
                        -Reason "Parser error (module line $ErrorLine): $ErrorText"
                )
            )
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

    $ExtensionName =
        Get-CleanText (
            Get-XmlProperty `
                -Object $ExtensionData `
                -PropertyName 'Name'
        )

    if ([string]::IsNullOrWhiteSpace($ExtensionName))
    {
        $ExtensionName = "<UnnamedExtension>"
    }

    # An unsupported extension (Scheduled Tasks, Scripts, Drive Maps, Folder
    # Redirection, and so on) can contain several distinct items. Enumerate
    # them heuristically (an XML attribute or child element commonly used to
    # name an item, plus its other attributes/text as a value) so each gets
    # its own identifiable row instead of one blank row for the whole
    # extension.
    $Items = @(Get-UnknownExtensionItems -ExtensionData $ExtensionData)

    if ($Items.Count -eq 0)
    {
        [void]$Result.Value.Unclassified.Add(
            (
                New-UnclassifiedRecord `
                    -GPOName $GPOName `
                    -Class $Class `
                    -Extension $ExtensionName `
                    -Reason "Unsupported Extension"
            )
        )

        return
    }

    foreach ($Item in $Items)
    {
        [void]$Result.Value.Unclassified.Add(
            (
                New-UnclassifiedRecord `
                    -GPOName $GPOName `
                    -Class $Class `
                    -Extension $ExtensionName `
                    -SettingName $Item.Name `
                    -Value $Item.Value `
                    -State $Item.State `
                    -Reason "Unsupported Extension"
            )
        )
    }
}

function Get-UnknownExtensionItems {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ExtensionData
    )

    $Items = [System.Collections.Generic.List[object]]::new()

    if ($ExtensionData -isnot [System.Xml.XmlNode])
    {
        return $Items
    }

    # Common naming conventions across GPP/extension schemas: a "name"
    # attribute on an item element, or a child element that identifies it.
    $NameChildCandidates = @('Name', 'FileName', 'TaskName', 'Command', 'Path')

    foreach ($Node in $ExtensionData.SelectNodes(".//*"))
    {
        $ItemName = $null

        if ($null -ne $Node.Attributes -and $null -ne $Node.Attributes['name'])
        {
            $ItemName = Get-CleanText $Node.Attributes['name'].Value
        }

        if ([string]::IsNullOrWhiteSpace($ItemName))
        {
            foreach ($Candidate in $NameChildCandidates)
            {
                $Child = $Node.SelectSingleNode($Candidate)

                if ($null -ne $Child -and -not [string]::IsNullOrWhiteSpace($Child.InnerText))
                {
                    $ItemName = Get-CleanText $Child.InnerText
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($ItemName))
        {
            continue
        }

        # Value: the item's other attributes (GPP items are usually
        # attribute-driven - Drive Maps, Shortcuts, INI files, Environment
        # Variables, and so on all render as <Item attr1="x" attr2="y" ...>).
        # "action" is reported separately as State (GPP's C/R/U/D convention);
        # "name" is dropped since it's already the SettingName.
        $AttributeParts = [System.Collections.Generic.List[string]]::new()
        $StateValue     = ""

        if ($null -ne $Node.Attributes)
        {
            foreach ($Attribute in $Node.Attributes)
            {
                if ($Attribute.Name -ieq 'name')
                {
                    continue
                }

                if ($Attribute.Name -ieq 'action')
                {
                    $StateValue = Get-CleanText $Attribute.Value
                    continue
                }

                [void]$AttributeParts.Add(
                    "$($Attribute.Name)=$(Get-CleanText $Attribute.Value)"
                )
            }
        }

        $ValueText = (@($AttributeParts) | Sort-Object) -join "; "

        if ([string]::IsNullOrWhiteSpace($ValueText))
        {
            # No attributes to fall back on (e.g. Scripts' <Command>/
            # <Parameters> style extensions) - use the node's own text
            # instead, unless that IS the name we already captured.
            $DirectText = Get-CleanText $Node.InnerText

            if (-not [string]::IsNullOrWhiteSpace($DirectText) -and $DirectText -ne $ItemName)
            {
                $ValueText = $DirectText
            }
        }

        [void]$Items.Add(
            [PSCustomObject]@{
                Name  = $ItemName
                Value = $ValueText
                State = $StateValue
            }
        )
    }

    return @($Items)
}

function Get-GPOSettingsFromXml {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$GPOName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "File not found: $Path"
    }

    $Result = New-GPOParseResult

    # XmlDocument.Load(Stream) detects the file encoding (UTF-8 / UTF-16)
    # from the byte order mark or XML declaration.
    $Xml    = New-Object System.Xml.XmlDocument
    $Stream = $null

    try
    {
        $ResolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $Stream       = [System.IO.File]::OpenRead($ResolvedPath)

        $Xml.XmlResolver = $null
        $Xml.Load($Stream)
    }
    catch
    {
        throw "Failed to load XML: $($_.Exception.Message)"
    }
    finally
    {
        if ($null -ne $Stream)
        {
            $Stream.Dispose()
        }
    }

    $GpoNode = $Xml.DocumentElement

    if ($null -eq $GpoNode -or $GpoNode.LocalName -ne "GPO")
    {
        throw "Invalid GPO XML format."
    }

    try
    {
        #
        # Computer Configuration
        #
        $ComputerNode =
            Get-XmlProperty `
                -Object $GpoNode `
                -PropertyName 'Computer'

        if ($null -ne $ComputerNode)
        {
            Invoke-GPOSectionParser `
                -Result ([ref]$Result) `
                -Section $ComputerNode `
                -Class "Computer" `
                -GPOName $GPOName
        }

        #
        # User Configuration
        #
        $UserNode =
            Get-XmlProperty `
                -Object $GpoNode `
                -PropertyName 'User'

        if ($null -ne $UserNode)
        {
            Invoke-GPOSectionParser `
                -Result ([ref]$Result) `
                -Section $UserNode `
                -Class "User" `
                -GPOName $GPOName
        }
    }
    catch
    {
        throw "GPO '$GPOName' (script line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
    }

    return $Result
}

Export-ModuleMember -Function @(
    'Get-GPOSettingsFromXml',
    'Import-DeprecatedPolicyReference',
    'Get-DeprecatedPolicyMatches'
)
