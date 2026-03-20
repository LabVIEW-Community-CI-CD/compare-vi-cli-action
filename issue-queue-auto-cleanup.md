## Summary

`priority:merge-sync` will stop emitting `--delete-branch` for queue-managed admin merges in #1397 and will preserve cleanup through immediate post-merge API deletion when the promotion materializes synchronously.

The remaining gap is queue-managed `--auto` promotion:
- cleanup is still requested when `keepBranch=false`
- but there is no immediate merge event in the current helper turn
- branch cleanup therefore stays deferred and depends on repository auto-delete settings or manual follow-up

## Needed

- add a deterministic post-queue branch cleanup path for queued auto merges
- record cleanup completion/deferment in merge receipts so unattended agents can reconcile it later
- keep queue-compatible merge commands free of inline `--delete-branch`
