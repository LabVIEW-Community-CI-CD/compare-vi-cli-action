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
  assert.equal(policy.artifacts.manifestSchema, 'docs/schemas/downstream-promotion-manifest-v1.schema.json');
  assert.equal(policy.artifacts.provingScorecardSchema, 'docs/schemas/downstream-promotion-scorecard-v1.schema.json');
  assert.equal(policy.artifacts.provingScorecardDefaultPath, 'tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json');
});

test('package scripts and runbook expose downstream promotion manifest and scorecard generation', () => {
  const packageJson = JSON.parse(read('package.json'));
  assert.equal(
    packageJson.scripts['priority:promote:downstream:manifest'],
    'node tools/priority/downstream-promotion-manifest.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:promote:downstream:scorecard'],
    'node tools/priority/downstream-promotion-scorecard.mjs'
  );

  const runbook = read('docs/DOWNSTREAM_DEVELOP_PROMOTION_CONTRACT.md');
  assert.match(runbook, /downstream\/develop/);
  assert.match(runbook, /priority:promote:downstream:manifest/);
  assert.match(runbook, /priority:promote:downstream:scorecard/);
  assert.match(runbook, /cookiecutter/i);
  assert.match(runbook, /rollback/i);
  assert.match(runbook, /replay/i);
  assert.match(runbook, /downstream-develop-promotion-scorecard\.json/);
  assert.match(runbook, /Release consumption/);
  assert.match(runbook, /downstream-promotion\.yml/);
});

test('downstream promotion workflow turns the proving rail into checked-in automation', () => {
  const workflow = read('.github/workflows/downstream-promotion.yml');
  assert.match(workflow, /^name: Downstream Promotion$/m);
  assert.match(workflow, /^\s{2}downstream-promotion:\s*$/m);
  assert.match(workflow, /^\s{4}name:\s*Downstream Promotion \/ downstream-promotion\s*$/m);
  assert.match(workflow, /source_sha:/);
  assert.match(workflow, /comparevi_tools_release:/);
  assert.match(workflow, /comparevi_history_release:/);
  assert.match(workflow, /scenario_pack_id:/);
  assert.match(workflow, /cookiecutter_template_id:/);
  assert.match(workflow, /Run downstream onboarding feedback harness/);
  assert.match(workflow, /downstream-onboarding-feedback\.mjs/);
  assert.match(workflow, /Generate downstream promotion manifest/);
  assert.match(workflow, /downstream-promotion-manifest\.mjs/);
  assert.match(workflow, /Build downstream promotion scorecard/);
  assert.match(workflow, /downstream-promotion-scorecard\.mjs/);
  assert.match(workflow, /Upload downstream promotion artifacts/);
  assert.match(workflow, /name:\s*downstream-promotion-\$\{\{\s*github\.run_id\s*\}\}/);
  assert.match(workflow, /git push origin '\$\{\{ steps\.source\.outputs\.source_sha \}\}:refs\/heads\/downstream\/develop'/);
});

test('branch required checks and priority policy recognize downstream/develop as a first-class proving rail', () => {
  const branchPolicy = JSON.parse(read('tools/policy/branch-required-checks.json'));
  assert.equal(branchPolicy.branchClassBindings['downstream/develop'], 'downstream-consumer-proving-rail');
  assert.deepEqual(branchPolicy.branchClassRequiredChecks['downstream-consumer-proving-rail'], [
    'Downstream Promotion / downstream-promotion'
  ]);
  assert.deepEqual(branchPolicy.branches['downstream/develop'], ['Downstream Promotion / downstream-promotion']);

  const priorityPolicy = JSON.parse(read('tools/priority/policy.json'));
  assert.equal(priorityPolicy.branches['downstream/develop'].branch_class_id, 'downstream-consumer-proving-rail');
  assert.deepEqual(priorityPolicy.branches['downstream/develop'].required_status_checks, [
    'Downstream Promotion / downstream-promotion'
  ]);
  assert.equal(priorityPolicy.rulesets['downstream-develop'].branch_class_id, 'downstream-consumer-proving-rail');
  assert.deepEqual(priorityPolicy.rulesets['downstream-develop'].includes, ['refs/heads/downstream/develop']);
  assert.deepEqual(priorityPolicy.rulesets['downstream-develop'].required_status_checks, [
    'Downstream Promotion / downstream-promotion'
  ]);
});
