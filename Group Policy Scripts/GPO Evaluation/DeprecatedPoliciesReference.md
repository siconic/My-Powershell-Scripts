# Deprecated and Legacy GPO Policy Reference

Use this file as a maintained exclusion/reference list for Compare-GPOXml.ps1.

## Deprecated / Legacy Microsoft Technologies

- HomeGroup
  - Prevent the computer from joining a homegroup
  - Status: Removed from Windows 10 version 1803 and later

- EMET (Enhanced Mitigation Experience Toolkit)
  - Any policy or registry setting under Software\Policies\Microsoft\EMET
  - Status: Retired and replaced by Microsoft Defender Exploit Guard / Attack Surface Reduction

- Windows Messenger
  - Turn off the Windows Messenger Customer Experience Improvement Program
  - Status: Obsolete product

- Search Companion
  - Turn off Search Companion content file updates
  - Status: Legacy Windows XP era feature

- Online Ordering / Web Publishing Wizard
  - Turn off Internet download for Web publishing and online ordering wizards
  - Turn off the Publish to Web task for files and folders
  - Status: Legacy feature

- Convenience PIN Sign-In
  - Turn on convenience PIN sign-in
  - Status: Superseded by Windows Hello for Business

- Microsoft Store Private Store
  - Only display the private store within the Microsoft Store
  - Status: Microsoft Store for Business/Private Store retired

- Early LAPS (AdmPwd/Legacy LAPS)
  - Enable local admin password management
  - Name of administrator account to manage
  - Password Settings (legacy LAPS ADMX)
  - Status: Prefer Windows LAPS policies

## Detection Logic
Compare by SettingName OR Registry KeyPath.
If matched, export to DeprecatedPolicies.csv with:
- GPOName
- Class
- Category
- SettingName
- Value
- Reason
- RecommendedReplacement
