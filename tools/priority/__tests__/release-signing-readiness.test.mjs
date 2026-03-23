import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH,
  parseArgs,
  REQUIRED_SIGNING_SECRET,
  OPTIONAL_SIGNING_SECRET,
  runReleaseSigningReadiness
} from '../release-signing-readiness.mjs';

function writeText(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, 'utf8');
}

function writeJson(filePath, payload) {
  writeText(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

function seedWorkflowContract(repoRoot) {
  writeText(
    path.join(repoRoot, '.github', 'workflows', 'release-conductor.yml'),
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
}

test('parseArgs keeps defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'release-signing-readiness.mjs',
    '--repo-root',
    'C:/repo',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--output',
    'custom/release-signing-readiness.json'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.outputPath, 'custom/release-signing-readiness.json');
  assert.equal(
    DEFAULT_OUTPUT_PATH,
    path.join('tests', 'results', '_agent', 'release', 'release-signing-readiness.json')
  );
  assert.equal(
    DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH,
    path.join('tests', 'results', '_agent', 'release', 'release-conductor-report.json')
  );
});

test('runReleaseSigningReadiness reports explicit external blocker when workflow secret is missing', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'release-signing-readiness-missing-'));
  seedWorkflowContract(repoRoot);

  const result = await runReleaseSigningReadiness(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T17:20:00Z'),
      runGhJsonFn: () => ({
        secrets: [{ name: 'GH_TOKEN' }]
      })
    }
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.codePathState, 'ready');
  assert.equal(result.report.summary.signingCapabilityState, 'missing');
  assert.equal(result.report.summary.publicationState, 'unobserved');
  assert.equal(result.report.summary.externalBlocker, 'workflow-signing-secret-missing');
  assert.equal(result.report.secretInventory.requiredSecretPresent, false);
  assert.deepEqual(result.report.blockers.map((entry) => entry.code), ['workflow-signing-secret-missing']);
});

test('runReleaseSigningReadiness reports publication success when signing capability is configured', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'release-signing-readiness-pass-'));
  seedWorkflowContract(repoRoot);
  writeJson(path.join(repoRoot, DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH), {
    release: {
      tagCreated: true,
      tagPushed: true,
      targetTag: 'v0.6.4-rc.1'
    }
  });

  const result = await runReleaseSigningReadiness(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T17:21:00Z'),
      runGhJsonFn: () => ({
        secrets: [{ name: REQUIRED_SIGNING_SECRET }, { name: OPTIONAL_SIGNING_SECRET }]
      })
    }
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.codePathState, 'ready');
  assert.equal(result.report.summary.signingCapabilityState, 'configured');
  assert.equal(result.report.summary.publicationState, 'authoritative-publication-successful');
  assert.equal(result.report.summary.externalBlocker, null);
  assert.equal(result.report.secretInventory.requiredSecretPresent, true);
  assert.equal(result.report.publication.targetTag, 'v0.6.4-rc.1');
  assert.deepEqual(result.report.blockers, []);
});
