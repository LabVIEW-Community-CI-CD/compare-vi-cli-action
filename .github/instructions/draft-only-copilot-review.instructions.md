# Draft-Only Copilot Review for Agent PRs

- Precedence:
  - `AGENTS.md` remains the repo-wide policy authority.
  - `.github/copilot-instructions.md` remains the Copilot CLI authority for the
    local review plane.
  - This file is a phase-specific overlay and must not widen review, queue, or
    promotion authority beyond those sources.
- Scope: agent-authored pull requests in `compare-vi-cli-action`.
- Keep the pull request in draft while implementation, local parity, and comment
  resolution are still in progress.
- Request or expect Copilot review only while the pull request is draft.
- Do not use `ready_for_review` to solicit a second Copilot pass.
- Resolve current-head Copilot comments before leaving draft.
- If a new commit lands, treat older Copilot review state as stale and repeat
  the draft-phase review loop on the new head.
- For standing-priority lanes, automation owns draft/ready transitions unless a
  human explicitly intervenes.
