import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');

function readRepoFile(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('bootstrap routes standing-priority helper scripts through the resolved helper root', () => {
  const content = readRepoFile(path.join('tools', 'priority', 'bootstrap.ps1'));
  assert.match(content, /Resolve-PriorityHelperRepoRoot/);
  assert.match(content, /function Ensure-RepoNodeDependencies/);
  assert.match(content, /function Invoke-NodeScriptFromRepoRoot/);
  assert.match(content, /function Test-SemVerRepoRootOverrideSupport/);
  assert.match(
    content,
    /Invoke-NodeScriptFromRepoRoot[\s\S]*-ScriptRelativePath 'tools\/priority\/sync-standing-priority\.mjs'[\s\S]*-RequiredPackages @\('undici'\)[\s\S]*--fail-on-missing[\s\S]*--auto-select-next/
  );
  assert.match(
    content,
    /\$reconcileArgs = @\('--issue', \[string\]\$routerIssue\)[\s\S]*Invoke-NodeScriptFromRepoRoot[\s\S]*-ScriptRelativePath 'tools\/priority\/reconcile-standing-after-merge\.mjs'[\s\S]*-RequiredPackages @\('undici'\)[\s\S]*-Arguments \$reconcileArgs/
  );
  assert.match(
    content,
    /Invoke-NodeScriptFromRepoRoot[\s\S]*-ScriptRelativePath 'tools\/priority\/project-session-index-v2-promotion-decision\.mjs'[\s\S]*-RequiredPackages @\('ajv', 'ajv-formats'\)[\s\S]*-AllowFailure:\$true/
  );
  assert.match(
    content,
    /\$semverOutcome = Invoke-SemVerCheck -RepoRoot \$priorityHelperRepoRoot -WorkingDirectory \$priorityWorkingDirectory/
  );
  assert.match(
    content,
    /\$selectedScriptSupportsRepoRoot = Test-SemVerRepoRootOverrideSupport[\s\S]*-ScriptPath \$selectedScriptPath[\s\S]*-WorkingDirectory \$resolvedWorkingDirectory[\s\S]*-NodeCommand \$nodeCmd\.Source[\s\S]*\$psi\.ArgumentList\.Add\('--repo-root'\)[\s\S]*\$psi\.ArgumentList\.Add\(\$resolvedWorkingDirectory\)/
  );
  assert.match(
    content,
    /foreach \(\$arg in @\(\$resolvedScriptPath, '--version', '0\.0\.0', '--repo-root', \$resolvedWorkingDirectory\)\)/
  );
  assert.match(
    content,
    /SemVer helper checkout script is unavailable; using caller checkout script\./
  );
  assert.match(
    content,
    /SemVer helper checkout lacks explicit repo-root support; using caller checkout script until develop helper catches up\./
  );
  assert.match(
    content,
    /Safe-git helper checkout script is unavailable; using caller checkout script\./
  );
  assert.match(
    content,
    /Invoke-SafeGitReliabilitySummary -RepoRoot \$priorityHelperRepoRoot -WorkingDirectory \$priorityWorkingDirectory/
  );
  assert.match(content, /\$routerPath = Join-Path \$priorityWorkingDirectory 'tests\/results\/_agent\/issue\/router\.json'/);
});
