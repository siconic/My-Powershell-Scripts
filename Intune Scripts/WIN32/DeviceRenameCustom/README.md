# DeviceRenameCustom (Intune Win32 app)

Renames a computer to a name that the logged-on user types in. This is a
variant of [DeviceRename](../DeviceRename/README.md), which builds the name
from a prefix and the BIOS serial number. Both packages use separate task
names, folders and registry keys, so they can exist on the same device (do not
assign both to the same device, or the second rename replaces the first).

A scheduled task runs at user logon (and every 15 minutes for one day after
logon). It shows a dialog with the current name, the user enters the new name,
confirms it, and is asked to restart.

## What the user sees

1. **Rename this computer** dialog: current name and a text box. Letters are
   converted to capitals as the user types. If `RequiredPrefix` is set, the
   box starts with it.
2. When the user clicks OK, the name is checked. If it is not valid, the reason
   is shown under the box and the dialog stays open. Rules:
   - 1 to 15 characters
   - only A to Z, 0 to 9 and the hyphen (no spaces)
   - not only digits, does not start or end with a hyphen
   - does not start with `DESKTOP-`, `LAPTOP-`, `WIN-` or `MININT-`
   - starts with `RequiredPrefix`, when it is set
3. **Confirm new computer name**: Yes renames the computer.
4. **Restart required**: Yes restarts now; No asks again in 15 minutes.

If the user clicks Cancel or No at step 1 or 3, nothing changes and the task
asks again at its next run. If the rename fails (for example, the name is
already used in Active Directory), the error is shown to the user, written to
the log, and the task asks again at its next run.

After the restart, the task sees that the active name is the chosen name and
disables itself. If the user enters the current name and chooses to keep it,
the task also disables itself.

## Files

| File | In the package | Purpose |
|---|---|---|
| `Settings.psd1` | Yes | Organization name and optional required prefix. Edit before packaging. |
| `Installer.ps1` | Yes | Install command. Copies the files, registers the task, records the install folder in the registry. |
| `Uninstall.ps1` | Yes | Uninstall command. Removes the task, the install folder and the registry key. |
| `RenameComputer.ps1` | Yes | Name dialog and rename. Run by the scheduled task. |
| `RenameHostCustom.xml` | Yes | Scheduled task definition. `__ORGNAME__` is replaced by the installer. |
| `ServiceUI.exe` | Yes | Microsoft MDT tool (x64) that shows the dialogs in the user's session. |
| `detection.ps1` | No (uploaded separately) | Detection script. |

## Settings

Edit `Settings.psd1` before building the package:

```powershell
@{
    OrgName = 'COMPANY'      # C:\ProgramData\<OrgName> folder and the dialog text
    RequiredPrefix = ''      # optional required start of the name, 1 to 14 characters; empty = any valid name
}
```

The settings are part of the `.intunewin` file. To change them later, edit the
file, rebuild the package and upload the new `.intunewin` to the app in Intune.

## Locations on the device

| Item | Value |
|---|---|
| Install folder | `C:\ProgramData\<OrgName>\RenameHostCustom` |
| Log | `C:\ProgramData\<OrgName>\Log\RenameCustom.log` (installer and every run) |
| Scheduled task | `\RenameHostCustom` |
| Registry | `HKLM\SOFTWARE\Packages\HostRenameCustom`: `InstallFolder`, `OrgName` (installer); `OldHostname`, `NewHostname`, `Rename = 1` (after a rename) |

The scripts find the settings and the install folder the same way as the
DeviceRename package; see the DeviceRename README for the details, including
the 32-bit and 64-bit handling.

## Build the package

1. Copy the six package files (all files above except `detection.ps1` and this
   README) to an empty source folder, for example `C:\Build\DeviceRenameCustom`.
2. Run:

   ```
   IntuneWinAppUtil.exe -c "C:\Build\DeviceRenameCustom" -s Installer.ps1 -o "C:\Build\Output"
   ```

## Intune app settings

| Setting | Value |
|---|---|
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Installer.ps1` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1` |
| Install behavior | System |
| Device restart behavior | No specific action (the scheduled task asks the user to restart) |
| Detection rules | Use a custom detection script: `detection.ps1` |
| Assignment | Available for enrolled devices (Company Portal) works well: the user installs it when they want to rename. Required also works. |

## Notes

- The dialog runs as SYSTEM in the user's session, so a standard user can
  rename the computer without admin rights. Assign the app only to the users
  or devices that are allowed to choose their own name.
- The name is not checked against Intune, Entra ID or Active Directory for
  duplicates before the rename. A duplicate in Active Directory makes the
  rename fail on a domain-joined device; Entra ID and Intune allow duplicates.
- Intune shows the new device name after the device restarts and syncs.
- To rename the same device again later, uninstall and reinstall the app (the
  uninstall removes the registry key that records the chosen name).
