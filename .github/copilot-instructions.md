## AI Coding Agent Quick Guidance (compare-vi-cli-action)

Purpose: Composite GitHub Action (PowerShell) that diff-checks two LabVIEW `.vi` files via NI `LVCompare.exe`, plus an optional latency / diff loop module and rich Pester test harness. Keep changes Windows‑only; do not add non‑PowerShell build systems.

### Architecture
- `action.yml`: Core composite logic; single‑run path uses `scripts/CompareVI.ps1`; loop path imports `module/CompareLoop` and emits aggregate metrics.
- `module/CompareLoop/`: `Invoke-IntegrationCompareLoop` (percentiles, histogram, diff summary, snapshots, run summary).
- `scripts/`: Automation helpers (`Run-AutonomousIntegrationLoop.ps1`, control & report scripts).
- Test dispatchers: `Invoke-PesterTests.ps1` (self‑hosted, PS7+), `tools/Run-Pester.ps1` (auto-install, PS 5.1+), `tools/Watch-Pester.ps1` (change-aware loop).
- Schemas: `docs/schemas/*.schema.json` (loop events/final status/run summary/etc.) – additive changes only; never rename existing keys without version bump.

### Core Policies
1. Canonical LVCompare path ONLY: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` (all resolution methods must land here).
2. Exit codes: 0=no diff, 1=diff, other=failure. `diff` output derives strictly from that mapping.
3. Timing outputs: `compareDurationSeconds` + `compareDurationNanoseconds` (loop mode: represent average latency).
4. HTML diff summary (loop/module) is a fragment, deterministic `<ul>` ordering, all dynamic values HTML‑encoded.
5. Percentile strategies: `Exact`, `StreamingReservoir` (alias `StreamingP2`), `Hybrid`; always surface legacy `p50/p90/p99` even if custom list added. Decimal percentile labels: `97.5 -> p97_5`.

### Key Workflows
- Unit tests (fast): `./Invoke-PesterTests.ps1` (excludes Integration by default).
- All tests (needs LVCompare + env): set `LV_BASE_VI`, `LV_HEAD_VI`; run with `-IncludeIntegration true`.
- Quick loop simulation (no real CLI): set `LOOP_SIMULATE=1` then `pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1`.
- Watch mode: `./tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly -InferTestsFromSource`.

### Conventions & Test Patterns
- Per‑test function shadowing: redefine `Get-Module` inside each `It`; remove with `Remove-Item Function:Get-Module` (never global mocks).
- Skip gating: compute prereq flags once; use `-Skip:(...)` instead of early returns.
- Test files: `Name.Tests.ps1`; helpers may be dot‑sourced (keep relative paths stable).
- Synthetic flags (`-SkipValidation`, `-PassThroughPaths`, `-BypassCliValidation`) restricted to tests & loop simulation.

### Loop Mode (Action Inputs Prefixed `loop-*`)
When `loop-enabled=true`: executes iterative comparisons (or simulated) and emits: `iterations`, `diffCount`, `errorCount`, `averageSeconds`, `totalSeconds`, `p50/p90/p99`, `quantileStrategy`, `streamingWindowCount`, plus JSON summary (`compare-loop-summary.json`). Histogram optional via `histogram-bins`.

### Schema & Versioning Rules
- JSON artifacts carry explicit `schema` / version fields; additive fields => patch/minor bump only. Never remove/rename existing keys without major bump + test updates.

### Adding Inputs / Outputs
1. Edit `action.yml` (inputs + outputs). 2. Regenerate docs: `npm run generate:outputs` updating `docs/action-outputs.md`. 3. Add/extend tests asserting presence & semantics. 4. Update README usage snippet.

### Common Pitfalls (Avoid)
- Non-deterministic ordering (HTML list, JSON field emission). Keep stable for tests.
- Altering exit code mapping or canonical path logic without updating dependent skip heuristics + tests.
- Writing empty diff summary file when no diffs (should be absent & `$null`).
- Leaving a shadowed `Get-Module` function undeleted (leaks to later tests).
- Performing filesystem side-effects at test script top-level (do inside `BeforeAll`).

### Troubleshooting (Mini Table)
| Symptom | Likely Cause | Fast Fix |
|---------|--------------|----------|
| Action fails: "LVCompare.exe not found" | Path not canonical | Ensure file exists at canonical path; any override must resolve exactly there. |
| `diff` output blank / unexpected | Exit code not 0 or 1 (error) | Inspect `exitCode` and step summary; treat only 0/1 as semantic diff states. |
| Loop mode percentiles empty | Insufficient iterations or all skipped | Increase iterations; verify not simulating with zero delay causing skips. |
| HTML diff summary file missing | No diff iterations occurred | Expected: fragment only written when `DiffCount > 0`. |
| Tests randomly fail after Pester version simulation | Shadowed `Get-Module` leaked | Add `Remove-Item Function:Get-Module` at end of each `It`. |
| Integration tests all skipped | Canonical CLI or env vars absent | Set `LV_BASE_VI` / `LV_HEAD_VI` and install CLI at canonical path. |
| Non‑deterministic test failure on HTML summary | List order changed | Restore deterministic `<ul>` item ordering; HTML‑encode all dynamic values. |
| Reservoir metrics unstable (p99 swings) | Stream capacity too small | Increase `stream-capacity` or enable `reconcile-every`. |
| Loop JSON missing histogram | `histogram-bins` unset or zero | Provide a positive bin count input. |
| Added field broke consumers | Schema key renamed/removed | Revert rename; only add new keys + version bump if necessary. |
| Report shows `Unknown/Failure (X)` exit text | Exit code not 0/1 (unexpected LVCompare failure) | Inspect raw LVCompare execution (stderr/log); only 0/1 map to diff semantics—fix underlying CLI error before interpreting results. |

### `lvCompareArgs` Quick Recipes
- Noise filters (recommended baseline): `-nobdcosm -nofppos -noattr` (ignore cosmetic BD, FP position, VI attrs).
- Specify LabVIEW executable (multi-version rigs): `-lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe"`.
- Pass path with spaces: `--flag "C:\\Temp\\My Folder\\out.txt"`.
- Combine multiple flags: `-nobdcosm -nofppos -noattr -lvpath "C:\\...\\LabVIEW.exe"`.
- Environment interpolation (workflow YAML): `lvCompareArgs: "-nobdcosm -nofppos -noattr --log \"${{ runner.temp }}\\lvcompare.log\""`.
- Strict diff (no noise suppression): (omit filters) – ensure tests cover both filtered & raw cases.
- Add future flags: keep ordering deterministic; append at end; update README example & add test asserting tokenization.

### HTML Report Generation
Two approaches:
1. LabVIEW CLI (external) for visual single-file diff (see README knowledgebase).
2. Internal summarizer `scripts/Render-CompareReport.ps1` (HTML metadata wrapper; does NOT embed graphical VI diff).

Internal script parameters (required): `-Command`, `-ExitCode`, `-Diff ('true'|'false')`, `-CliPath`; optional: `-Base`, `-Head`, `-OutputPath`, `-DurationSeconds` (use action output `compareDurationSeconds`). If `Base/Head` omitted they are parsed from the command tokens 1 & 2.

Example (after action step):
```powershell
pwsh -File scripts/Render-CompareReport.ps1 `
	-Command "$($env:COMPARE_COMMAND)" `
	-ExitCode $env:COMPARE_EXIT_CODE `
	-Diff $env:COMPARE_DIFF `
	-CliPath $env:COMPARE_CLI_PATH `
	-DurationSeconds $env:COMPARE_DURATION_SECONDS `
	-OutputPath compare-report.html
```
Populate envs from `${{ steps.compare.outputs.* }}` in workflow if you want artifact publishing.

HTML file guarantees: UTF‑8, deterministic key ordering, fully self-contained (no external assets), command HTML‑encoded.

### Capturing LVCompare stderr (Artifact)
When diagnosing unexpected non 0/1 exit codes, capture stderr & stdout to files and upload as artifacts (do not alter action code unless adding tested feature flag).

Workflow snippet (single-run mode):
```yaml
	- name: Compare VIs
		id: compare
		uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@vX.Y.Z
		with:
			base: VI1.vi
			head: VI2.vi
			fail-on-diff: false
	- name: Capture raw CLI output
		if: always()
		shell: pwsh
		run: |
			# Reconstruct command (already emitted as output) and re-run capturing streams
			$cmd = '${{ steps.compare.outputs.command }}'
			Write-Host "Replaying: $cmd";
			$psi = New-Object System.Diagnostics.ProcessStartInfo
			$psi.FileName = 'pwsh'
			$psi.ArgumentList = '-NoLogo','-NoProfile','-Command',$cmd
			$psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
			$p = [System.Diagnostics.Process]::Start($psi)
			$stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
			Set-Content raw-lvcompare-stdout.txt $stdout -Encoding utf8
			Set-Content raw-lvcompare-stderr.txt $stderr -Encoding utf8
			"$($p.ExitCode)" | Set-Content raw-lvcompare-exitcode.txt
	- name: Upload raw compare logs
		if: always()
		uses: actions/upload-artifact@v4
		with:
			name: lvcompare-raw-logs
			path: |
				raw-lvcompare-stdout.txt
				raw-lvcompare-stderr.txt
				raw-lvcompare-exitcode.txt
```
Notes:
- Replay uses emitted `command`; for safety treat non-canonical path results as failure.
- Avoid embedding secrets in `lvCompareArgs`; artifacts are plaintext.
- For loop mode, wrap executor injection instead (capture inside custom CompareExecutor passed to `Invoke-IntegrationCompareLoop`).

### Loop Mode: Custom Executor With Inline Capture
Use a custom `-CompareExecutor` scriptblock to intercept exit codes & timing without re-running after the loop:
```powershell
Import-Module ./module/CompareLoop/CompareLoop.psd1 -Force
$captures = [System.Collections.Generic.List[object]]::new()
$exec = {
	param($cli,$base,$head,$args)
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	# Real invoke (no simulation): rely on canonical path already validated upstream
	$psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName=$cli; ArgumentList=@($base,$head) }
	$psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true; $psi.UseShellExecute=$false
	$p = [System.Diagnostics.Process]::Start($psi)
	$stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit(); $sw.Stop()
	$captures.Add([pscustomobject]@{ ts=[DateTime]::UtcNow; exit=$p.ExitCode; ms=$sw.ElapsedMilliseconds; stderr=$stderr; stdoutLen=$stdout.Length }) | Out-Null
	return $p.ExitCode
}
$r = Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 5 -IntervalSeconds 0 `
	-CompareExecutor $exec -Quiet -PassThroughPaths -BypassCliValidation -SkipValidation
$captures | Format-Table -AutoSize
```
Guidelines:
- Keep objects lightweight (avoid storing full stdout for large runs—store lengths or sample lines).
- Return only numeric exit code; loop interprets 0/1; others count as errors.
- Use `-PassThroughPaths -BypassCliValidation -SkipValidation` only in controlled test/scenario contexts.

### Fast Reference Commands
```powershell
# Unit tests
./Invoke-PesterTests.ps1
# All tests (integration)
$env:LV_BASE_VI='VI1.vi'; $env:LV_HEAD_VI='VI2.vi'; ./Invoke-PesterTests.ps1 -IncludeIntegration true
# Simulated autonomous loop
$env:LV_BASE_VI='VI1.vi'; $env:LV_HEAD_VI='VI2.vi'; $env:LOOP_SIMULATE='1'; pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

Questions / gaps? Open an issue or request deeper detail (e.g., percentile internals or snapshot schemas) and update this file with any newly codified invariants.
