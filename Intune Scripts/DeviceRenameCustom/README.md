# Rename-DeviceCustom.ps1

Renames a Windows device to a name you type in. One standalone script, run on
the device in an elevated PowerShell window. No package, scheduled task or
other files.

For automatic renaming to a prefix plus the BIOS serial number, use the
[DeviceRename Win32 app](../WIN32/DeviceRename/README.md) instead.

## Run it

Open PowerShell as administrator on the device, then:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Rename-DeviceCustom.ps1
```

Optional parameters:

| Parameter | Purpose |
|---|---|
| `-NewName <name>` | Use this name instead of asking. The confirmation and restart questions are still asked. |
| `-RequiredPrefix <text>` | The new name must start with this text (1 to 14 letters, digits or -), for example a site code. |

## What it does

1. Shows the current name, a pending name (if a rename already waits for a
   restart), the serial number and whether the device is domain joined.
2. Asks for the new name and checks it. An invalid name is rejected with the
   reason and asked again. Enter `Q` to quit. Rules:
   - 1 to 15 characters
   - only A to Z, 0 to 9 and the hyphen (no spaces)
   - not only digits, does not start or end with a hyphen
   - does not start with `DESKTOP-`, `LAPTOP-`, `WIN-` or `MININT-`
   - starts with `-RequiredPrefix`, when it is given
   Letters are converted to capitals.
3. Asks for confirmation, then runs `Rename-Computer`.
4. Asks whether to restart now.

In a console window the questions are asked in the console. In PowerShell ISE
they are shown in a small window that stays on top.

## Notes

- Intune shows the new device name after the device restarts and syncs.
- The name is not checked for duplicates in Intune, Entra ID or Active
  Directory. On a domain-joined device a name that already exists in Active
  Directory makes the rename fail with an error; the device needs a
  reachable domain controller.
- Exit codes: 0 = renamed, cancelled or nothing to do; 1 = not run as
  administrator, invalid `-NewName`, or the rename failed.
