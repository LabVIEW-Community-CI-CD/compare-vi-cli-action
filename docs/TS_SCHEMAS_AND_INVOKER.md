# TypeScript Schemas & Invoker Plan (Approved)

This document captures the minimal, incremental plan to introduce TypeScript as a
typed source of truth for artifact schemas and to gradually move the long‑running
invoker loop out of PowerShell.

## Goals

- Single source of truth for JSON/NDJSON artifacts (zod/io‑ts), with JSON Schema
  generation for validation.
- Robust, typed invoker loop with per‑run isolation and stale‑state cleanup.
- Keep existing PowerShell entry points; adopt changes behind small, controlled switches.

## Phases

1) Schemas package
 - Define types for: compare-exec, lvcompare-notice, agent-wait, pester-summary,
   pester-leak-report, single-compare-state, pester-invoker.ndjson.
 - Emit JSON Schemas; optional PS validation helper may consume them.
  - Surface `teststand-compare-session/v1` (output of `tools/TestStand-CompareHarness.ps1`) and
    provide a thin Node CLI that shells to the harness.

2) Test discovery manifest
   - Small TS tool to classify test files by `-Tag 'Integration'` and emit a manifest.
   - Feed the manifest into existing PS dispatcher (explicit file lists), keeping tag filters.

3) Invoker (optional switch)
   - TS service that handles `CompareVI`, `RenderReport`, `PhaseDone` with per‑run `runId`,
     atomic writes, and TTL cleanup for stale state.
   - Replace `RunnerInvoker.psm1` in CI first; keep PS as fallback.

4) Consolidation
   - Remove legacy shims and duplicated PS blocks once adoption is stable.

## Guardrails

- No change to default behavior unless explicitly opted in.
- Keep `tools/PrePush-Checks.ps1` as the single pre‑push entry; call TS utilities when present.
- Keep CompareVI policy (canonical path) intact.

## Quick Wins (already addressed)

- Dot‑sourcing removed from tests; policy guard added.
- Single‑invoker now enforces tag filters per file to prevent Integration leakage.
- Optional `-LiveOutput` streams Pester progress to console for local use.
