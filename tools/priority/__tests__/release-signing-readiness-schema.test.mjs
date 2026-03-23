import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runReleaseSigningReadiness } from '../release-signing-readiness.mjs';

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
}

function resolveValidatorRepoRoot(repoRoot) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRoot, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRoot;
  }
  const candidates = [
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1843-wake-lifecycle-state-machine')
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json'))
    ) || repoRoot
  );
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRoot);
  execFileSync('node', ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPath), '--data', toGlobPath(dataPath)], {
    cwd: validatorRepoRoot,
    stdio: 'pipe'
  });
}

function writeText(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, 'utf8');
}

test('release signing readiness report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-signing-readiness-schema-'));

  writeText(
    path.join(tmpDir, '.github', 'workflows', 'release-conductor.yml'),
    [
      'name: release-conductor',
      'jobs:',
      '  release:',
      '    steps:',
      '      - name: Configure release tag signing material',
      '        run: |',
      '          echo RELEASE_TAG_SIGNING_PRIVATE_KEY',
      '          git config gpg.format ssh',
      '          git config user.signingkey "$public_key_path"'
    ].join('\n')
  );

  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'release', 'release-signing-readiness.json');
  const { report } = await runReleaseSigningReadiness(
    {
      repoRoot: tmpDir,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      outputPath
    },
    {
      now: new Date('2026-03-23T17:30:00Z'),
      runGhJsonFn: () => ({
        secrets: [{ name: 'RELEASE_TAG_SIGNING_PRIVATE_KEY' }]
      })
    }
  );

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'release-signing-readiness-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/release-signing-readiness-report@v1');
});
