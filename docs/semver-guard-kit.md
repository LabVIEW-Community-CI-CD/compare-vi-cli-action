# SemVer Guard Kit (Reusable Instructions)

> _Purpose_: capture the exact steps needed to lift the Icon Editor Lab SemVer tooling into sibling repos (for example, compare-vi-cli-action) while enforcing a consistent Node.js version.

## 1. Copy the SemVer script

1. Copy `src/tools/priority/validate-semver.mjs` verbatim into the target repo (keep the same relative path or adjust the npm script accordingly). To automate this, run `pwsh -File tools/Export-SemverBundle.ps1 -Zip` and unzip the result inside the destination repo.
2. Ensure the target repo’s `package.json` includes:
   ```jsonc
   {
     "scripts": {
       "semver:check": "node ./src/tools/priority/validate-semver.mjs"
     }
   }
   ```
3. (Optional) mirror the `priority:sync`, `priority:show`, or other npm helpers if you plan to sync the standing-priority router, but only `semver:check` is required for tag validation.
4. After unpacking the bundle, inspect `bundle.json` (included automatically) to confirm the SHA256 hashes match what landed in your repo:
   ```powershell
   $manifest = Get-Content bundle.json | ConvertFrom-Json
   $manifest.files | ForEach-Object {
     $hash = (Get-FileHash $_.relativePath -Algorithm SHA256).Hash
     if ($hash -ne $_.sha256) { throw "Hash mismatch for $($_.relativePath)" }
   }
   ```
   Prefer automation? Run `pwsh -File tools/Verify-SemverBundle.ps1 -BundlePath <bundle-folder-or-zip>` and the helper will expand the bundle (or zip), compute hashes, and stop on the first mismatch.

## 2. Pin the Node toolchain

1. Add the same engine + package manager metadata we use here:
   ```jsonc
   {
     "engines": { "node": ">=20.11.0" },
     "packageManager": "npm@11.6.2"
   }
   ```
2. Update every GitHub Actions workflow (or equivalent CI entry point) to call `actions/setup-node@v4` with `node-version: 20` before running npm:
   ```yaml
   - uses: actions/setup-node@v4
     with:
       node-version: 20
       cache: npm
   ```
3. Run `npm install` once on Node 20 so the resulting lockfile matches the pinned engine.

## 3. Wire SemVer into release automation

- If the target repo already has a release workflow, add a dedicated job or step that runs `npm run semver:check` and surfaces the JSON it prints.
- To capture run artifacts similar to Icon Editor Lab, write the output to `tests/results/_agent/handoff/release-summary.json` (the schema is `agent-handoff/release-v1`).

## 4. Verification checklist

| Step | Command | Expected result |
| --- | --- | --- |
| Node pin | `node -v` | `v20.x` (>= 20.11.0) |
| NPM install | `npm install` | `node_modules` + updated lock file |
| SemVer guard | `npm run semver:check` | JSON report with `"valid": true` for legal versions |

## Optional helpers

- `pwsh -File tools/Export-SemverBundle.ps1 -IncludeWorkflow` drops a ready-to-use GitHub workflow (`.github/workflows/semver-guard.yml`) plus an `IMPORT-CHECKLIST.md` reminder file. Customize the triggers or steps after copying.
- Need to copy straight into another checkout? Add `-TargetRepoRoot C:\path\to\compare-vi-cli-action` and the script will place the SemVer script/docs (and optional workflow) directly into that repo in addition to emitting the bundle.

Keep this file in sync with `docs/semver-node-evidence.md` whenever the toolkit changes, so downstream repos always have a single place to copy/paste from.
