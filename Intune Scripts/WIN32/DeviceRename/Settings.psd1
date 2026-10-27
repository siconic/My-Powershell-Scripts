# Settings for the DeviceRename Win32 app. Edit this file before you build the .intunewin package.
# Read by Installer.ps1 (from the package folder), Uninstall.ps1 (fallback only) and
# RenameComputer.ps1 (from C:\ProgramData\<OrgName>\RenameHost, where Installer.ps1 copies it).
# detection.ps1 does not read it; see README.md.
@{
    # Organization name. Used for the C:\ProgramData\<OrgName> folder and in the restart message.
    # Letters, digits, - and _ only.
    OrgName = 'COMPANY'

    # Optional fixed hostname prefix, for example a site code: 1 to 5 letters, digits or -.
    # Leave empty to use the first 3 characters of the current hostname.
    HostnamePrefix = ''
}
