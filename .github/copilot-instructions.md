# Copilot CLI Local Review Contract

- Use GitHub Copilot CLI only in the local `draft-review` loop.
- Run it through the repo-owned wrapper surfaces under `tools/local-collab/providers/`.
- Keep review runs head-scoped and focused on the current staged diff or current branch delta only.
- Preserve and honor:
  - `AGENTS.md`
  - `.github/instructions/draft-only-copilot-review.instructions.md`
  - `.github/instructions/final-ready-validation.instructions.md`
- Do not treat local Copilot CLI output as merge, queue, or promotion authority.
- Hosted required checks and final ready-validation remain authoritative for promotion.
- If the head SHA changes after a local review receipt is created, treat the receipt as stale and rerun the local review.
- Prefer least-privilege CLI execution. Do not widen tools/permissions without an explicit tracked policy change.
