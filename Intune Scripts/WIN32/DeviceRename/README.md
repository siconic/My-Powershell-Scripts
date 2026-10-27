# DeviceRename (Intune Win32 app)

Renames a computer to the organization's naming standard: a 3-character prefix
plus up to 10 characters of the BIOS serial number. A scheduled task runs the
rename at user logon and asks the user to restart.

## Files

| File | In the package | Purpose |
|---|---|---|
| `Settings.psd1` | Yes | Organization name and optional hostname prefix. Edit before packaging. |
| `Installer.ps1` | Yes | Install command. Copies the files, registers the task, records the install folder in the registry. |
| `Uninstall.ps1` | Yes | Uninstall command. Removes the task, the install folder and the registry key. |
| `RenameComputer.ps1` | Yes | The rename itself. Run by the scheduled task. |
| `RenameHost.xml` | Yes | Scheduled task definition. `__ORGNAME__` is replaced by the installer. |
| `ServiceUI.exe` | Yes | Microsoft MDT tool (x64) that shows the restart prompt in the user's session. |
| `detection.ps1` | No (uploaded separately) | Detection script. |

## Settings

Edit `Settings.psd1` before building the package:

```powershell
@{
    OrgName = 'COMPANY'      # C:\ProgramData\<OrgName> folder and restart message
    HostnamePrefix = ''      # optional fixed prefix, 1 to 5 characters; empty = first 3 characters of the current name
}
```

The settings are part of the `.intunewin` file. To change them later, edit the
file, rebuild the package and upload the new `.intunewin` to the app in Intune.
If you change `OrgName` on devices that already have the app, uninstall the old
version first (or use supersedence with uninstall), so the old
`C:\ProgramData\<old name>\RenameHost` folder is removed.

## How each script finds the settings at run time

| Script | Started by | Runs from | Finds the settings |
|---|---|---|---|
| `Installer.ps1` | Intune install command | The extracted package folder (`C:\Windows\IMECache\<app id>`) | `Settings.psd1` next to the script (`$PSScriptRoot`). |
| `RenameComputer.ps1` | Scheduled task, through ServiceUI.exe | `C:\ProgramData\<OrgName>\RenameHost` | `Settings.psd1` next to the script; the installer copies it there. The log folder is `..\Log` from that folder. |
| `Uninstall.ps1` | Intune uninstall command | The extracted package folder | Registry value `InstallFolder` (below). If it is missing, `Settings.psd1` next to the script. |
| `detection.ps1` | Intune detection | An Intune folder, not the package folder | Registry value `InstallFolder`. It cannot read `Settings.psd1`, because the detection script is uploaded on its own and the package files are not next to it. |

The installer writes these values to `HKLM\SOFTWARE\Packages\HostRename`:

- `InstallFolder`: for example `C:\ProgramData\COMPANY\RenameHost`
- `OrgName`

`RenameComputer.ps1` adds `OldHostname`, `NewHostname` and `Rename` there.

### 32-bit and 64-bit

The Intune Management Extension starts install and uninstall commands as a
32-bit process on 64-bit Windows. In a 32-bit process, `HKLM\SOFTWARE` is
redirected to `HKLM\SOFTWARE\WOW6432Node`. To keep every script on the same
registry key:

- `Installer.ps1` and `Uninstall.ps1` restart themselves in 64-bit PowerShell
  (`%WINDIR%\Sysnative\...\powershell.exe`) when they start as 32-bit.
- `detection.ps1` opens the 64-bit registry view directly, so either setting of
  "Run script as 32-bit process" works.
- `ServiceUI.exe` is x64, so `RenameComputer.ps1` runs in 64-bit PowerShell.

## Build the package

1. Download the Microsoft Win32 Content Prep Tool (`IntuneWinAppUtil.exe`).
2. Copy the six package files (all files above except `detection.ps1` and this
   README) to an empty source folder, for example `C:\Build\DeviceRename`.
   Extra files in the folder are harmless but become part of the package.
3. Run:

   ```
   IntuneWinAppUtil.exe -c "C:\Build\DeviceRename" -s Installer.ps1 -o "C:\Build\Output"
   ```

   This creates `C:\Build\Output\Installer.intunewin`.

## Intune app settings

Apps > Windows > Add > Windows app (Win32), then upload `Installer.intunewin`.

| Setting | Value |
|---|---|
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Installer.ps1` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1` |
| Install behavior | System |
| Device restart behavior | No specific action (the scheduled task asks the user to restart) |
| Return codes | Defaults (0 = success) |
| Detection rules | Use a custom detection script: `detection.ps1` |
| Run script as 32-bit process on 64-bit clients | No (Yes also works) |
| Enforce script signature check | No, unless the scripts are signed |

## Results and logs on the device

- Log: `C:\ProgramData\<OrgName>\Log\RenameInstall.log` (installer and every
  rename run)
- Registry: `HKLM\SOFTWARE\Packages\HostRename`
  (`Rename = 1` after a successful rename)
- Intune agent log: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log`

## Notes

- Detection reports the app as installed when the task and files are in place.
  It does not wait for the rename, because the rename needs the user to log on
  and restart.
- On a domain-joined or hybrid-joined device the rename also changes the AD
  computer object. It needs a reachable domain controller and permission for
  the computer account to rename itself. When it fails, the error is in the log
  and the task tries again at the next run.
