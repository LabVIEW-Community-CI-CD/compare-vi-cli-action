# Testing Patterns & Guidance

This document captures practical patterns and anti-patterns encountered while building and stabilizing the test suite for `compare-vi-cli-action`, particularly around the Pester dispatcher and nested test invocation scenarios.

## Overview

The repository includes tests that (a) validate business logic and (b) exercise the **Pester test dispatcher** (`Invoke-PesterTests.ps1`) which itself launches Pester. This creates a *nested Pester invocation* condition:

```text
Outer Pester run (your normal test invocation)
  └─ Dispatcher test launches Invoke-PesterTests.ps1
       └─ Inner Pester run (isolated temporary workspace)
```

Nested runs can invalidate certain assumptions about mock scope and discovery-time state. The patterns below help avoid brittle failures.

---
\n## Pattern: Conditional Definition of Integration Tests

Integration test `Describe` blocks for dispatcher functionality are only defined when **Pester v5+** is truly available, instead of defining then skipping. This avoids discovery-time variable lookups under `Set-StrictMode -Version Latest` that previously caused UndefinedVariable errors.

**Why:** Discovery-time references to script-scoped probes (e.g. `$script:pesterAvailable`) are fragile. Instead, call a small probe function `Test-PesterAvailable` and wrap the entire `Describe` in an `if` statement.

**Benefit:** No skipped noise when Pester is absent; faster fail feedback; works under strict mode.

---
\n## Pattern: Function Shadowing Instead of `Mock` for Core Cmdlets

When validating probe logic (e.g. `Test-PesterAvailable`) we initially used:

```powershell
BeforeEach {
  Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pester' } -MockWith { ... }
}
```

**Problem:** Dispatcher tests launch a *nested* Pester run. Internal Pester mock registries are cleared during those inner runs, invalidating mocks defined in outer scopes. Result: `RuntimeException: Mock data are not setup for this scope` in subsequent `It` blocks.

**Solution:** Replace Pester `Mock` with transient function shadowing in the individual `It` block.

```powershell
It 'returns $true for Pester v5+' {
  function Get-Module { param([switch]$ListAvailable,[string]$Name)
    if ($ListAvailable -and $Name -eq 'Pester') {
      return [pscustomobject]@{ Name='Pester'; Version=[version]'5.7.1' }
    }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
  }
  Test-PesterAvailable | Should -BeTrue
  Remove-Item Function:Get-Module -ErrorAction SilentlyContinue
}
```

**Guidelines:**

- Shadow only *core* cmdlets that prove difficult to mock reliably across nested runs.
- Delegate to the fully-qualified original (`Microsoft.PowerShell.Core\\Get-Module`) for non-intercepted cases.
- Clean up with `Remove-Item Function:Get-Module` to avoid bleed into other tests.

**When to still use `Mock`:** For pure, non-nested scenarios (most other test files) where you aren't spawning a secondary Pester process.

---

### Helper: `Invoke-WithFunctionShadow`

To reduce repetition and guarantee restoration, a reusable helper is exported by the test utils module `tests/support/CompareVI.TestUtils.psd1`:

```powershell
Invoke-WithFunctionShadow -Name Get-Module -Definition {
  param([switch]$ListAvailable,[string]$Name)
  if ($ListAvailable -and $Name -eq 'Pester') {
    return [pscustomobject]@{ Name='Pester'; Version=[version]'5.7.1' }
  }
  Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
} -Body {
  Test-PesterAvailable | Should -BeTrue
}
```

The helper:

- Captures any pre-existing function of the same name.
- Writes the shadow to `Function:` drive (overriding cmdlet lookup).
- Executes the `-Body` scriptblock and returns its output.
- Restores (or removes) the original function in a `finally` block, even on exceptions.

Prefer the helper over hand-written `function ...; try { ... } finally { Remove-Item Function:... }` boilerplate to avoid subtle restoration omissions.

\n## Pattern: Per-`It` Setup Instead of `BeforeEach` for Fragile State

If state can be mutated or invalidated by a nested run, move the setup directly inside each `It`. This confines surface area and guarantees the setup executes *after* any nested dispatcher activity that an earlier test may have triggered.

---
\n## Pattern: Minimal Probe Definitions

For readiness checks (`Test-PesterAvailable`, integration prerequisites, etc.) keep probe functions:

- Side-effect free
- Idempotent (cache/memoize results only when safe)
- Free of global state changes

This reduces cross-test coupling and discovery failures.

---
\n## Anti-Pattern: Global Script Variables for Discovery-Time Branching

Avoid patterns like:

```powershell
$script:pesterAvailable = ...
Describe 'Integration Suite' -Skip:(-not $script:pesterAvailable) { ... }
```

Under strict mode, if `$script:pesterAvailable` is not yet set (ordering, partial load) discovery fails. Prefer conditional definition with an `if` block.

---
\n## Pattern: Defensive `$TestDrive` Fallback

Rare host-specific issues produced a late-null `$TestDrive`. Dispatcher & integration tests defensively ensure `$TestDrive` (or synthesize a temp path) before file system operations.

```powershell
if (-not $TestDrive) {
  $fallback = Join-Path ([IO.Path]::GetTempPath()) ("pester-fallback-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Force -Path $fallback | Out-Null
  Set-Variable -Name TestDrive -Value $fallback -Scope Global -Force
}
```

---
\n## Pattern: Nested Dispatcher Invocation Isolation

Dispatcher integration tests copy `Invoke-PesterTests.ps1` and synthetic test files into a temporary workspace *per test* to avoid contaminating repository-level result directories and to keep timing metrics independent.

Key considerations

- Always isolate results (`results/`) inside the temp workspace.
- Do not rely on repository-level mocks or global variables inside the nested run.
- Pass minimal config: tests path, results path, IncludeIntegration flag as needed.

## Pattern: Explicit Timing Metrics Validation

When asserting performance/timing derived fields (mean/p95/max), avoid hard-coded values; assert property *presence* and type unless stable synthetic timing is enforced. This keeps tests resilient across machine speed variance.

## Quick Decision Matrix

| Scenario | Recommended Pattern |
|----------|---------------------|
| Need to toggle entire integration block based on Pester availability | Conditional `if (Test-PesterAvailable) { Describe ... }` |
| Validate module presence/version under nested dispatcher tests | Function shadowing (not `Mock`) |
| Standard unit test (no nested dispatcher) | Traditional `Mock` / `BeforeEach` |
| Flaky `$TestDrive` observed | Defensive fallback creation |
| Need to ensure isolation of nested Pester run artifacts | Temp workspace per test |

## Checklist for New Dispatcher-Oriented Tests

1. Will this test trigger a nested dispatcher run? If yes, avoid `Mock` of core cmdlets that inner runs also need.
2. Does any function rely on script-scoped variables at discovery time? Refactor to a probe + conditional Describe.
3. Are filesystem artifacts written only under `$TestDrive` or a temp workspace? (No repo pollution.)
4. Are timing assertions tolerant (structure/type over exact numeric equality)?
5. Is cleanup (function shadow removal, temp dirs) automatic via `$TestDrive` or explicit removal?

---

## Future Enhancements

- Optional wrapper to run nested dispatcher in a separate PowerShell process to further insulate mock state.
- Add a focused regression test ensuring PesterAvailability continues to pass after a nested dispatcher run with synthetic failures.

Contributions welcome—open an issue or PR if you extend these patterns.

---

## Watcher-Specific Patterns (Fixture Mutation)

### Problem: Post-Startup Mutation Lock Contention

Early attempts to mutate `VI1.vi` immediately after launching `tools/Start-FixtureWatcher.ps1` caused repeated `UnauthorizedAccessException` during file growth (append/SetLength/read+write). The watcher performs rapid size/hash polling (every ~150ms) plus initial hashing, creating high contention for writes—especially in environments with AV or indexing.

### Added Parameter: `-StartupPollDelayMs` / `WATCHER_STARTUP_POLL_DELAY_MS`

The watcher now supports a startup synthetic-poll defer window. When set, the internal length/hash synthetic polling is skipped until the delay elapses. This is useful if a test *must* mutate immediately after start without competing reads. (Default = 0, meaning no delay.)

Usage example:

```powershell
$env:WATCHER_STARTUP_POLL_DELAY_MS = '1000'
pwsh -File tools/Start-FixtureWatcher.ps1 -Targets VI1.vi -DurationSeconds 5
```

### Two-Phase Atomic Swap Strategy (Preferred)

Instead of fighting for an exclusive write handle right after watcher startup, tests now:

1. Copy fixture into sandbox.
2. Pre-grow the sandbox copy *before* starting the watcher (Initial event captures enlarged length + hash).
3. Start watcher.
4. Create a second temporary enlarged copy, then perform an atomic rename swap (`Move-Item -Force`) to introduce a new size/hash.
5. Assert a `Changed` event with the final target length and a non-null sha256.

Benefits:

- Avoids prolonged exclusive locks.
- Short rename swap reduces contention versus in-place growth.
- Still validates runtime detection semantics (Changed event) without relying on forced debug emissions.

### When to Use Startup Delay vs. Atomic Swap

| Scenario | Use Delay | Use Atomic Swap |
|----------|-----------|-----------------|
| Need to mutate immediately after start with minimal size delta | ✅ | Possible |
| Large mutations or multiple growth steps | Optional | ✅ (preferred) |
| CI environments with aggressive AV scanning | Optional | ✅ |
| Simplest deterministic single change | ❌ (not needed) | ✅ |

### Anti-Pattern: Forced Synthetic `Changed` Spam

Earlier debugging relied on `WATCHER_FORCE_CHANGED` and produced zero-length `Changed` events, obscuring real detection quality. Tests should explicitly filter zero-length `Changed` lines and avoid enabling forced mode outside targeted diagnostics.

### Sample Snippet (Atomic Swap Core)

```powershell
$firstGrowth = 2048
$secondGrowth = 3072
Copy-Item $src $dest
# Phase 1 grow
$fs = [IO.File]::Open($dest,'Open','Write','ReadWrite'); try { $fs.SetLength($baseline + $firstGrowth) } finally { $fs.Dispose() }
$proc = Start-Process pwsh -PassThru -ArgumentList @('-File','tools/Start-FixtureWatcher.ps1','-Targets','VI1.vi','-DurationSeconds','10','-Quiet','-LogPath','watch.ndjson')
# Wait Initial...
$temp = Join-Path (Split-Path $dest) ([guid]::NewGuid())
Copy-Item $dest $temp; (Get-Item $temp).IsReadOnly=$false
$fs2=[IO.File]::Open($temp,'Open','Write','ReadWrite'); try { $fs2.SetLength((Get-Item $dest).Length + $secondGrowth) } finally { $fs2.Dispose() }
Move-Item $temp $dest -Force
# Poll for Changed...
```

### Future Watcher Enhancements

- Optional hash-on-demand mode: compute hash only after size delta to further reduce early contention.
- Lightweight content sampler (first/last N bytes) to avoid full `ReadAllBytes` for large files in loop tests.
- Structured diagnostic event type (instead of synthetic forced Changed) for clearer debugging without polluting metrics.

