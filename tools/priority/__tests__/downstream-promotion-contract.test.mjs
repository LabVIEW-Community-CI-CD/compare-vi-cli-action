import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('downstream promotion contract locks downstream/develop as a consumer proving rail', () => {
  const policy = JSON.parse(read('tools/policy/downstream-promotion-contract.json'));
  assert.equal(policy.schema, 'priority/downstream-promotion-contract@v1');
  assert.equal(policy.sourceRef, 'upstream/develop');
  assert.equal(policy.targetBranch, 'downstream/develop');
  assert.equal(policy.targetBranchClassId, 'downstream-consumer-proving-rail');
  assert.equal(policy.directDevelopment, 'unsupported');
  assert.ok(policy.requiredInputs.includes('compareviToolsRelease'));
  assert.ok(policy.requiredInputs.includes('cookiecutterTemplateIdentity'));
});

test('package scripts and runbook expose downstream promotion manifest generation', () => {
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(
    packageJson.scripts['priority:promote:downstream:manifest'],
    'node tools/priority/downstream-promotion-manifest.mjs'
  );

  const runbook = read('docs/DOWNSTREAM_DEVELOP_PROMOTION_CONTRACT.md');
  assert.match(runbook, /downstream\/develop/);
  assert.match(runbook, /priority:promote:downstream:manifest/);
  assert.match(runbook, /cookiecutter/i);
  assert.match(runbook, /rollback/i);
  assert.match(runbook, /replay/i);
});
