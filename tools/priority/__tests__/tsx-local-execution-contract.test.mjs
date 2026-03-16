import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), 'utf8'));
}

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('tsx local execution policy aligns with package scripts and keeps hosted surfaces compiled', () => {
  const policy = readJson(path.join('tools', 'policy', 'tsx-local-execution.json'));
  const packageJson = readJson('package.json');
  const workflow = readText(path.join('.github', 'workflows', 'agent-review-policy.yml'));

  assert.equal(policy.schema, 'comparevi/tsx-local-execution-policy@v1');
  assert.equal(policy.localRunner, 'tsx');
  assert.equal(packageJson.devDependencies.tsx, '^4.20.6');

  for (const [scriptName, rule] of Object.entries(policy.allowedScripts)) {
    const expectedCommand = [
      'node tools/npm/run-local-typescript.mjs',
      `--project ${rule.project}`,
      `--entry ${rule.entry}`,
      `--fallback-dist ${rule.fallbackDist}`,
      ...(Array.isArray(rule.args) && rule.args.length > 0 ? ['--', ...rule.args] : [])
    ].join(' ');
    assert.equal(packageJson.scripts[scriptName], expectedCommand);
  }

  assert.equal(packageJson.scripts['priority:review:signal'], 'tsc -p tsconfig.json && node dist/tools/priority/copilot-review-signal.js');
  assert.equal(packageJson.scripts['priority:validation:attestation'], 'tsc -p tsconfig.json && node dist/tools/priority/validation-agent-attestation.js');
  assert.equal(packageJson.scripts['priority:github:metadata:apply'], 'tsc -p tsconfig.cli.json && node dist/tools/cli/github-metadata.js');
  const trackedDist = spawnSync(
    'git',
    [
      '-C',
      repoRoot,
      'ls-files',
      '--error-unmatch',
      'dist/tools/cli/github-metadata.js',
      'dist/tools/cli/github-metadata-lib.js'
    ],
    { encoding: 'utf8' }
  );
  assert.equal(trackedDist.status, 0, trackedDist.stderr || trackedDist.stdout);
  assert.doesNotMatch(workflow, /run-local-typescript\.mjs/);
});
