# GPO Compare Toolset - Version History

Versioning convention (applies to both toolsets): MAJOR bumps mean
restructured logic, a changed CSV/report schema - something that could
break a workflow built on the old output - or a major new feature, such
as a new output format. MINOR bumps are bug fixes and small additions that
don't change existing columns or behavior. A script and its
paired module are always versioned in lockstep (Compare-GPOXml.ps1 +
GPOCompare.psm1 share one version; Compare-GPOHtml.ps1 + GPOCompareHtml.psm1
share another), since they're only ever used together.

Not run: PowerShell was not available where these files were written, so
XML-side changes are structurally checked (balanced braces/parens, every
called function defined) but not executed. HTML-side changes were also
validated by re-implementing the same DOM-walk algorithm in Python against
three real gpresult /h reports - see that toolset's changelog for what that
did and didn't catch.

## Folder layout and launcher (Start-GPOToolkit.ps1) - current: 1.0

- **1.0** - The files are now in folders: `Scripts` (the five scripts),
  `Modules` (the three modules), `Data` (DeprecatedPoliciesReference.md,
  intunemapping.json, IntunePolicyMappings.json,
  IntuneMigrationExclusions.json) and `Config` (the example configuration
  files, and the local-only GpoRoles.csv, ConsolidationRules.json,
  IntuneMappingRedactions.txt and IntunePolicyMappings.Internal.json). A
  committed `.gitignore` keeps the four local-only Config files out of the
  repository. New `Start-GPOToolkit.ps1` at the top: a console menu with
  six actions (compare XML, compare HTML, Intune policy plan, GPO
  consolidation plan, import mapping workbooks, check the toolkit files).
  It asks only for the inputs each script needs, shows the equivalent
  direct command, offers the folders used earlier in the session as
  defaults, offers to copy the Config example files when they are missing,
  and returns to the menu after an error. Every script can still be run
  directly with the same parameters; only their location changed, which is
  why every script gets a MAJOR version. See README.md.
  Tested in Windows PowerShell 5.1 through Start-GPOToolkit.ps1 with answers given on standard input
  All six actions were run. Actions 1 and 2 compared the XML exports
  and GPResult reports of three sites (Excel output). Action 3 built an
  Intune policy plan from the XML compare workbook. Action 4 built the GPO
  consolidation plan (same counts as the 1.0 acceptance run, except one
  more "ready" setting from the updated IntunePolicyMappings.json).
  Action 5 imported one mapping workbook into Data\IntunePolicyMappings.json
  (the file was restored afterwards). Action 6 listed every file as found.
  An action whose script stops with an error (HTML reports with no
  settings) showed the message and returned to the menu.

## XML toolset (Compare-GPOXml.ps1 + GPOCompare.psm1) - current: 5.0

- **5.0** - Moved to `Scripts\Compare-GPOXml.ps1` and
  `Modules\GPOCompare.psm1`. Default paths now point to `Modules` and
  `Data`. Parameters and output are unchanged. No module changes. Can be
  run from `Start-GPOToolkit.ps1` (action 1).

- **4.0** - Excel output (MAJOR: a new output format), the same as HTML
  2.0: new `-OutputFormat CSV|Excel` parameter with a question when it is
  not given; Excel writes only `GPOCompareXml.xlsx` (with the file name
  prefix), with RunStatistics first in a blue Statistic / Value table;
  ImportExcel is installed if missing, with CSV output if that fails. No
  module changes. Run in Windows PowerShell 5.1: the workbook functions
  with test rows (see HTML 2.0), and `-OutputFormat Excel` with one invalid
  XML file, which wrote a workbook with the 4 worksheets collected before
  the "No settings were parsed" stop. Same workbook layout as HTML 2.0
  (worksheet order, blue tables, RunStatistics links); `RunStatistics.csv`
  has two new columns at the end (`MissingSettingsMatrix`,
  `IntuneMigrationCandidates`). The XML workbook functions were run with
  test rows: the statistics linked to the worksheets present and were
  listed in worksheet order, with UnmappedSettings linked. A full XML
  run has not been tested, because no GPO XML exports were available.
  Intune mapping from manual workbooks, the same as HTML 2.0, plus a
  table that translates the internal names in XML exports to display
  names for this lookup: 15 account policies (`PasswordHistorySize` ->
  "Enforce password history") and 45 user rights (`SeNetworkLogonRight` ->
  "Access this computer from the network"). The table is written from the
  standard Windows names and has not been checked against real GPO XML
  exports. Tested with the lookup functions: `PasswordHistorySize` and
  `SeNetworkLogonRight` found their workbook mappings. Exclusions
  (`IntuneMigrationExclusions.json`, question or `-ApplyExclusions`), the
  same as HTML 2.0; for the XML script tested with the functions only
  (XML naming: Windows Firewall, Registry Settings excluded).

- **3.3** - New `-FilePrefix` parameter, the same as HTML 1.10. The prefix
  and a hyphen are added to the start of every output file name
  (`LS-CommonSettings.csv`). If the parameter is not given, the script asks
  for it; an empty answer keeps the original file names. No module changes.
  Run in Windows PowerShell 5.1 with one invalid XML file (no GPO XML
  exports were available): the four files written before the "No settings
  were parsed" stop were all prefixed, and the stop message named the
  prefixed files. A full XML run with the prefix has not been tested.

- **3.2** - Replaced all 13 uses of the `"{0}={1}" -f` composite-format
  operator with plain string interpolation (a grep for ` -f ` with spaces
  on both sides had missed 9 of the 13 - `-f` followed immediately by a
  line break doesn't match that pattern). This was the reported source of
  "error formatting a string: index (zero based) must be greater than or
  equal to zero..." - string interpolation has no template/argument-list
  mechanism to fail that way, so this removes the entire exception class
  regardless of which of the 13 call sites was actually throwing.
- **3.1** - Unsupported-extension Unclassified rows now carry a
  SettingName, Value, and State per item (new `Get-UnknownExtensionItems`),
  instead of one blank row per whole extension. Parser-error Reason text
  now includes the module line number that threw, so a future error is
  self-diagnosing from the CSV alone.
- **3.0** - Full rework from the original script: GPO total based on
  parsed files rather than settings found; conflict/unique/duplicate rules
  fixed to require more than one GPO; list-style values (user rights, LUG
  members, ADMX multi-value settings) sorted before comparison so element
  order doesn't cause false conflicts; unsupported extensions and Security
  sub-sections routed to Unclassified instead of dropped silently; Intune
  mapping and deprecated-policy matching added; module path, encoding, and
  `-LiteralPath` fixes; duplicate/dead function definitions removed.

## HTML toolset (Compare-GPOHtml.ps1 + GPOCompareHtml.psm1) - current: 3.0

- **3.0** - Moved to `Scripts\Compare-GPOHtml.ps1` and
  `Modules\GPOCompareHtml.psm1`. Default paths now point to `Modules` and
  `Data`. Parameters and output are unchanged. No module changes. Can be
  run from `Start-GPOToolkit.ps1` (action 2).

- **2.0** - Excel output (MAJOR: a new output format). New
  `-OutputFormat` parameter, `CSV` or `Excel`. If it is not given, the
  script asks (C or E; Enter or no way to ask means CSV; any other answer
  gives a warning and CSV). CSV output is unchanged. Excel output writes
  only `GPOCompareHtml.xlsx` (with the file name prefix), one worksheet
  per report, and no CSV files. RunStatistics is the first worksheet,
  shown as a two-column Statistic / Value table with a title and Excel's
  blue Medium2 table style (`RunStatistics.csv` keeps its one-row layout).
  (Worksheet order and table style: see "Workbook layout" below.) A
  report with no rows gets a worksheet
  that says "No rows". Uses the ImportExcel module (tested with 7.8.10);
  Excel is not needed. If the module is missing, the script installs it
  for the current user from the PowerShell Gallery (with the NuGet
  provider, TLS 1.2 and `-Force`); if that fails, it says so and the
  output is CSV files. If the "No settings were parsed" stop happens, the
  workbook is still written with the worksheets collected so far. If the
  workbook cannot be written (for example, it is open in Excel), the
  reports are written as CSV files instead. Text values are kept exactly
  as text: `-NoNumberConversion` and `-NoHyperLinkConversion` stop number
  and link conversion, and text starting with `=` (which Export-Excel
  always writes as a formula) is written back as plain text. Counts are
  Excel numbers and True/False values are Excel TRUE/FALSE. Values longer than 32767
  characters are cut to that length in the workbook only, with a warning.
  No module changes. Run in Windows PowerShell 5.1: a full run wrote all 18
  worksheets; test rows with `=SUM(A1:A2)`, a URL, `0001`, `1-2` and a
  40,000-character value were read back unchanged (the long value cut to
  32767), and Excel showed the `=` value as text with no formula. Excel
  opened the workbook on RunStatistics, and a picture of the table
  exported from Excel showed the blue header and banded rows. Output
  format: `Excel` wrote only the workbook (18 worksheets); `CSV` wrote 18
  CSV files; no way to ask gave CSV; answer `E` gave the workbook; answer
  `X` gave a warning and CSV; the early stop wrote a workbook with the 5
  worksheets collected so far; a locked workbook file gave the warning and
  18 CSV files. Install failure was tested with the module reported
  missing and the internet blocked by an unreachable proxy: the error was
  shown, then "could not be installed. Output will continue as CSV files."
  and 18 CSV files. A successful install by the script has not been
  tested, because ImportExcel was already installed on the test PC.
  Workbook layout: worksheets in the order RunStatistics, CommonSettings,
  UniqueSettings, DeprecatedPolicies, FirewallRules,
  IntuneMigrationCandidates, DuplicateSettings, ConflictingSettings,
  ParsedSettings, then the others. Every worksheet is an Excel table in
  the blue Medium2 style with a frozen header row. In RunStatistics, each
  statistic that counts a worksheet's rows is a link to that worksheet
  (`Settings` -> ParsedSettings, `Conflicts` -> ConflictingSettings, and
  so on). `RunStatistics.csv` has three new columns at the end
  (`MissingSettingsMatrix`, `IntuneMigrationCandidates`,
  `FirewallDiagnostics`) so that every report has a count. Tested in Excel
  with three reports, one named `Test [1] #A`: the worksheet order was as
  listed, all 18 worksheets were Medium2 tables, the matrix header showed
  `Test [1] #A` correctly, every worksheet had a linked statistic whose
  value equaled its row count, and following the `Conflicts` link opened
  ConflictingSettings. The RunStatistics worksheet lists the statistics in
  worksheet order (general values such as Timestamp first), and
  `UnmappedSettings` links to IntuneMigrationCandidates; its value is the
  number of rows there with MappingStatus `Unmapped` (checked in Excel: 3
  and 3; following the link opened IntuneMigrationCandidates).
  `RunStatistics.csv` keeps its column order.
  Intune mapping from manual workbooks: each setting is first looked up
  in `IntunePolicyMappings.json` (new `-PolicyMappingPath`, default next
  to the script; built by `Import-IntuneMappingWorkbook.ps1`) by class +
  policy name, case and spacing ignored. When a policy name has entries
  in several categories (event logs, WinRM Client/Service), the entry
  whose last category part is part of the setting's category is used;
  otherwise the first, with a note. A match gives MappingStatus `Mapped`
  or `NoIntuneEquivalent`, Confidence `High`, IntuneType = the workbook's
  Intune Setting, IntuneSetting = its Intune Sub Setting, Notes = its
  remarks and any alternate mappings. Other settings use the general
  rules in `intunemapping.json` as before. IntuneMigrationCandidates has
  a new last column, `MappingSource` (the mapping file's name; for a file
  written with -KeepSensitiveData also the workbook / worksheet labels; or
  "intunemapping.json (general rule)");
  RunStatistics has a new last value, `MappedFromWorkbooks`, linked to
  IntuneMigrationCandidates. Without the file, a note is shown and the run
  is unchanged. A scrubbed file has no remarks, so Notes shows "Reviewed in
  a mapping workbook: no Intune equivalent." or "Mapped from the manual
  mapping workbooks."; an internal file (-KeepSensitiveData) gives its
  remarks. Tested with the lookup functions (display name, case and
  spacing, event log category, User vs Computer, unknown policy), and in
  full runs with small test mapping files whose policy names matched the
  test reports: a scrubbed NoIntuneEquivalent entry and an internal Mapped
  entry with a remark and an alternate both gave the expected status,
  Intune columns, Notes, MappingSource (with the loaded file's name) and
  MappedFromWorkbooks count.
  Exclusions: new `IntuneMigrationExclusions.json` next to the scripts, one
  entry per area with `enabled` true/false, a class and wildcard patterns
  matched against "Extension / Category / SettingName". Firewall,
  Registry and Public Key Policies are enabled; File System, System
  Services, Local Users and Groups, Wireless Network Policies, Internet
  Explorer Maintenance, Software Restriction Policies, Advanced Audit
  Policy and NRPT are included but disabled. The scripts ask "Exclude
  settings from IntuneMigrationCandidates?" (Enter or no way to ask = no);
  `-ApplyExclusions` / `-ApplyExclusions:$false` answer without asking,
  `-ExclusionPath` points to another file. Matching settings are left out
  of IntuneMigrationCandidates only (they stay in ParsedSettings and the
  comparisons); RunStatistics has a new last value, ExcludedFromMigration,
  and the console lists the count per entry. Tested with the functions
  (XML and HTML naming for firewall, registry and public key policies
  excluded; password policy, an ADMX policy named "...registry...", and a
  disabled entry kept; enabled "false"/"true" and a class limit respected;
  a missing file warns and excludes nothing) and in full HTML runs with a
  test exclusion file: -ApplyExclusions and answer Y excluded the 3
  matching settings (ParsedSettings still 3, UnmappedSettings 0);
  -ApplyExclusions:$false, Enter and a non-interactive session excluded
  nothing; the Excel output shows ExcludedFromMigration in RunStatistics.

- **1.10** - New `-FilePrefix` parameter. The prefix and a hyphen are added
  to the start of every output file name (`LS-CommonSettings.csv`). A
  trailing hyphen in the input is removed, so `LS-` also gives `LS-`. If
  the parameter is not given, the script asks for it; an empty answer
  keeps the original file names. `-FilePrefix ""` skips the question. In a
  session that cannot ask, no prefix is used. A prefix with a character
  not allowed in file names stops the run. No module changes. Run in
  Windows PowerShell 5.1: all 18 files prefixed with `LS`, `LS-`, and an
  answer of `LS` given to the question on standard input; no prefix with
  `""` and in a `-NonInteractive` session; `a:b` stopped the run.

- **1.9** - The report title table (`<table class="title">`) is skipped.
  Its "Data collected on: <date/time>" row was recorded as a setting with
  Class `Unknown`, so any two reports taken at different times showed it
  as a unique or conflicting setting. Run in Windows PowerShell 5.1 against
  two user-scope `gpresult /h` reports taken 93 minutes apart on a
  non-domain PC: with 1.8, `UniqueSettings.csv` listed both timestamps;
  with 1.9, no output file contains the timestamp. Those reports had no
  other settings, so the effect on reports with real policy settings has
  not been tested yet.
- **1.8** - Firewall profile, global and Windows Defender Firewall ADMX
  settings moved out of the settings comparison files into
  `FirewallSettingsCommon.csv` and `FirewallSettingsUnique.csv`. They stay
  in `ParsedSettings.csv` and `IntuneMigrationCandidates.csv`.
- **1.7** - Firewall rules can no longer appear in the settings files. A
  rule whose detail table is not found now still goes to the firewall
  files, with its detail columns blank, instead of falling through to the
  settings. Firewall profile and global settings are not rules and still
  appear in the settings files.
- **1.6** - Firewall rules were still missing after 1.5. Rule tables are
  now recognized by their headers instead of by finding the Inbound Rules
  heading; direction comes from document order. Rows, cells and detail
  rows no longer use `nextSibling`, `.rows` or `.cells`. New
  `FirewallDiagnostics.csv` shows which step fails per report. Earlier
  fixes (1.4, 1.5) were validated only in Python, which does not reproduce
  how the Windows `HTMLFile` object behaves; the cause of 1.5 still failing
  is not confirmed.
- **1.5** - Real cause of the empty firewall files. Row and cell lookups
  used `getElementsByTagName`, which searches every depth. A firewall
  rule's detail row is one cell holding a nested table, so the lookup
  counted many cells and concluded there was no detail table. Rules then
  fell through to ordinary settings in `CommonSettings.csv`. New helpers
  `Get-TableRows` and `Get-RowCells` read only a table's own rows and a
  row's own cells. On a sample report, detail tables found went from 0 of
  204 rules to 204 of 204. Also fixes list-style ADMX values (ASR rules,
  Hardened UNC Paths) and nested-table rows being read as settings. The
  1.4 note claiming validation was wrong: the Python check only looked at
  direct children, so it could not reproduce this bug.
- **1.4** - Firewall rules split into their own comparison, matching the
  pattern used for regular settings: `FirewallRulesCommon.csv` (a rule -
  matched by Name + Direction - present in every report with the same
  configuration) and `FirewallRulesUnique.csv` (present in only some
  reports, or with a differing configuration in at least one).
  `FirewallRules.csv` remains the raw per-report inventory. Also fixed the
  actual reason `FirewallRules.csv` was coming back empty:
  `GPOCompareHtml.psm1`'s `Get-Attribute` used `getAttributeNode(name)`,
  which is case-sensitive in the document mode the `HTMLFile` COM object
  negotiates, while gpresult writes the `colspan` attribute lowercase and
  the call site queried it as `'colSpan'` - silently returning null
  instead of throwing, which broke every nested-detail-table lookup
  (Firewall rule detail, Administrative Template list values). Switched to
  the case-insensitive `getAttribute`. Validated against all three sample
  reports: 618 firewall rule rows across the three, all 133 distinct
  rule identities present and identical in every report (expected, since
  the three reports are the same computer in different OUs and Windows'
  predefined firewall rules don't vary by OU).
- **1.3** - Replaced all 4 uses of the `"{0}={1}" -f` composite-format
  operator with plain string interpolation, matching the same fix already
  applied to `GPOCompare.psm1` for the same reported error.
- **1.2** - Fixed the actual reported source of "The property 'Count'
  cannot be found on this object": `Get-AllTags` (26 call sites) and
  `Get-HeadingAncestors` (4 call sites) both return a .NET ArrayList, and
  PowerShell's pipeline silently unwraps an ArrayList with exactly one
  item into that bare single element whenever the caller doesn't force
  array context - so any later `.Count` check on it throws. Confirmed this
  is common, not an edge case: one sample report alone has 402 rows with
  exactly one `<td>` and 3 tables with exactly one `<th>`. Every call site
  is now wrapped in `@(...)`.
- **1.1** - Guarded three unguarded sibling-walk `.tagName` accesses
  (`Get-NestedDetailRows`, System Services parsing) behind a new
  `Get-NodeTagName` helper, matching the one walk that was already
  guarded - a whitespace text node between tags may not expose `.tagName`
  the same way an element does. Parser-error Reason text now includes the
  module line number that threw.
- **1.0** - Initial version, built for gpresult /h (RSoP) HTML reports.
  Validated by re-implementing the DOM-walk algorithm in Python against
  three real reports before shipping, which caught and fixed two
  significant bugs pre-release: heading divs are the PRECEDING SIBLING of
  their content div, not an ancestor of it (an ancestor-only walk found
  nothing); and "Computer Details"/"User Details" were wrongly in the
  skip-list, which would have skipped nearly the entire report. Group
  Policy Preferences items are explicitly excluded (routed to
  Unclassified) rather than parsed, since their per-field layout doesn't
  fit the generic table handlers.

## Intune policy plan (New-IntunePolicyPlan.ps1) - current: 2.0

- **2.0** - Moved to `Scripts\New-IntunePolicyPlan.ps1`. It uses no other
  file, so nothing else changed. Can be run from `Start-GPOToolkit.ps1`
  (action 3).

- **1.0** - New script. Reads the output of Compare-GPOXml.ps1 or
  Compare-GPOHtml.ps1 (IntuneMigrationCandidates, FirewallRules and
  CommonSettings, from the CSV files or the GPOCompare workbook) and
  writes `IntunePolicyPlan.xlsx`, a proposed set of Intune policies: one
  policy per PresentIn group (the same set of GPOs or reports).
  - Baseline: taken from CommonSettings (plus FirewallSettingsCommon for
    HTML output); a setting is Baseline when all its value rows are in
    it. Assigned to all devices / all users. Without CommonSettings in the
    input, a warning is shown and the Baseline is calculated the same way.
  - Every other setting with a given value belongs to the exact set of
    GPOs that have that value (a GPO with several values for one setting
    is compared as the set of values): Shared (two or more GPOs), Single
    (one GPO). Firewall rules are grouped the same way by name +
    direction + rule fields; a rule in every GPO is Baseline.
  - One policy per group: device and user settings, all Intune types and
    firewall rules of a group are in its one policy. PolicyType comes
    from IntuneType with an editable keyword table (`$PolicyTypeRules`:
    Firewall, Account protection, Attack surface reduction, Antivirus,
    Disk encryption, LAPS, no direct mapping, Settings Catalog,
    Remediation script; Unmapped settings are "Needs mapping").
  - Deprecated and NoIntuneEquivalent settings go to NotMigrated;
    settings and rules with different values in different GPOs are listed
    on Conflicts.
  - Worksheets (blue tables): Summary (counts linked to their worksheet
    or table, the Baseline source, and below them the policy plan: one row
    per policy with Worksheet, Tier, Assignment - "All devices", "All
    users", "All devices and users", or "Devices / Users / Devices and
    users of: ..." - GPOs, Scopes, PolicyTypes and counts, each policy
    name linked to its worksheet); one worksheet per policy in plan order,
    named "Baseline", "Shared 1", "Shared 2", ... or after its single GPO
    (cut at the last whole word within Excel's 31 characters, numbered when
    two GPOs match), titled with the full policy name, with a "Back to
    Summary" link and a frozen title and header; then Conflicts (Kind,
    Scope, Item, Value, GPOs, PolicyName) and NotMigrated (Reason, Class,
    Extension, Category, SettingName, Value, GPOs).
  - A policy worksheet has the settings table - only the columns needed
    to build the policies: Class, PolicyType, WinningGPO (HTML only),
    IntuneType, IntuneSetting, Value, MappingStatus, Confidence, sorted by
    Class and PolicyType so each part to build as its own Intune policy is
    together - and below it a "Firewall Rules" table (Conflict flag and
    rule fields) when the group has firewall rules.
  - `-PolicyNamePrefix` adds text to every policy name (not to worksheet
    names); `-FilePrefix` picks one run when the folder has several.
  - Run in Windows PowerShell 5.1 with synthetic XML-format output (3
    GPOs, one case per rule): 5 policies (Baseline, Shared 1, and one per
    GPO) as worked out by hand; a group with device and user settings got
    "Devices and users of: ..."; the firewall rules table below the
    settings with its title; conflicts and not-migrated settings listed;
    list values in a different order grouped together; `=` text kept as
    text. The Baseline followed CommonSettings (a setting listed there
    moved into the Baseline even though it was in only two GPOs); without
    CommonSettings the warning appeared and the same Baseline was
    calculated. Also run on real HTML compare output (CSV and workbook: a
    Baseline exactly when CommonSettings had rows), on a compare workbook
    with a prefix, and on a folder with two runs (stopped without
    `-FilePrefix`). Checked in Excel with short, long and colliding GPO
    names: worksheet names within 31 characters, every Summary link
    resolved, "Back to Summary" returned. Not yet run on real GPO exports.
## Intune mapping import (Import-IntuneMappingWorkbook.ps1) - current: 2.0

- **2.0** - Moved to `Scripts\Import-IntuneMappingWorkbook.ps1`. Writes
  `Data\IntunePolicyMappings.json` by default, or
  `Config\IntunePolicyMappings.Internal.json` with `-KeepSensitiveData`;
  reads redactions from `Config\IntuneMappingRedactions.txt`. Parameters
  are unchanged. Can be run from `Start-GPOToolkit.ps1` (action 5).

- **1.0** - New script. Reads manual GPO-to-Intune mapping workbooks
  (.xlsx files or folders) and writes `IntunePolicyMappings.json`, which
  both compare scripts use. Finds the header row (a `Policy` column and a
  column containing "Intune") in each worksheet and skips worksheets
  without one (GPO summary/metadata, firewall rules, Preferences).
  Recognizes varying column names (`Intune Setiing`, `Intune Sub
  Settings`, `Intune Setting Sub-Setting`, `Rema`, `Comment`, `Migration
  status`), category rows (merged or not) and Intune cells merged over
  several rows. A policy is keyed by class + policy name + the last part
  of its category path. Rows are Mapped (Intune setting given),
  NoIntuneEquivalent (remark only) or blank (not stored; may be mapped in
  another workbook). Different mappings for one policy: the first read is
  used, the others kept as alternates. Adds to the existing file, or
  starts over with `-Rebuild`; a second run with the same workbooks
  leaves the file unchanged. Optional `-ReportPath` CSV per row.
  By default the file is scrubbed and safe for a public repository: GPO
  values and remarks are not stored (remarks are still read to tell a
  reviewed "no equivalent" row from a blank one), permission rows
  (`Allow:` / `Deny:`) are skipped, Intune cells without a letter or digit
  count as empty, and every text is redacted (URLs, UNC paths, email and
  IP addresses, host and domain names, `DOMAIN\account`, and the terms in
  the local, uncommitted `IntuneMappingRedactions.txt`) to placeholders
  such as `<ORG>`. In a scrubbed file every source (and alternate source)
  is the mapping file's own name, not a workbook or worksheet name; an
  older scrubbed file is converted the same way when it is added to, and
  the `-ReportPath` CSV still shows the workbook and worksheet per row.
  `-KeepSensitiveData` writes an unscrubbed file with
  remarks for internal use, to `IntunePolicyMappings.Internal.json` by
  default, with a warning; the file records `"scrubbed": false`, and
  scrubbed and unscrubbed data are never merged into one file (tested:
  both directions refused, the target file unchanged). Run in
  Windows PowerShell 5.1 on four workbooks: 741 policy rows, 412 policies
  (349 Mapped, 63 NoIntuneEquivalent), 221 blank rows (134 mapped in
  another workbook, 73 policies not mapped anywhere), 8 permission rows
  skipped, 10 policies with alternates (all the same Intune setting
  written differently). A scan of the written file found no domain,
  account, URL, IP or email address, and no organization term.

## GPO consolidation plan (New-GpoConsolidationPlan.ps1 + GPOConsolidation.psm1) - current: 2.0

- **2.0** - Moved to `Scripts\New-GpoConsolidationPlan.ps1` and
  `Modules\GPOConsolidation.psm1`. Reads `Config\GpoRoles.csv`,
  `Config\ConsolidationRules.json` and `Data\DeprecatedPoliciesReference.md`
  by default. Parameters and output are unchanged. No module changes. Can
  be run from `Start-GPOToolkit.ps1` (action 4), which offers to copy the
  example files when the Config files are missing.

- **1.0** - First version. Turns Compare-GPOXml.ps1 output (workbook or
  CSV folder) into a layered GPO consolidation plan workbook: Summary,
  Intune Plan, Baseline, Baseline FW Rules, Hardening, one
  "Branding - <Site>" sheet per site, Decisions, Retired & Moved, and Not
  Migrated to Intune. Groups settings by GPO role, which comes from
  `GpoRoles.csv` (GPOName, Site, Role, Precedence; roles Baseline,
  Hardening, Branding, DomainRoot, Separate, Retire). The decisions not
  in the data come from `ConsolidationRules.json` (ReferenceSite,
  ValueOverrides, BrandingSettings, IntuneExclusions, IntuneKeepList,
  RetireRules, ReviewNotes). The repo has `GpoRoles.example.csv` and
  `ConsolidationRules.example.json` with placeholder names; the real
  files stay local.
  Compare-GPOHtml.ps1 output can be given as well. It is used only for
  GPOs that have no XML export, with a warning for Role=Baseline GPOs
  (GPResult shows only winning settings and no Administrative Template
  options). Settings inside a gpresult section with a "Winning GPO" row
  (wireless, file system) get that GPO name instead of `<Unknown>`. A
  setting read from HTML uses the XML mapping of the same setting when
  one exists.
  Normalization: `qN:` prefixes removed; Se* rights and account policy
  keys become display names; user rights are sorted; Administrative
  Template values are cleaned to "Enabled; Option=value". Firewall
  profile keys are derived to the Defender Firewall CSP ("Mapped
  (derived)"). Suspect mappings are marked "Yes – fix mapping":
  one Intune setting used for several settings where one of them has
  that name, audit settings mapped to another subcategory, and a
  profile mapped to another profile's setting. Deprecated policies come
  from DeprecatedPoliciesReference.md through GPOCompare.psm1.
  Summary and Intune Plan counts are Excel formulas (COUNTA / COUNTIFS).
  New-IntunePolicyPlan.ps1 and the compare scripts are unchanged.
  Run in Windows PowerShell 5.1 against three sites' real data (two
  Compare-GPOXml workbooks and one Compare-GPOHtml CSV folder) and
  compared with a hand-built reference workbook. Results (reference in
  brackets):
  - Baseline 342 [343]. "Turn on convenience PIN sign-in" is retired,
    because DeprecatedPoliciesReference.md lists it.
  - Baseline FW Rules 197 [194], and 0 [3] Hardening firewall rules. The
    Windows 11 GPOs contain the same 3 rules enabled, so the Hardening
    copies are duplicates.
  - Hardening 28 [28]. Branding 3 per site [3].
  - Decisions 29 [24]. Extra rows: the separate lockout duration and
    reset counter rows, 2 domain-root security option differences, and
    one row per Separate GPO. The reference has hand-written rows.
  - Retired & Moved 294 [295]. Deprecated settings in Hardening are
    listed as deprecated, not "Moved to baseline" (3). A registry path
    that differs only in letter case counts as the same setting (1).
    "System/LAPS Password Settings" is Windows LAPS, not legacy LAPS (1).
    The reference's 4 domain-root rows per site (event log sizes, XP
    wireless) come from GPResult HTML, which is not used when an XML
    export exists; the XML export does not have them. The IE settings in
    the domain-root GPOs are retired (3 per site).
  - Not Migrated 101 [106]. Retired settings are not listed again (4
    legacy LAPS rows). Two certificates whose names differ only in
    letter case are one setting (1).
  - Intune Plan 540 / 489 / 51 [541 / 491 / 50]. "Limits print driver
    installation to Administrators" is mapped to another setting's name
    and is marked "fix mapping". The domain-root wallpaper has no Intune
    equivalent (the XML mapping of the same setting).
## Shared reference files

- **DeprecatedPoliciesReference.md** - 1.1. Adds a Microsoft Defender
  Application Guard `Category` row (removed from Windows 11 24H2; matches
  the Microsoft and older Windows Defender category names) and updates the
  version line to the current script versions. 1.0: table format
  (Technology/MatchType/Pattern/Status/Replacement/CategoryFilter), read by
  both toolsets.
- **intunemapping.json** - schemaVersion 1.2 (tracked separately, since
  it's a data schema version rather than a tool version). Includes a
  `Security | * | *` fallback and treats Registry Settings as applying to
  any class. 1.2 adds the `Mapped` and `NoIntuneEquivalent` status
  definitions used for IntunePolicyMappings.json matches.
- **IntuneMigrationExclusions.json** - schemaVersion 1.0. Exclusion
  entries for IntuneMigrationCandidates: name, enabled, class, patterns,
  description. Read by both compare scripts when exclusions are used.
- **IntunePolicyMappings.json** - schemaVersion 1.0. Written by
  Import-IntuneMappingWorkbook.ps1; do not edit by hand (edit the
  workbook and import again with `-Rebuild`). One entry per policy:
  class, policy, categoryPath, status, intuneSetting, intuneSubSetting,
  sources, alternates (intuneSetting, intuneSubSetting, source); in the
  committed, scrubbed file every source is "IntunePolicyMappings.json". Top-level
  `scrubbed`: true for the committed file, which has no remarks; false for
  an internal file written with `-KeepSensitiveData`, which adds `remarks`
  to each entry and alternate.

## Known open items (not yet fixed)

- HTML: the `HTMLFile` COM/`IHTMLDocument2_write` interop path is still
  unverified against a live PowerShell session.
- HTML: Group Policy Preferences items and File System ACL summary tables
  are not parsed (routed to Unclassified by design).
- XML: `$script:ASRRuleMap` is still never populated, so ASR rule name
  translation in Administrative Templates does nothing.
- XML: firewall address scopes are still not parsed.
