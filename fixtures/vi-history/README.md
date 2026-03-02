# VI history fixtures

These helper fixtures feed scripted history workflows (for example the `/vi-history`
PR command and the smoke helper).

## `sequential.json`

- Schema: `vi-history-sequence@v1`
- Defines the ordered set of LabVIEW VI snapshots that make up the sequential history smoke.
- Each step points to an existing fixture under `fixtures/` so we never hand-edit VI binaries.
- Consumed by `tools/Test-PRVIHistorySmoke.ps1` (and any future helpers) to replay the
  same change progression when synthesising commits.

```jsonc
{
  "schema": "vi-history-sequence@v1",
  "targetPath": "fixtures/vi-attr/Head.vi",
  "steps": [
    { "title": "VI Attribute", "source": "fixtures/vi-attr/attr/HeadAttr.vi" }
  ]
}
```

Extend the `steps` list when new scenarios are required; tests ensure every referenced
`source` path exists in the repository.

## `mixed-same-commit.json`

- Schema: `vi-history-mixed-commit@v1`
- Defines a deterministic single commit that mutates two VI targets:
  - one strict signal target (`requireDiff: true`)
  - one non-strict metadata-noise target (`requireDiff: false`)
- Consumed by `tools/Test-PRVIHistorySmoke.ps1` when
  `-Scenario mixed-same-commit` is selected.

```jsonc
{
  "schema": "vi-history-mixed-commit@v1",
  "commit": {
    "changes": [
      {
        "targetPath": "fixtures/vi-attr/Head.vi",
        "requireDiff": true
      },
      {
        "targetPath": "fixtures/vi-attr/Base.vi",
        "requireDiff": false
      }
    ]
  }
}
```

## `sequential-masscompile.json`

- Schema: `vi-history-sequence-matrix@v1`
- Defines an ordered commit chain that alternates masscompile-like metadata
  updates with one mixed signal+noise commit.
- Includes a multi-VI same-commit step (`signal-plus-masscompile`) where at
  least two VI targets are updated in one commit.
- Consumed by `tools/Test-PRVIHistorySmoke.ps1` when
  `-Scenario sequential-masscompile` is selected.

## Policy Gate Semantics

`tools/Test-PRVIHistorySmoke.ps1` evaluates each expected target with a hybrid
policy contract:

- `strict` (`requireDiff: true`):
  - missing rows, zero comparisons, or missing required diffs are **hard
    failures** (blocking).
- `smoke` (`requireDiff: false`):
  - the same conditions are emitted as **warnings** (non-blocking) so
    diagnostics stay visible without failing the run.

The smoke summary JSON now includes `Policy` (`vi-history-policy-gate@v1`) with
separate strict failure and smoke warning buckets.
