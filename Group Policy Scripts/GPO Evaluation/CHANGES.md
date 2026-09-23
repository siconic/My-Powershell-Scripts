# GPO Compare Toolset - Version History

Versioning convention (applies to both toolsets): MAJOR bumps mean
restructured logic or a changed CSV/report schema - something that could
break a workflow built on the old output. MINOR bumps are bug fixes and
additions that don't change existing columns or behavior. A script and its
paired module are always versioned in lockstep (Compare-GPOXml.ps1 +
GPOCompare.psm1 share one version; Compare-GPOHtml.ps1 + GPOCompareHtml.psm1
share another), since they're only ever used together.

Not run: PowerShell was not available where these files were written, so
XML-side changes are structurally checked (balanced braces/parens, every
called function defined) but not executed. HTML-side changes were also
validated by re-implementing the same DOM-walk algorithm in Python against
three real gpresult /h reports - see that toolset's changelog for what that
did and didn't catch.

## XML toolset (Compare-GPOXml.ps1 + GPOCompare.psm1) - current: 3.3

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

## HTML toolset (Compare-GPOHtml.ps1 + GPOCompareHtml.psm1) - current: 1.10

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

## Shared reference files

- **DeprecatedPoliciesReference.md** - 1.0. Table format
  (Technology/MatchType/Pattern/Status/Replacement/CategoryFilter), read by
  both toolsets.
- **intunemapping.json** - schemaVersion 1.1 (tracked separately, since
  it's a data schema version rather than a tool version). Includes a
  `Security | * | *` fallback and treats Registry Settings as applying to
  any class.

## Known open items (not yet fixed)

- HTML: the `HTMLFile` COM/`IHTMLDocument2_write` interop path is still
  unverified against a live PowerShell session.
- HTML: Group Policy Preferences items and File System ACL summary tables
  are not parsed (routed to Unclassified by design).
- XML: `$script:ASRRuleMap` is still never populated, so ASR rule name
  translation in Administrative Templates does nothing.
- XML: firewall address scopes are still not parsed.
