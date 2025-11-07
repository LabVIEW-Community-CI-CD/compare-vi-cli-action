# Development Mode Functional Test Plan

## Test Matrix

1. **Enable → Missing-In-Project Passes**  
   Expect the missing-in-project job to:  
   - exit code `0`  
   - emit `passed=true` in action outputs  
   - leave no `missing_files.txt`

2. **Disable → Missing-In-Project Fails**  
   Expect the job to:  
   - exit non-zero (preferably `2`)  
   - retain `missing_files.txt`  
   - emit `passed=false`

3. **Helper Failure While Enabled**  
   Force the helper/g-cli stub to fail. Expect the wrapper to:  
   - exit with code `1`  
   - report `passed=false`  
   - not delete `missing_files.txt`

4. **Enable Wrapper Missing Helper**  
   Delete `add-token-to-labview` script before running. Expect:  
   - command fails immediately  
   - error message includes missing helper path

5. **Disable Wrapper Missing Helper**  
   Delete `restore-setup-lv-source` script before running. Expect:  
   - command fails with same missing-helper message

6. **Policy-Driven Enable/Disable Round Trip**  
   With a dev-mode policy JSON (`Compare` operation), expect:  
   - state file flips between `Active=true` / `false`  
   - `dev-mode.txt` switches `on-64` → `off-64`

## Notes for Real LabVIEW Runs

- _Placeholder: capture observations (execution time, g-cli logs, LabVIEW cleanup) once testing moves from stubs to actual installs._
- _Record any discrepancies between simulated exit codes and real g-cli behaviour._
- _Document LabVIEW versions/bitness combos exercised on hardware._

