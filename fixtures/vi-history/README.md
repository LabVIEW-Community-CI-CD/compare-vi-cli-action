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
