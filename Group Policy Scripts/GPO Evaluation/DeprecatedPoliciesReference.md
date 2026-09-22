# Deprecated and Legacy GPO Policy Reference

Read by `Compare-GPOXml.ps1` through `Import-DeprecatedPolicyReference` in `GPOCompare.psm1`.
Only the table rows below are used. All other text in this file is ignored, so notes can be added anywhere outside the table.

Matches are written to `DeprecatedPolicies.csv` with Technology, MatchType, Status and RecommendedReplacement.
Settings that match are also flagged `Deprecated = Yes` in `IntuneMigrationCandidates.csv`.

## Columns

| Column | Meaning |
|---|---|
| Technology | Name shown in the report. |
| MatchType | `Name`, `Category` or `RegistryPath` (see below). |
| Pattern | The text to match. |
| Status | Why it is listed. |
| Replacement | What to use instead. |
| CategoryFilter | Optional. Only for `Name` rows: the Category must also equal this value exactly. Leave blank for none. |

## MatchType

- **Name**: the setting name equals Pattern (case-insensitive). Type it exactly as it appears in the `SettingName` column of `ParsedSettings.csv`.
- **Category**: the Category contains Pattern (case-insensitive). Use this to flag a whole group of policies, such as an ADMX category.
- **RegistryPath**: a Registry Settings key path contains Pattern (case-insensitive). Write it without the hive, starting with `Software\`.

A pipe character (`|`) cannot be used inside a cell.

## Deprecated / Legacy Microsoft Technologies

| Technology | MatchType | Pattern | Status | Replacement | CategoryFilter |
|---|---|---|---|---|---|
| HomeGroup | Name | Prevent the computer from joining a homegroup | Removed from Windows 10 version 1803 and later | None documented | |
| EMET | RegistryPath | Software\Policies\Microsoft\EMET | Retired | Microsoft Defender Exploit Guard / Attack Surface Reduction | |
| EMET | Category | EMET | Retired | Microsoft Defender Exploit Guard / Attack Surface Reduction | |
| Windows Messenger | Name | Turn off the Windows Messenger Customer Experience Improvement Program | Obsolete product | None documented | |
| Search Companion | Name | Turn off Search Companion content file updates | Legacy Windows XP era feature | None documented | |
| Online Ordering / Web Publishing Wizard | Name | Turn off Internet download for Web publishing and online ordering wizards | Legacy feature | None documented | |
| Online Ordering / Web Publishing Wizard | Name | Turn off the Publish to Web task for files and folders | Legacy feature | None documented | |
| Convenience PIN Sign-In | Name | Turn on convenience PIN sign-in | Superseded by Windows Hello for Business | Windows Hello for Business | |
| Microsoft Store Private Store | Name | Only display the private store within the Microsoft Store | Microsoft Store for Business / Private Store retired | None documented | |
| Legacy LAPS (AdmPwd) | Name | Enable local admin password management | Legacy LAPS; prefer Windows LAPS | Windows LAPS policies | |
| Legacy LAPS (AdmPwd) | Name | Name of administrator account to manage | Legacy LAPS; prefer Windows LAPS | Windows LAPS policies | LAPS |
| Legacy LAPS (AdmPwd) | Name | Password Settings | Legacy LAPS; prefer Windows LAPS | Windows LAPS policies | LAPS |

## Notes

- **LAPS:** Windows LAPS uses some of the same policy names as legacy LAPS. The two rows with `LAPS` in CategoryFilter only match settings whose Category is exactly `LAPS`. Confirm that value against the Category column in `ParsedSettings.csv` for your GPOs; if the legacy policies show a different category, change the CategoryFilter to match.
- **EMET:** the `Category` row matches any category that contains the text `EMET`. Check `DeprecatedPolicies.csv` after a run for unrelated matches.
- **Adding entries:** copy an existing row and edit it. Keep every row on one line and keep six cells (leave the last one empty if there is no filter).
