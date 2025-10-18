<!-- markdownlint-disable-next-line MD041 -->
# Priority queue deadlock investigation

## Summary

The standing-priority sync is currently stuck on cached metadata because every live fetch path fails.
【493f17†L1-L9】
【F:.agent_priority_cache.json†L1-L16】
【F:tests/results/_agent/issue/134.json†L1-L14】
`priority:sync` reports that the GitHub CLI cannot be invoked and the REST fallback also errors.
As a result, the snapshot never refreshes beyond the cache copy from 2025-10-15.
【493f17†L1-L9】
【F:.agent_priority_cache.json†L1-L16】
【F:tests/results/_agent/issue/134.json†L1-L14】

## Evidence

- Running `priority:sync` falls back to cached data because the `gh` command is missing and REST requests error out.
  The command logs both the missing CLI and the failed fetch attempt.
  【493f17†L1-L9】
- The cache records that the last successful fetch source was the cache itself.
  It preserves the failure message (`gh CLI not found`).
  The sync loaded no fresh labels or assignees.
  The `lastSeenUpdatedAt` timestamp shows the queue has not advanced since 2025-10-15.
  【F:.agent_priority_cache.json†L1-L16】
- The standing-priority router still shows only the default pre-commit/multi/lint actions from the October snapshot.
  That confirms the queue never rotated to any new actions or issues.
  That behavior indicates the router still mirrors the stale October snapshot.
  【F:tests/results/_agent/issue/router.json†L1-L32】
- Direct REST requests from Node fail with `ENETUNREACH`.
  Even with a token the environment cannot reach api.github.com right now.
  【c055b7†L1-L16】

## Unblocking options

1. Restore a working GitHub CLI (`gh`) in `PATH` or run the repo tools from a host where `gh` is available.
   Either option lets the sync pull the live issue list again.
   【493f17†L1-L9】
2. Provide outbound GitHub API access (e.g., set `GH_TOKEN` once network egress is available).
   That connectivity allows the REST fallback to succeed when `gh` is unavailable.
   【493f17†L1-L9】
   【c055b7†L1-L16】
3. For fully offline work, temporarily set `AGENT_PRIORITY_OVERRIDE`.
   Alternatively, run `tools/Get-StandingPriority.ps1 -CacheOnly`.
   That override points the router at the desired issue so it can progress without live fetches.
   【F:tools/Get-StandingPriority.ps1†L56-L92】
   【F:tools/Get-StandingPriority.ps1†L187-L205】

Tracking these mitigations should unblock the queue once network or CLI access returns.
Sustained access ensures the standing-priority workflow can rotate to new issues again.
