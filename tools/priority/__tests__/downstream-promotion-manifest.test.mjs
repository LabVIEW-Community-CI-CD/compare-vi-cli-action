import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  runDownstreamPromotionManifest
} from '../downstream-promotion-manifest.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs enforces immutable input flags for downstream promotion manifests', () => {
  const parsed = parseArgs([
    'node',
    'downstream-promotion-manifest.mjs',
    '--source-sha',
    '2e058f794595649c2beeb1b531ca8f5401d1ead5',
    '--comparevi-tools-release',
    'v0.6.3-tools.14',
    '--comparevi-history-release',
    'v1.3.24',
    '--scenario-pack-id',
    'scenario-pack@v1',
    '--cookiecutter-template-id',
    'LabviewGitHubCiTemplate@v0.1.1',
    '--proving-scorecard-ref',
    'tests/results/_agent/throughput/throughput-scorecard.json',
    '--actor',
    'SergioVelderrain'
  ]);

  assert.equal(parsed.sourceRef, 'upstream/develop');
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(parsed.promotionKind, 'promote');
  assert.equal(parsed.compareviToolsRelease, 'v0.6.3-tools.14');
  assert.equal(parsed.cookiecutterTemplateIdentity, 'LabviewGitHubCiTemplate@v0.1.1');
});

test('parseArgs fails closed when replay and rollback lineage flags do not match promotion kind', () => {
  assert.throws(
    () =>
      parseArgs([
        'node',
        'downstream-promotion-manifest.mjs',
        '--source-sha',
        '2e058f794595649c2beeb1b531ca8f5401d1ead5',
        '--comparevi-tools-release',
        'v0.6.3-tools.14',
        '--comparevi-history-release',
        'v1.3.24',
        '--scenario-pack-id',
        'scenario-pack@v1',
        '--cookiecutter-template-id',
        'LabviewGitHubCiTemplate@v0.1.1',
        '--proving-scorecard-ref',
        'tests/results/_agent/throughput/throughput-scorecard.json',
        '--actor',
        'SergioVelderrain',
        '--replay-of-manifest',
        'prev.json'
      ]),
    /requires --promotion-kind replay/
  );
});

test('runDownstreamPromotionManifest writes a deterministic immutable manifest', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-manifest-'));
  const policyPath = path.join(tmpDir, 'downstream-promotion-contract.json');
  const outputPath = path.join(tmpDir, 'manifest.json');
  writeJson(policyPath, {
    schema: 'priority/downstream-promotion-contract@v1',
    sourceRef: 'upstream/develop',
    targetBranch: 'downstream/develop',
    targetBranchClassId: 'downstream-consumer-proving-rail'
  });

  const { manifest } = await runDownstreamPromotionManifest(
    {
      sourceRef: 'upstream/develop',
      sourceSha: '2e058f794595649c2beeb1b531ca8f5401d1ead5',
      compareviToolsRelease: 'v0.6.3-tools.14',
      compareviHistoryRelease: 'v1.3.24',
      scenarioPackIdentity: 'scenario-pack@v1',
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1',
      provingScorecardRef: 'tests/results/_agent/throughput/throughput-scorecard.json',
      actor: 'SergioVelderrain',
      promotionKind: 'promote',
      replayOfManifest: null,
      rollbackOfManifest: null,
      policyPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-21T03:20:00.000Z'),
      resolveRepoSlugFn: (value) => value,
      resolveGitRefFn: () => '2e058f794595649c2beeb1b531ca8f5401d1ead5'
    }
  );

  assert.equal(manifest.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(manifest.promotion.sourceRef, 'upstream/develop');
  assert.equal(manifest.promotion.targetBranch, 'downstream/develop');
  assert.equal(manifest.inputs.compareviHistoryRelease, 'v1.3.24');
  assert.equal(manifest.lineage.promotionKind, 'promote');
  assert.equal(manifest.promotion.localSourceVerification.matched, true);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runDownstreamPromotionManifest fails closed when local upstream/develop does not match the requested source sha', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-manifest-mismatch-'));
  const policyPath = path.join(tmpDir, 'downstream-promotion-contract.json');
  writeJson(policyPath, {
    schema: 'priority/downstream-promotion-contract@v1',
    sourceRef: 'upstream/develop',
    targetBranch: 'downstream/develop',
    targetBranchClassId: 'downstream-consumer-proving-rail'
  });

  await assert.rejects(
    () =>
      runDownstreamPromotionManifest(
        {
          sourceRef: 'upstream/develop',
          sourceSha: '2e058f794595649c2beeb1b531ca8f5401d1ead5',
          compareviToolsRelease: 'v0.6.3-tools.14',
          compareviHistoryRelease: 'v1.3.24',
          scenarioPackIdentity: 'scenario-pack@v1',
          cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1',
          provingScorecardRef: 'tests/results/_agent/throughput/throughput-scorecard.json',
          actor: 'SergioVelderrain',
          promotionKind: 'promote',
          replayOfManifest: null,
          rollbackOfManifest: null,
          policyPath,
          outputPath: path.join(tmpDir, 'manifest.json'),
          repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        },
        {
          resolveRepoSlugFn: (value) => value,
          resolveGitRefFn: () => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
      ),
    /resolved to aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/
  );
});
