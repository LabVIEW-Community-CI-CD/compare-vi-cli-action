## Dispatcher Failure Handling Notes

- Scenario A: `ResultsPath` is an existing file.
  - Setup: create `blocked-results.txt`, invoke dispatcher with `-ResultsPath blocked-results.txt`.
  - Expectation: exit code non-zero, terminating error references the guard crumb (`tests/results/_diagnostics/guard.json`), crumb `path` matches the resolved file, and `tests/results/_invoker` remains absent (when it did not exist before the run).
- Scenario B: `ResultsPath` is a read-only directory.
  - Setup: create directory, set the `ReadOnly` attribute, invoke dispatcher with `-ResultsPath <dir>`.
  - Expectation: same as scenario A but `path` matches the read-only directory.

Tests should capture stdout/stderr for the terminating error, assert the guard crumb content (schema `dispatcher-results-guard/v1`), and verify that no `pester-results.xml` or `pester-summary.json` files are created under the blocked directory.
