# Agent Flow 1.1.0 Requirements (Verifiable)

- Version: 1.1.0
- Issue: #88

## Legend

- MUST: hard requirement; CI should enforce or fail.
- SHOULD: recommended; notice-only in CI.
- VERIFY: how to validate locally/CI.

---

## R1 — Deterministic Locking (MUST)

- All self-hosted Windows “heavy” jobs acquire the `pester-selfhosted` lock before work and release it after (finally path).
- VERIFY (CI):
  - Workflow logs show step “Acquire session lock” succeeded and “Release session lock” executed.
  - `tests/results/_session_lock/pester-selfhosted/status.md` exists during the run and is cleared by job end.

## R2 — Preflight Hygiene (MUST)

- Preflight runs `runner-unblock-guard` with cleanup gating and fails if `LabVIEW.exe` is running.
- VERIFY (CI): step summary contains “Runner Unblock Guard” snapshot link and preflight OK message; failures list PID(s).

## R3 — Cleanup Policy Defaults (MUST)

- Repo vars default: `CLEAN_LV_BEFORE=true`, `CLEAN_LV_AFTER=true`, `CLEAN_LV_INCLUDE_COMPARE=true`.
- VERIFY (CI): environment dump in logs shows the three vars; guard steps indicate cleanup performed when relevant.

## R4 — Inline Heartbeat (MUST)

- Dispatcher writes `tests/results/pester-heartbeat.ndjson` without spawning background `pwsh` jobs.
- VERIFY (CI): file exists and appends beats; guard snapshots show no accumulating `pwsh` processes across cancellations.

## R5 — Warmup Normalization (MUST)

- `tools/Warmup-LabVIEW.ps1` defaults bitness from env/64, forwards to runtime script, and safely propagates `$LASTEXITCODE`.
- VERIFY (CI): warmup step logs show bitness, resolved path, start/stop or skip reason; wrapper no longer throws ValidateSet or LASTEXITCODE errors.

## R6 — LV Notice Directory UX (SHOULD)

- When `LV_NOTICE_DIR` is missing, job searches `results/fixture-drift/**/_lv` and logs fallback; strict single-launch assertion only fails with clear reason.
- VERIFY (CI): logs show “LV notice directory fallback → … (original=…)” or skip reason; strict step fails with `notice_dir_absent_strict` reason code when enabled.

## R7 — Re-run Hint + Provenance (SHOULD)

- Each gate (Pester, Drift, Orchestrated) appends re-run snippet and provenance block (runId, workflow, ref, sample_id, include_integration).
- VERIFY (CI): job summaries contain “Re-run With Same Inputs” and a provenance section.

## R8 — Current State Summary (SHOULD)

- Summaries include: runner busy/online, lock status (LockId/age/holder), LVCompare path resolved, idle LV result, notice dir path/fallback, heartbeat count/last timestamp.
- VERIFY (CI): presence of these bullets in the step summary; values match runtime conditions.

## R9 — Non-Interactive Defaults (MUST)

- Jobs set `LV_SUPPRESS_UI=1`, `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`, `LV_IDLE_WAIT_SECONDS=2`, `LV_IDLE_MAX_WAIT_SECONDS=5`.
- VERIFY (CI): environment section lists these values; guard and warmup logs reflect the idle gates.

## R10 — Failure Ergonomics (SHOULD)

- Preflight failures list PIDs and sessions; warmup failures list resolved path/version/bitness and hint to set `LABVIEW_PATH` or repo vars; notice dir asserts emit clear reasons.
- VERIFY (CI): error annotations/summary lines contain actionable details and suggestions.

---

## R11 — No Overlap (MUST)

- At most one heavy Windows job (Pester/Drift/Orchestrated) is active on the self-hosted runner at any time.
- VERIFY (CI): `gh run list --status in_progress` shows at most one Windows heavy job; additional runs wait until the lock is released.

## R12 — Merge Readiness (SHOULD)

- All required checks green for PRs tying to this flow; summaries include re-run links and artifacts; repo ready for merge queue enablement after stable cycles.
- VERIFY (CI): PR reports green; summaries show rerun and artifact links; optional merge queue configured for `develop`.

---

## Traceability Matrix

| Req | Implementation | Verification Evidence |
|-----|----------------|-----------------------|
| R1  | `.github/workflows/pester-reusable.yml` (Acquire/Release session lock); `tools/Session-Lock.ps1` | status.md present/cleared; lock steps in logs |
| R2  | Preflight steps in `.github/workflows/pester-reusable.yml`; `.github/actions/runner-unblock-guard/action.yml` | preflight summary shows idle LV OK or PIDs/sessions |
| R3  | Cleanup env + guard cleanup gating across workflows | guard snapshot shows cleanup counts; env dump lists vars |
| R4  | `Invoke-PesterTests.ps1` inline heartbeat (no Start-Job) | `pester-heartbeat.ndjson`; no orphan pwsh across cancels |
| R5  | `tools/Warmup-LabVIEW.ps1` → runtime; bitness default; exit guard | warmup logs show path/bitness; no ValidateSet/LASTEXITCODE errors |
| R6  | Notice dir fallback in `.github/workflows/fixture-drift.yml` | fallback message or strict reason code present |
| R7  | Re-run hint + provenance in Pester/Drift/Orchestrated | summaries contain rerun command + provenance fields |
| R8  | Summary bullets via guard + workflow steps | bullets present (runner/lock/LVCompare/idle/notice/heartbeat) |
| R9  | LV_* defaults in Pester/Drift/Orchestrated env | env dump shows toggles; idle gates applied |
| R10 | Actionable error messaging in preflight/warmup/notice checks | annotations + summaries show fix hints |
| R11 | Lock + concurrency group enforce single active job | `gh run list` shows single in_progress heavy job |
| R12 | Required checks + artifacts + rerun hint; merge queue ready | PR status green; summaries link artifacts/rerun |

---

## Verification Hints (Local)

- Lock: `pwsh -File tools/Session-Lock.ps1 -Action Acquire -Group 'pester-selfhosted'` then `... -Action Release`.
- Rogue scan: `pwsh -File tools/Detect-RogueLV.ps1 -ResultsDir tests/results -LookBackSeconds 900`.
- Warmup: `pwsh -File tools/Warmup-LabVIEW.ps1 -MinimumSupportedLVVersion 2025` (optionally set `LABVIEW_PATH`).
- Dispatcher heartbeat: run a small Pester selection and confirm `tests/results/pester-heartbeat.ndjson`.
