# Copilot CLI Local Review Contract

- Use GitHub Copilot CLI only in the local `draft-review` loop.
- Run it through the repo-owned wrapper surfaces under `tools/local-collab/providers/`.
- Precedence:
  - `AGENTS.md` is the repo-wide policy authority.
  - This file narrows GitHub Copilot CLI behavior for the local review plane.
  - `.github/instructions/*.instructions.md` may add phase guidance but must not
    widen review, queue, or promotion authority beyond this file and
    `AGENTS.md`.
- Keep review runs head-scoped and focused on the current staged diff or current branch delta only.
- Preserve and honor:
  - `AGENTS.md`
  - `.github/instructions/draft-only-copilot-review.instructions.md`
  - `.github/instructions/final-ready-validation.instructions.md`
- Do not treat local Copilot CLI output as merge, queue, or promotion authority.
- Hosted required checks and final ready-validation remain authoritative for promotion.
- If the head SHA changes after a local review receipt is created, treat the receipt as stale and rerun the local review.
- Prefer least-privilege CLI execution. Keep `allowAllTools=false`, keep the explicit
  tool allowlist empty unless a tracked policy change widens it, and do not
  reuse prior CLI sessions across branch heads.
