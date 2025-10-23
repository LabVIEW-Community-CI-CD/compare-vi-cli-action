---
name: RunSummary Tool Binding Anomaly
about: Track investigation of the PowerShell parameter binding issue affecting RunSummary tool tests
labels: bug, investigation, test-quarantine
assignees: ''
---

# RunSummary Tool Binding Anomaly

## Summary

A persistent parameter binding error occurs only in the test host when invoking the RunSummary renderer (wrapper or
module):

```text
ParameterBindingValidationException: Cannot bind argument to parameter 'Path' because it is null.
```

The exception is raised before any custom renderer logic (debug output inside functions never triggers), and persists
across multiple mitigation attempts.

## Impact

- Original `RunSummary.Tool.Tests.ps1` quarantined (see CHANGELOG Unreleased / Tests section)
- Renderer functionality verified manually in isolated PowerShell sessions
- Other test suites unaffected

## Observed Symptoms

- Inline scriptblock `param(...)` constructs sometimes collapse to `param(,,,)` in one-liners
- Module import prompt appeared for phantom `Name[0]` parameter during an attempted `Import-Module`
- `PSModulePath` echo lines treated as commands (colon / space tokenization anomaly)
- Even subshell invocations (`pwsh -NoProfile -File tools/Render-RunSummary.ps1 <file>`) trigger the same binding error
  inside Pester
- Renaming `-Path` -> `-InputFile` (with/without alias), removing Mandatory, using positional-only, and
  using environment
  variable fallback (`RUNSUMMARY_INPUT_FILE`) all fail identically

## Mitigations Attempted

| Attempt | Change | Result |
|---------|--------|--------|
| Module refactor | Moved logic into `RunSummary.psm1` | Error persists |
| Wrapper delegator | Thin script calling module function | Error persists |
| Parameter rename | `Path` -> `SummaryPath` -> `InputFile` (aliases) | Error persists |
| Positional arg only | Removed named usage | Error persists |
| Env var fallback | `RUNSUMMARY_INPUT_FILE` -> internal resolution | Error persists |
| Subshell execution | `pwsh -File` & `pwsh -Command` forms | Error persists |
| Synthetic JSON | Bypassed loop & executor entirely | Error persists |
| Skipping tests | Added -Skip markers | Discovery still failed due to arg coercion |
| Quarantine | Removed file, added placeholder | Suite green |

## Working Hypotheses

1. Host process (editor test runner or injected profile) mutates argument list, injecting a bare `-Path` with no value
   before test script executes.
2. A global proxy function / dynamic parameter injection is interfering with advanced function parsing.
3. PowerShell host is partially constrained or instrumentation is rewriting tokens (evidenced by colon path splitting
   and invalid prompt during `Import-Module`).

## Next Diagnostic Steps

- Create minimal reproduction script outside the repository containing only:

  ```powershell
  param([string]$Path)
  'OK'
  ```

- If reproducible, capture `$PSVersionTable` and host details: `[System.Environment]::CommandLine`.
- Inspect `$PSStyle` and any enforced modules via `$PROFILE` scripts.
- Run with `-NoProfile` (already done) and `-ExecutionPolicy Bypass`.
- Echo `$PSBoundParameters` at the earliest possible line.
- Use `Set-StrictMode -Version Latest` to surface latent issues.
- Capture verbose binding trace: `Set-PSDebug -Trace 1` (no secrets) to a log file.
- Attempt alternate parameter name outside common nouns: `__InputFile`.
- Attempt parameterless read of `$args[0]` to bypass binding.
- Verify there is no proxy function named `pwsh` altering invocation.
- Check for automatic variable collision (unlikely with `Path`).
- Probe `$ExecutionContext.SessionState.InvokeCommand.GetCommand('Render-RunSummary','All')` for duplicates.

- Run the problematic (old) test file in a brand-new standalone PowerShell 7 session outside the current environment.
- Temporarily rename all occurrences of `-Path` in the repository to confirm no cross-file dynamic parameter
  interference (already mostly done; still failed).
- Inspect and diff `$PROFILE`, all AllUsers / CurrentUser profile scripts; attach contents if non-empty.
- Enumerate loaded modules in the failing session: `Get-Module | Select Name,Version,Path`.
- Use `Set-PSDebug -Trace 1` around a minimal reproduction to capture pre-execution argument binding.
- Create minimal reproduction script outside the repository containing only:

  ```powershell
  param([string]$Path)
  'OK'
  ```

  invoked as `pwsh -File .\mini.ps1 foo` inside the host (observe if the same error surfaces).
- If reproducible, capture `$PSVersionTable` and host details: `[System.Environment]::CommandLine`.

## Exit Criteria

- Identify root cause (e.g., rogue profile, extension injection, or PowerShell bug)
- Restore an active renderer test that passes under normal CI runner conditions

## Temporary Workaround

Renderer can be exercised manually:

```powershell
pwsh -NoProfile -File tools/Render-RunSummary.ps1 .\path\to\run-summary.json -Format Markdown
```

Module usage:

```powershell
Import-Module .\module\RunSummary\RunSummary.psm1
Convert-RunSummary -InputFile .\run-summary.json -AsString
```

### Requested Assistance

Please provide:

- Sanitized copies of any custom profile scripts
- Output of:

  ```powershell
  $PSVersionTable
  Get-Module
  Get-ChildItem Env: | Where-Object Name -match 'RUNSUMMARY'
  ```

### References

- CHANGELOG.md Unreleased / Tests
- Quarantined test file: `tests/RunSummary.Tool.Quarantined.Tests.ps1`
- Original (removed) failing test name: `RunSummary.Tool.Tests.ps1`
- Minimal repro script: `tools/Binding-MinRepro.ps1`
- Restored renderer tests: `tests/RunSummary.Tool.Restored.Tests.ps1`

## Update (Restored Tests)

Restored renderer tests now pass using the following mitigations:

- All dynamic filesystem setup moved to `BeforeAll` or inside individual `It` blocks
- Avoided using `$TestDrive` outside runtime blocks to prevent discovery-time evaluation anomalies
- Replaced brittle `Should -Throw` pattern check with explicit try/catch and substring assertions due to full path
  variance in error messages
- Added minimal repro test `Binding.MinRepro.Tests.ps1` (still demonstrates environment discovery injection when using
  discovery-time variable assignments prior refactor)

Remaining open item: root cause of the original injected null `-Path` during discovery still not definitively isolated
(likely early evaluation of `$TestDrive` combined with Pester discovery semantics). Further investigation is optional
unless the anomaly reappears.

---
Please append diagnostic findings and commands run as comments below.
