# Desktop Sync (Intune remediation)

Keeps desktop shortcuts, desktop icons and supporting files (icons, icon
DLL, wallpapers, an INI file) on devices in line with a folder on a file
server. Version 2.0.

| File | Purpose |
|---|---|
| `DesktopSyncDetection.ps1` | Detection script (placeholders) |
| `DesktopSyncRemediation.ps1` | Remediation script (placeholders) |
| `Build-LocalScripts.ps1` | Writes the deployable scripts with the real configuration to `Local\` |
| `Local\` | Git-ignored. `Configuration.txt` holds the real server and file names; the built scripts go here |

## What it manages

The `Configuration` region has four sections.

| Section | Where | Source |
|---|---|---|
| 1. Default and user desktops: `$UserDesktopFiles` | `C:\Users\Default\Desktop` and the desktop of every user profile | Share |
| 1. Default and user desktops: `$UserDesktopShortcuts` (Office) | Same desktops | Created on the device, only when the Office program exists |
| 2. Public desktop: `$PublicDesktopFiles` | `C:\Users\Public\Desktop` | Share, only when the app is installed (`RequirePath`) |
| 3. User profile settings: `$DesktopIcons` | Each user's registry and the Default profile registry | Settings in the script |
| 4. System files: `$SystemFiles` | Full path per file | Share |

## How it works

- **User desktop folder:** read from the user's registry (`User Shell
  Folders\Desktop`), so a OneDrive Known Folder Move desktop is used when it
  is on. Falls back to `<profile>\Desktop`. Desktops redirected to a network
  path are skipped and listed in the output notes.
- **Registry hives:** for users who are not signed in, the script loads
  `NTUSER.DAT` under `HKEY_USERS\DesktopSync_N`, reads or writes the
  settings, and unloads it. This also happens in the detection script.
- **Desktop icons:** set in
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel`
  (0 = show, 1 = hide). Users see the change after the desktop refreshes or
  at the next sign-in.
- **File comparison:** a file is compliant when it exists, has the same
  SHA256 hash as the source and inherits permissions from its folder.
  Users can delete files on their own desktop; the next run puts them back.
- **Office shortcuts:** compliant when the shortcut exists and points to the
  installed program. Not created when Office is not installed.
- **Files in use:** a destination file that is in use (for example an icon
  DLL loaded by Explorer) is renamed to `<name>.old` and the new file is
  copied. The `.old` file is deleted on a later run.
- **Share not reachable:** only the Office shortcuts and desktop icons are
  checked and fixed. The output says that file checks were skipped.
- **32-bit start:** both scripts restart themselves in 64-bit PowerShell.
- **Not deleted:** files that are no longer in the configuration stay on the
  devices.

## Configuration

The `Configuration` and `Shared functions` regions must be identical in both
scripts.

1. Put the real `Configuration` region in `Local\Configuration.txt`.
2. Run `Build-LocalScripts.ps1`.
3. Upload `Local\DesktopSyncDetection.ps1` and
   `Local\DesktopSyncRemediation.ps1` to Intune.

Check the `RequirePath` values of the Public desktop entries against a
reference device. This lists the target of each shortcut on the Public
desktop:

```powershell
$Shell = New-Object -ComObject WScript.Shell; Get-ChildItem "$env:PUBLIC\Desktop\*.lnk" | ForEach-Object { "$($_.Name) -> $($Shell.CreateShortcut($_.FullName).TargetPath)" }
```

## Intune settings

| Setting | Value |
|---|---|
| Run this script using the logged-on credentials | No (runs as SYSTEM) |
| Enforce script signature check | No (unless you sign the scripts) |
| Run script in 64-bit PowerShell | Yes |

## Requirements and risks

- The script runs as SYSTEM and reaches the share as the **computer
  account**. `Domain Computers` (or a group containing the devices) needs Read
  on the share and on the NTFS folders. Entra-only devices have no AD
  computer account and cannot read the share.
- Anyone with write access to the share can place files (including a DLL in
  `System32`) on every device as SYSTEM. Limit write access to admins.
- Loading a signed-out user's `NTUSER.DAT` takes a moment. If that user
  signs in at exactly that time, Windows can give them a temporary profile.
  The hive is unloaded immediately after use to keep this window short.
- With OneDrive Known Folder Move, files copied to a user's desktop are
  uploaded to OneDrive and appear on the user's other devices.

## Log

`C:\ProgramData\Logs\DesktopSync\DesktopSyncRemediation.log` (renamed to
`.old` when it grows over 1 MB).
