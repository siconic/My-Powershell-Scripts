# Settings for the DeviceRenameCustom Win32 app. Edit this file before you build the .intunewin package.
# Read by Installer.ps1 (from the package folder), Uninstall.ps1 (fallback only) and
# RenameComputer.ps1 (from C:\ProgramData\<OrgName>\RenameHostCustom, where Installer.ps1 copies it).
# detection.ps1 does not read it; see README.md.
@{
    # Organization name. Used for the C:\ProgramData\<OrgName> folder and in the messages to the user.
    # Letters, digits, - and _ only.
    OrgName = 'COMPANY'

    # Optional required start of the new name, for example a site code: 1 to 14 letters, digits or -.
    # When set, the dialog fills it in and rejects names that do not start with it.
    # Leave empty to accept any valid name.
    RequiredPrefix = ''
}
