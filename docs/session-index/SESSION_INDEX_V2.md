<!-- markdownlint-disable-file MD041 -->

# Session Index v2 – proposal

> Heroic goal: Turn the session index into the single source of truth for CI
> telemetry – rich enough to capture live branch protection state, per–test
> metadata, requirement traceability, and downstream artefact links.

## Objectives

1. **Typed service layer** – Generate session-index.json via a TypeScript module
   instead of direct PowerShell JSON manipulation.
2. **Extensible schema** – Expand beyond run summaries to include per-test
   metadata (requirements, rationale, expected results), artefact catalogues,
   live branch-protection snapshots, and diagnostic notes.
3. **Callback-friendly orchestration** – Provide pre/post hooks so Pester (or
   any harness) can emit structured test events that the writer consumes.
4. **Backwards compatibility** – Keep the existing v1 schema during migration.
   Producers opt into v2, consumers can reference both until the transition is
   complete.

## Proposed shape

```jsonc
{
  "schema": "session-index/v2",
  "schemaVersion": "2.0.0",
  "generatedAtUtc": "2025-10-11T18:52:28Z",
  "run": {
    "id": "github-actions/18433434521",
    "attempt": 1,
    "workflow": "Validate",
    "job": "session-index",
    "branch": "develop",
    "commit": "64df3a765246d562f4051515bc90f8dac656574f",
    "trigger": {
      "kind": "pull_request",
      "number": 119,
      "author": "svelderrainruiz"
    },
    "branchState": {
      "branch": "develop",
      "upstream": "origin/develop",
      "summary": "Branch develop: up-to-date with origin/develop; dirty (includes untracked files)",
      "ahead": 0,
      "behind": 0,
      "hasUpstream": true,
      "isClean": false,
      "hasUntracked": true,
      "timestampUtc": "2025-10-11T18:52:20Z"
    }
  },
  "environment": {
    "runner": "ubuntu-24.04",
    "node": "20.11.1",
    "pwsh": "7.5.3",
    "toggles": {
      "schema": "agent-toggle-values/v1",
      "schemaVersion": "1.0.0",
      "generatedAtUtc": "2025-10-11T18:52:28Z",
      "manifestDigest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "manifestGeneratedAtUtc": "2025-10-11T18:52:28Z",
      "profiles": ["ci-orchestrated"],
      "values": {
        "SKIP_SYNC_DEVELOP": {
          "value": false,
          "valueType": "boolean",
          "source": "profile",
          "profile": "ci-orchestrated",
          "description": "Skip automatic develop branch sync during bootstrap (set to 1/true only when a frozen snapshot is required)."
        },
        "HANDOFF_AUTOTRIM": {
          "value": true,
          "valueType": "boolean",
          "source": "profile",
          "profile": "ci-orchestrated",
          "description": "Automatically trim watcher logs during agent hand-off when telemetry indicates oversize and cooldown permits."
        }
      }
    }
  },
  "branchProtection": {
    "status": "error",
    "reason": "api_forbidden",
    "expected": ["Validate / lint", "Validate / fixtures", "Validate / session-index"],
    "produced": ["Validate / lint", "Validate / session-index"],
    "actual": {
      "status": "available",
      "contexts": ["Validate", "Workflows Lint"]
    },
    "notes": [
      "Branch protection query failed: Response status code does not indicate success: 403 (Forbidden)."
    ],
    "mapping": {
      "path": "tools/policy/branch-required-checks.json",
      "digest": "9121da2e7b43a122c02db5adf6148f42de443d89159995fce7d035ae66745772"
    }
  },
  "tests": {
    "summary": {
      "total": 7,
      "passed": 7,
      "failed": 0,
      "errors": 0,
      "skipped": 0,
      "durationSeconds": 14.75
    },
    "cases": [
      {
        "id": "Invoke-Pester::Watcher.BusyLoop.Tests::When the watcher hangs it exits",
        "category": "Watcher.BusyLoop.Tests.ps1",
        "requirement": "REQ-1234",
        "rationale": "Busy loop detection must terminate the watcher within 120s.",
        "expectedResult": "Watcher exits with code 2 and writes hang telemetry.",
        "outcome": "passed",
        "durationMs": 1739,
        "artifacts": [
          "tests/results/watcher-busyloop/pester-results.xml"
        ],
        "tags": ["busy-loop", "watcher"]
      }
    ]
  },
  "artifacts": [
    {
      "name": "pester-summary",
      "path": "tests/results/pester-summary.json",
      "kind": "summary"
    },
    {
      "name": "compare-report",
      "path": "tests/results/compare-report.html",
      "kind": "report"
    }
  ],
  "notes": [
    "LVCompare-only mode enforced (no LabVIEW.exe discovered).",
    "Watcher telemetry trimmed automatically."
  ]
}
```

Key differences from v1:

* `run` replaces the bare `runContext` block, with explicit trigger metadata.
* `run.branchState` captures the branch/upstream relationship (ahead/behind, cleanliness, summary)
  so CLI consumers can surface deterministic branch status without re-running git.
* `tests.cases` stores per-test metadata that we can hydrate via pre/post
  callbacks inside the Pester harness.
* `branchProtection` contains canonical contexts (`expected`), the contexts the
  workflow produced (`produced`), and the live API snapshot (`actual.status` +
  `actual.contexts`) alongside diagnostic notes (allowing us to log 403s / 404s
  without losing alignment).
* `environment.toggles` records the schema id/version, manifest digest, generated-at timestamp,
  active profiles, and the resolved toggle values that shaped the run (enabling deterministic
  auditing).
* `artifacts` become first-class, linking to dashboards, compare reports, and
  trace matrices.
* `notes` is a free-form area for session-wide diagnostics.

## Implementation plan

1. **TypeScript builder (this PR)**  
   Introduce a typed builder that writes v2 objects, along with a CLI to emit
   sample indices. This keeps structure and validation in one place.

2. **PowerShell integration (follow-up)**  
   * Update existing scripts (e.g., Quick-DispatcherSmoke, Update-SessionIndexBranchProtection) to
     call the TypeScript CLI.
   * Provide thin PS wrappers so existing jobs don’t need to learn Node APIs.

3. **Per-test callbacks**  
   * Add a Pester shim that captures test metadata and streams it to the builder.
   * Populate `tests.cases` incrementally; fall back to summaries when callbacks
     are unavailable.

4. **Consumer migration**  
   * Update dashboards, trace matrices, and tooling to read v2.
   * Keep emitting v1 in parallel until all consumers understand v2.

5. **Deprecate v1**  
   * Once all jobs and dashboards read v2, freeze v1 generation and archive the
     old schema documentation.

## CLI helpers

- `node dist/src/session-index/cli.js --format json` writes the full session index (default).
- `--format values` emits a trimmed summary with branch state and toggle manifest metadata.
- `--format env` prints `SESSION_INDEX_*` environment assignments suitable for `pwsh`/`bash` export.
- `--format sample` mirrors the legacy `--sample` flag while exercising the same code paths.
- Pass `--no-check` to bypass the ADR requirements validation when intentionally experimenting;
  otherwise the CLI fails on any `error` severity violation before writing output.

## Open questions

* How much requirement metadata do we already track (e.g., via tags)?  
  We may need an annotation mechanism (`It '...' -TestMeta @{ Requirement =
  'REQ-1234' }`) to capture this cleanly.
* Do we need per-artifact checksums / sizes to help latency-sensitive tooling?
* Should branch-protection snapshots also include the raw API payload for
  auditability?

Feedback welcome before we harden the schema.
