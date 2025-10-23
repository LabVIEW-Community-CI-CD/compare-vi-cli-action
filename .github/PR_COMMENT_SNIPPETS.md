# PR Comment Snippets

Use these snippets in PR comments to (re)run workflows with explicit, reproducible inputs. Replace placeholders in angle
brackets.

## Re-run Orchestrated With Same Inputs

- Copy `strategy`, `include_integration`, and `sample_id` from the previous run's "Run Provenance" block (or choose new
  values).
- Paste this as a new PR comment:

```
/run orchestrated strategy=<single|matrix> include_integration=<true|false> sample_id=<same-or-new-id>
```

Notes:
- Prefer `strategy=single` under typical load; use `matrix` when runners are idle.
- Re-using the same `sample_id` links runs for easier comparison and can help idempotency.
- If you omit `sample_id`, the dispatcher will generate one automatically.

## Quick Variants

- Single (deterministic chain):
```
/run orchestrated strategy=single include_integration=true sample_id=<id>
```
- Matrix (parallel categories):
```
/run orchestrated strategy=matrix include_integration=true sample_id=<id>
```

