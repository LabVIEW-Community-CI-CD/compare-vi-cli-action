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

test('workflow executes onboarding, success, feedback, and promotion scorecard contracts', () => {
  const workflow = read('.github/workflows/downstream-onboarding-feedback.yml');
  assert.match(workflow, /GITHUB_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(workflow, /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(workflow, /downstream-onboarding-feedback\.mjs/);
  assert.match(workflow, /downstream-onboarding-report-v1\.schema\.json/);
  assert.match(workflow, /downstream-onboarding-success-v1\.schema\.json/);
  assert.match(workflow, /downstream-onboarding-feedback-v1\.schema\.json/);
  assert.match(workflow, /Build downstream promotion scorecard/);
  assert.match(workflow, /downstream-promotion-scorecard\.mjs/);
  assert.match(workflow, /downstream-promotion-scorecard-v1\.schema\.json/);
  assert.match(workflow, /tests\/results\/_agent\/promotion\/downstream-develop-promotion-scorecard\.json/);
  assert.match(workflow, /Append onboarding feedback summary/);
  assert.match(workflow, /execution status/);
  assert.match(workflow, /hashFiles\('tests\/results\/_agent\/onboarding\/downstream-onboarding\.json'\)/);
  assert.match(workflow, /hashFiles\('tests\/results\/_agent\/promotion\/downstream-develop-promotion-scorecard\.json'\)/);
});

test('runbook and package scripts expose downstream onboarding and promotion commands', () => {
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(packageJson.scripts['priority:onboard:downstream'], 'node tools/priority/downstream-onboarding.mjs');
  assert.equal(packageJson.scripts['priority:onboard:feedback'], 'node tools/priority/downstream-onboarding-feedback.mjs');
  assert.equal(packageJson.scripts['priority:onboard:success'], 'node tools/priority/downstream-onboarding-success.mjs');
  assert.equal(packageJson.scripts['priority:promote:downstream:scorecard'], 'node tools/priority/downstream-promotion-scorecard.mjs');

  const runbook = read('docs/DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md');
  assert.match(runbook, /priority:onboard:downstream/);
  assert.match(runbook, /priority:onboard:feedback/);
  assert.match(runbook, /priority:onboard:success/);
  assert.match(runbook, /priority:promote:downstream:scorecard/);
  assert.match(runbook, /downstream-develop-promotion-scorecard\.json/);
  assert.match(runbook, /HOSTED_SIGNAL_REPORT_FIRST_CONTRACT\.md/);
});
