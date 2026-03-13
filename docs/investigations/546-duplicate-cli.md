# Investigation Plan: Duplicate LabVIEWCLI Invocations (#546)

Objective

- Investigate and eliminate duplicate LabVIEWCLI launches when Git difftool/mergetool and our automation both trigger compares.

Context

- LVCompare.exe remains the graphical differencing engine.
- LabVIEWCLI.exe provides automation and, in LabVIEW 2025 Q3+, `CreateComparisonReport` to emit HTML/XML/Word/Text.
- Risk: both Git and our automation invoke LabVIEWCLI for a single compare intent, causing duplicate launches.

Plan

- Audit Git config / .gitattributes for CLI vs LVCompare mappings.
- Inventory internal CLI entry points (compare helpers, PR flows).
- Add short‑TTL sentinel keyed by normalized VI pair to block duplicate CLI within the window.
- Add env/context guard (e.g., `COMPAREVI_NO_CLI_CAPTURE=1`; detect Git difftool context/parent process).
- Documentation: recommended configurations (interactive LVCompare vs automated CLI capture) to avoid overlap.
- Tests: PID tracker assertions, sentinel behavior, env toggle handling.

Acceptance

- Single CLI invocation per compare intent (verified by PID tracker).
- Artifacts still produced when desired.
- Clear doc guidance; optional warning when overlapping configs detected.

