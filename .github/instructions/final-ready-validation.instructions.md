# Ready-for-Review Means Final Validation

- Use `ready_for_review` only when the current head is locally reviewed and is
  ready for final hosted validation.
- Before marking ready, require all of the following on the current head:
  - the Docker/Desktop review receipt exists
  - the receipt is passing
  - the receipt is tracked-clean
  - the receipt covers all requested review surfaces
  - no unresolved current-head Copilot comments remain
- Do not request or wait for a second Copilot review after `ready_for_review`.
- Treat merge, merge-queue admission, and admin promotion as blocked if the
  current head changed after draft review or if unresolved current-head Copilot
  comments remain.
- If a new commit lands after ready, return the pull request to draft and
  restart the local-plus-Copilot review loop.
