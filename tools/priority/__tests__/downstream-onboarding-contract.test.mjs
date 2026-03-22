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
  assert.match(workflow, /push:\s+branches:\s+- develop/);
  assert.match(workflow, /downstream_branch:/);
  assert.match(workflow, /GITHUB_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(workflow, /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(workflow, /consumer_issue_repo:/);
  assert.match(workflow, /DOWNSTREAM_CONSUMER_ISSUE_REPO:/);
  assert.match(workflow, /Resolve pinned template dependency policy/);
  assert.match(workflow, /tools\/policy\/template-dependency\.json/);
  assert.match(workflow, /Resolve immutable upstream source/);
  assert.match(workflow, /git fetch --no-tags origin '\+refs\/heads\/develop:refs\/remotes\/upstream\/develop'/);
  assert.match(workflow, /downstream-onboarding-feedback\.mjs/);
  assert.match(workflow, /args\+=\(--branch "\$branch"\)/);
  assert.match(workflow, /--issue-repo "\$issue_repo"/);
  assert.match(workflow, /downstream-onboarding-report-v1\.schema\.json/);
  assert.match(workflow, /downstream-onboarding-success-v1\.schema\.json/);
  assert.match(workflow, /downstream-onboarding-feedback-v1\.schema\.json/);
  assert.match(workflow, /Refresh template-agent verification report/);
  assert.match(workflow, /priority:template:agent:verify/);
  assert.match(workflow, /Generate downstream promotion manifest/);
  assert.match(workflow, /downstream-promotion-manifest\.mjs/);
  assert.match(workflow, /--source-sha '\$\{\{ steps\.source\.outputs\.source_sha \}\}'/);
  assert.match(workflow, /--comparevi-tools-release 'develop@\$\{\{ steps\.source\.outputs\.source_sha \}\}'/);
  assert.match(workflow, /--comparevi-history-release 'not-evaluated:onboarding-feedback'/);
  assert.match(workflow, /--scenario-pack-id 'downstream-onboarding-feedback@v1'/);
  assert.match(workflow, /--cookiecutter-template-id '\$\{\{ steps\.template-policy\.outputs\.repository \}\}@\$\{\{ steps\.template-policy\.outputs\.ref \}\}'/);
  assert.match(workflow, /downstream-promotion-manifest-v1\.schema\.json/);
  assert.match(workflow, /template-agent-verification-report-v1\.schema\.json/);
  assert.match(workflow, /tests\/results\/_agent\/promotion\/template-agent-verification-report\.json/);
  assert.match(workflow, /Build downstream promotion scorecard/);
  assert.match(workflow, /downstream-promotion-scorecard\.mjs/);
  assert.match(workflow, /--template-agent-verification-report tests\/results\/_agent\/promotion\/template-agent-verification-report\.json/);
  assert.match(workflow, /--manifest-report tests\/results\/_agent\/promotion\/downstream-develop-promotion-manifest\.json/);
  assert.match(workflow, /downstream-promotion-scorecard-v1\.schema\.json/);
  assert.match(workflow, /tests\/results\/_agent\/promotion\/downstream-develop-promotion-scorecard\.json/);
  assert.ok(
    workflow.indexOf('Generate downstream promotion manifest') < workflow.indexOf('Build downstream promotion scorecard')
  );
  assert.match(workflow, /Append onboarding feedback summary/);
  assert.match(workflow, /execution status/);
  assert.match(workflow, /template-agent verification status/);
  assert.match(workflow, /hashFiles\('tests\/results\/_agent\/onboarding\/downstream-onboarding\.json'\)/);
  assert.match(workflow, /hashFiles\('tests\/results\/_agent\/promotion\/downstream-develop-promotion-manifest\.json'\)/);
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
  assert.match(runbook, /--issue-repo LabVIEW-Community-CI-CD\/LabviewGitHubCiTemplate/);
  assert.match(runbook, /consumer_issue_repo/);
  assert.match(runbook, /fails closed/);
  assert.match(runbook, /HOSTED_SIGNAL_REPORT_FIRST_CONTRACT\.md/);
});

test('documentation manifest includes the downstream onboarding runbook', () => {
  const manifest = JSON.parse(read('docs/documentation-manifest.json'));
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md'));
});
