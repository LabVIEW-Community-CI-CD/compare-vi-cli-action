import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('downstream onboarding policy defines required checklist seams', () => {
  const policy = JSON.parse(read('tools/policy/downstream-onboarding-checklist.json'));
  assert.equal(policy.schema, 'priority/downstream-onboarding-policy@v1');
  const checklistIds = policy.checklist.map((entry) => entry.id);
  assert.ok(checklistIds.includes('workflow-reference-present'));
  assert.ok(checklistIds.includes('certified-reference-pinned'));
  assert.ok(checklistIds.includes('successful-consumption-run'));
});

test('workflow executes onboarding + success scripts with schema validation', () => {
  const workflow = read('.github/workflows/downstream-onboarding-feedback.yml');
  assert.match(workflow, /downstream-onboarding\.mjs/);
  assert.match(workflow, /downstream-onboarding-success\.mjs/);
  assert.match(workflow, /downstream-onboarding-report-v1\.schema\.json/);
  assert.match(workflow, /downstream-onboarding-success-v1\.schema\.json/);
});

test('runbook and package scripts expose downstream onboarding commands', () => {
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(packageJson.scripts['priority:onboard:downstream'], 'node tools/priority/downstream-onboarding.mjs');
  assert.equal(packageJson.scripts['priority:onboard:success'], 'node tools/priority/downstream-onboarding-success.mjs');

  const runbook = read('docs/DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md');
  assert.match(runbook, /priority:onboard:downstream/);
  assert.match(runbook, /priority:onboard:success/);
});
