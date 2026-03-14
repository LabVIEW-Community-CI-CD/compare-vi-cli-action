import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('public Linux diagnostics harness schema validates the checked-in contract fixture', async () => {
  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'public-linux-diagnostics-harness-contract-v1.schema.json'),
      'utf8'
    )
  );
  const payload = JSON.parse(
    await readFile(
      path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'diagnostics', 'public-linux-diagnostics-harness-contract.json'),
      'utf8'
    )
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.schema, 'public-linux-diagnostics-harness-contract@v1');
  assert.equal(payload.target.repositoryVisibility, 'public');
  assert.equal(payload.target.developRelationship, 'ahead');
  assert.equal(payload.humanGoNoGo.required, true);
});

test('public Linux diagnostics harness contract doc points to the shared bundle and human decision surfaces', async () => {
  const doc = await readFile(path.join(repoRoot, 'docs', 'PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md'), 'utf8');

  assert.match(doc, /Run-NonLVChecksInDocker\.ps1 -UseToolsImage -NILinuxReviewSuite/);
  assert.match(doc, /public-linux-diagnostics-harness\.yml/);
  assert.match(doc, /DOCKER_TOOLS_PARITY\.md/);
  assert.match(doc, /human-go-no-go-feedback\.yml/);
  assert.match(doc, /human-go-no-go-decision-v1\.schema\.json/);
  assert.match(doc, /public-linux-diagnostics-harness-contract-v1\.schema\.json/);
  assert.match(doc, /public-linux-diagnostics-review-summary-v1\.schema\.json/);
  assert.match(doc, /public-linux-diagnostics-review-summary\.mjs/);
  assert.match(doc, /equal to or ahead of `develop`/i);
});
