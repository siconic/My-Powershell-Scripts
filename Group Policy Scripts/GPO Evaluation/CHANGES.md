# GPO Compare - Version 3.0 change list

Not run: PowerShell was not available where these files were written, so nothing has been executed.
Structure was checked (balanced braces/parentheses, every called function is defined, JSON valid, reference table parses to 12 entries).
Test against real XML before relying on the output.

## What to expect on the first run

- **Unclassified will no longer be 0.** Unsupported extensions and unsupported Security sub-sections are now reported instead of dropped. Review `UnclassifiedSettings.csv` and decide which to parse or ignore.
- **Comparison results will change.** Lists are sorted before comparison, GPO totals now include only GPOs that parsed, and conflicts/unique/duplicates use new rules (below).
- **Local Users and Groups "Membership Actions" rows changed.** SettingName is now `<group> member: <member>` and the value is the action.

## Compare-GPOXml.ps1

- GPO total comes from the files that parsed (a failed or empty GPO no longer inflates Common). GPOs with no settings produce a warning.
- Stops with a clear error if no settings were parsed at all.
- Conflicts: needs more than one GPO and different configurations. A GPO with several rows for one name is compared as a set.
- Duplicates: adds `PresentIn`.
- Unique: based on setting name (configured in some GPOs, not all), one row per distinct value, with `PresentIn`, `ConfiguredInGPOs`, `ValuesDiffer`.
- CommonSettingsByName: adds `SameValueEverywhere`.
- Comparison keys use a control-character separator instead of `|`. Matrix `Setting` column is `Class | Extension | Category | SettingName`.
- Intune mapping: optional file (warn and continue if missing, error if present but invalid), most specific entry wins, ties go to the first entry in the file, results cached. New columns `Deprecated`, `RecommendedReplacement`. `MappingStatus` can be `Unmapped` or `MappingFileMissing`. `firewallRuleMapping` adds `IntuneType` to `FirewallRules.csv`.
- Defaults for module, mapping and deprecated reference paths are next to the script (`$PSScriptRoot`). New parameters: `-IntuneMappingPath`, `-DeprecatedReferencePath`.
- `-LiteralPath` / `-File` for file access, `-Encoding UTF8` on every CSV, every report file is always created (empty file when there is no data). `ParserFailures.csv` is in the validation list.
- Warnings at the end for parse failures and unclassified entries. `RunStatistics.csv` adds `GPOsParsed`, `UnmappedSettings`.
- Help block rewritten with valid keywords; the invalid "module setting" note removed.

## GPOCompare.psm1

- Unsupported extensions go to Unclassified (`default` case in `Invoke-GPOSectionParser`). Each extension is parsed in its own try/catch, so one bad section no longer discards the whole GPO.
- Unsupported Security sub-sections (legacy audit, event log, restricted groups, file/registry permissions, and so on) are reported.
- Direct property access replaced with `Get-XmlProperty` where a missing element would throw under StrictMode (firewall profiles/rules, LUG container, audit, ADMX policy, NRPT rule).
- Outbound firewall rules are parsed (`OutboundFirewallRules`); inbound null-element bug fixed.
- Sorted before joining: user rights members, LUG members, ListBox/MultiText/MultiString/SettingStrings/DisplayStrings values.
- User rights: falls back to the SID when a member has no name.
- `Convert-AuditValue` accepts an empty value.
- Security Options with no name go to Unclassified (no more `<UnknownSecurityOption>` collisions).
- `Get-CleanText` returns the text of XML nodes instead of the type name.
- Single Unclassified record schema (`New-UnclassifiedRecord`).
- XML loaded with `XmlDocument.Load(stream)` (encoding detected, `-LiteralPath` safe) instead of `Get-Content -Encoding Unicode`.
- Deprecated policy reference is now a table (Name / Category / RegistryPath matching, optional CategoryFilter). Output adds Technology, MatchType, Status, RecommendedReplacement.
- Removed: duplicate `Convert-AuditValue` and `Add-FirewallRule`, six unused `Invoke-*Parser` wrappers, `Get-AuditCategory`, `Get-NodeValue`, `Get-NodeState`, `Get-PropertyValue`, `New-GPONamespaceManager`, two commented-out functions, unused script variables including `ExcludeFirewallRulesFromComparison`.

## intunemapping.json (schema 1.1)

- Added a `Security | * | *` fallback (account policies and other Security settings had no match).
- Registry Settings now apply to any class (User-scoped registry settings were unmapped).
- Added `statusDefinitions`. Updated the Membership Actions and firewall notes.

## DeprecatedPoliciesReference.md

- Rewritten as a table the module can read. EMET registry path now works. LAPS name matches for `Name of administrator account to manage` and `Password Settings` require Category `LAPS`.

## Not changed / could not verify

- `$script:ASRRuleMap` is still never filled, so the ASR name translation in Administrative Templates does nothing.
- Firewall address scopes are still not parsed.
- `[ref]` parameters and the `<NoValue>` / whitespace normalisation are unchanged.
- Unverified against your XML: the `OutboundFirewallRules` element name, the `Advanced Audit Configuration` extension name (a mismatch will show up as Unclassified), and the legacy LAPS category `LAPS`.
- A GPO that has no `Computer`/`User` extension data at all produces no error and no settings.
