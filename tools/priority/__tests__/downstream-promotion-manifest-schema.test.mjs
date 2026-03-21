import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runDownstreamPromotionManifest } from '../downstream-promotion-manifest.mjs';

const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('downstream promotion manifest validates its schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'downstream-promotion-manifest-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-schema-'));
  const policyPath = path.join(tmpDir, 'downstream-promotion-contract.json');
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
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.0',
      provingScorecardRef: 'tests/results/_agent/throughput/throughput-scorecard.json',
      actor: 'SergioVelderrain',
      promotionKind: 'replay',
      replayOfManifest: 'tests/results/_agent/promotion/prior.json',
      rollbackOfManifest: null,
      policyPath,
      outputPath: path.join(tmpDir, 'manifest.json'),
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-21T03:25:00.000Z'),
      resolveRepoSlugFn: (value) => value,
      resolveGitRefFn: () => '2e058f794595649c2beeb1b531ca8f5401d1ead5'
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(manifest);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
