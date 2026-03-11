import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import {
  resolveJsPackageReleaseContext,
  stageJsPackageRelease,
  verifyJsPackageRelease
} from '../js-package-release.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

async function loadSchema() {
  return JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'js-package-release-v1.schema.json'), 'utf8')
  );
}

test('JS package release schema validates resolve/stage/verify artifacts', async () => {
  const schema = await loadSchema();
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-harness-schema-'));
  const common = {
    packageDir: 'packages/runtime-harness',
    version: '0.1.0-rc.1',
    channel: 'rc',
    publish: false,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    owner: 'LabVIEW-Community-CI-CD',
    serverUrl: 'https://github.com'
  };

  const resolveReport = await resolveJsPackageReleaseContext(common, {
    repoRoot,
    now: new Date('2026-03-10T08:15:00Z')
  });
  const stageReport = await stageJsPackageRelease(
    {
      ...common,
      stagingDir: path.join(tempRoot, 'staging'),
      tarballDir: path.join(tempRoot, 'tarballs'),
      copyLicenseFrom: 'LICENSE'
    },
    { repoRoot, now: new Date('2026-03-10T08:16:00Z') }
  );
  const verifyReport = await verifyJsPackageRelease(
    {
      ...common,
      sourceSpec: stageReport.outputs.tarballPath,
      consumerDir: path.join(tempRoot, 'consumer')
    },
    { repoRoot, now: new Date('2026-03-10T08:18:00Z') }
  );

  assert.equal(validate(resolveReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(validate(stageReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(validate(verifyReport), true, JSON.stringify(validate.errors, null, 2));
});
