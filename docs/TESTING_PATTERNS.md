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

## Watcher-Specific Patterns

### Helper Utilities

Watcher tests involving file mutation and FileSystemWatcher event validation use centralized helper utilities located in `tests/support/WatcherMutation.ps1`. These provide two-phase atomic file operations to ensure deterministic test behavior.

**Purpose:**

- Enable reliable file growth and atomic replacement for watcher event testing
- Abstract transient I/O error handling with retry logic
- Provide deterministic filler patterns for file growth

**Available Functions:**

1. **`New-GrownCopy`** - Copies a source file and grows it by appending extra bytes
   - Parameters: `-Source <path>`, `-ExtraBytes <int>`, `-Destination <optional path>`
   - Returns object with `Path` and `FinalLength` properties
   - Uses deterministic 'A' byte pattern for growth

2. **`Invoke-AtomicSwap`** - Atomically replaces original file with replacement file
   - Parameters: `-Original <path>`, `-Replacement <path>`, `-MaxRetries 12`, `-RetryDelayMs 50`
   - Handles read-only attributes and retries on transient I/O errors
   - Returns boolean success indicator

**Usage Example (from FixtureWatcher.ChangeHash.Tests.ps1):**

```powershell
BeforeAll {
  . "$PSScriptRoot/support/WatcherMutation.ps1"
  $script:baselineFile = Join-Path $TestDrive "baseline.txt"
  "Original content" | Set-Content -NoNewline -LiteralPath $script:baselineFile -Encoding utf8
}

It 'detects file change via grown copy and atomic swap' {
  # Use helper to create grown copy
  $grown = New-GrownCopy -Source $script:baselineFile -ExtraBytes 100
  $grown.FinalLength | Should -BeGreaterThan (Get-Item -LiteralPath $script:baselineFile).Length

  # Use helper to atomically swap
  $swapSuccess = Invoke-AtomicSwap -Original $script:baselineFile -Replacement $grown.Path
  $swapSuccess | Should -BeTrue
  
  # Verify file hash changed
  $newHash = (Get-FileHash -LiteralPath $script:baselineFile -Algorithm SHA256).Hash
  # ... assertions
}
```

### Zero-Length Changed Guard

**Rationale:** Prevent regression where FileSystemWatcher emits `Changed` events for zero-length files, which can cause spurious event spam and invalid hash calculations.

**Test:** `tests/FixtureWatcher.ZeroLengthGuard.Tests.ps1`

**Validation Strategy:**

- Start watcher without debug/force flags
- Run for bounded polling window (e.g., 600ms)
- Assert: No `Changed` event where file `Length -eq 0`
- Passes reliably with typical runtime < 1s

**Code Fragment:**

```powershell
It 'does not emit Changed events with zero length during polling window' {
  $fsw = [System.IO.FileSystemWatcher]::new($watchDir)
  $fsw.EnableRaisingEvents = $true
  
  # ... register event handler that captures file length
  
  Start-Sleep -Milliseconds 600
  
  # Verify no zero-length Changed events
  foreach ($evt in $receivedEvents) {
    $fileInfo = Get-Item -LiteralPath $evt.SourceEventArgs.FullPath
    $fileInfo.Length | Should -BeGreaterThan 0
  }
}
```

### Startup Poll Delay Test

**Purpose:** Validate that watcher honors `WATCHER_STARTUP_POLL_DELAY_MS` environment variable for deferring initial polling operations.

**Test:** `tests/FixtureWatcher.StartupDelay.Tests.ps1`

**Validation Approach:**

- Set environment variable to modest delay (e.g., 150ms)
- Start watcher and record start timestamp
- Trigger immediate file change (before delay window)
- Wait beyond delay window and trigger second change
- Verify environment variable was applied correctly
- Test runtime typically < 1s

**Timing Considerations:**

- Use generous overall timeout (e.g., 1.5s) to avoid flakiness
- Allow tolerance for event processing latency
- Rely on monotonic stopwatch for elapsed time calculation
- Core assertion: env var is respected by configuration layer

**Implementation Notes:**

- FileSystemWatcher events are asynchronous; avoid strict timing assertions
- Focus on configuration validation rather than precise event timing
- Restore original env var value in `finally` block

### Tagging

All watcher-related tests include a shared `Watcher` tag in the `Describe` block for selective test runs:

```powershell
Describe 'FixtureWatcher ChangeHash' -Tag 'Unit', 'Watcher' { ... }
Describe 'FixtureWatcher ZeroLengthChangedGuard' -Tag 'Unit', 'Watcher' { ... }
Describe 'FixtureWatcher StartupPollDelay' -Tag 'Unit', 'Watcher' { ... }
```

**Running watcher tests only:**

```powershell
Invoke-Pester -Tag Watcher -Output Detailed
```

---

## Future Enhancements

- Optional wrapper to run nested dispatcher in a separate PowerShell process to further insulate mock state.
- Add a focused regression test ensuring PesterAvailability continues to pass after a nested dispatcher run with synthetic failures.

Contributions welcome—open an issue or PR if you extend these patterns.
