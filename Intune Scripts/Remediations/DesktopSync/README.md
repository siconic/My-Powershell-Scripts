# Desktop Sync (Intune remediation)

Keeps desktop shortcuts, a `Bat` folder and supporting files (icons, icon
DLL, wallpapers, an INI file) on devices in sync with a folder on a file
server.

| File | Purpose |
|---|---|
| `DesktopSyncDetection.ps1` | Detection script (placeholders) |
| `DesktopSyncRemediation.ps1` | Remediation script (placeholders) |
| `Build-LocalScripts.ps1` | Writes the deployable scripts with the real configuration to `Local\` |
| `Local\` | Git-ignored. `Configuration.txt` holds the real server and file names; the built scripts go here |

## What it does

- Shortcuts and the `Bat` folder go to the **Public desktop**
  (`C:\Users\Public\Desktop`). Every user sees them, including new users and
  users with OneDrive Known Folder Move. Standard users cannot delete them.
- Each file is compared with its source by **SHA256 hash**. A file is fixed
  when it is missing, has different content, or does not inherit permissions
  from its folder.
- Files for the Chrome folder are only managed when `chrome.exe` exists. The
  Chrome folder is never created.
- With `$RemoveProfileCopies = $true`, copies of the Public desktop files in
  user profile desktops (including `OneDrive*\Desktop` and the Default
  profile) are reported and deleted, so users do not see each icon twice.
  Only files with the managed names are deleted. A managed subfolder (`Bat`)
  in a profile desktop is deleted only when it is empty afterwards.
- A destination file that is in use (for example an icon DLL loaded by
  Explorer) is renamed to `<name>.old` and the new file is copied in its
  place. The `.old` file is deleted on a later run.
- When the share is not reachable, both scripts exit 0 and say so in the
  output. Intune shows this text in the detection output column.
- Both scripts restart themselves in 64-bit PowerShell when started in
  32-bit PowerShell.

## Configuration

The `Configuration` region (file server path, file list) and the
`Shared functions` region must be identical in both scripts.

1. Put the real `Configuration` region in `Local\Configuration.txt`.
2. Run `Build-LocalScripts.ps1`.
3. Upload `Local\DesktopSyncDetection.ps1` and
   `Local\DesktopSyncRemediation.ps1` to Intune.

Each `$ManagedFiles` entry has `Source` (path relative to `$ShareRoot`),
`Destination` (full path on the device) and optionally `RequirePath` (the
entry is only managed when that path exists).

## Intune settings

| Setting | Value |
|---|---|
| Run this script using the logged-on credentials | No (runs as SYSTEM) |
| Enforce script signature check | No (unless you sign the scripts) |
| Run script in 64-bit PowerShell | Yes |

## Requirements

- The script runs as SYSTEM and reaches the share as the **computer
  account**. `Domain Computers` (or a group containing the devices) needs Read
  on the share and on the NTFS folders.
- Entra-only (not hybrid) devices have no AD computer account and cannot read
  the share. On those devices the scripts report "share is not reachable".
- Anyone with write access to the share can place files (including a DLL in
  `System32`) on every device as SYSTEM. Limit write access to admins.
- Files that rarely change (icons, DLL, wallpapers, INI) can be deployed as a
  Win32 app instead, so they do not depend on the file server.

## Log

`C:\ProgramData\Logs\DesktopSync\DesktopSyncRemediation.log` (renamed to
`.old` when it grows over 1 MB).
