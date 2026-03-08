import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function readYaml(relativePath) {
  return yaml.load(readText(relativePath));
}

test('github intake layer ships the expected PR template variants', () => {
  const defaultTemplate = readText('.github/pull_request_template.md');
  const agentTemplate = readText('.github/PULL_REQUEST_TEMPLATE/agent-maintenance.md');
  const workflowTemplate = readText('.github/PULL_REQUEST_TEMPLATE/workflow-policy.md');
  const humanTemplate = readText('.github/PULL_REQUEST_TEMPLATE/human-change.md');

  assert.match(defaultTemplate, /## Agent Metadata/);
  assert.match(defaultTemplate, /## Validation Evidence/);
  assert.match(agentTemplate, /## Queue and Follow-up/);
  assert.match(workflowTemplate, /## Workflow and Policy Impact/);
  assert.match(workflowTemplate, /## Rollout and Rollback/);
  assert.doesNotMatch(humanTemplate, /## Agent Metadata/);
  assert.match(humanTemplate, /## Testing and Evidence/);
});

test('github intake layer issue forms are structured and blank issues are disabled', () => {
  const bugForm = readYaml('.github/ISSUE_TEMPLATE/01-bug-report.yml');
  const featureForm = readYaml('.github/ISSUE_TEMPLATE/02-feature-program-intake.yml');
  const workflowForm = readYaml('.github/ISSUE_TEMPLATE/03-workflow-policy-agent-ux.yml');
  const investigationForm = readYaml('.github/ISSUE_TEMPLATE/04-investigation-anomaly.yml');
  const config = readYaml('.github/ISSUE_TEMPLATE/config.yml');

  assert.equal(bugForm.name, 'Bug report');
  assert.equal(featureForm.name, 'Feature or program intake');
  assert.equal(workflowForm.name, 'Workflow, policy, or agent UX request');
  assert.equal(investigationForm.name, 'Investigation or anomaly');
  assert.equal(config.blank_issues_enabled, false);
  assert.ok(Array.isArray(config.contact_links));
  assert.ok(config.contact_links.some((link) => String(link.url).includes('GitHub-Intake-Layer.md')));

  const featureIds = featureForm.body.filter((item) => item.id).map((item) => item.id);
  assert.ok(featureIds.includes('problem'));
  assert.ok(featureIds.includes('acceptance'));

  const workflowIds = workflowForm.body.filter((item) => item.id).map((item) => item.id);
  assert.ok(workflowIds.includes('affected_contracts'));
  assert.ok(workflowIds.includes('validation'));
});

test('github intake docs and manifest reference the new helper layer', () => {
  const snippets = readText('.github/PR_COMMENT_SNIPPETS.md');
  const agents = readText('AGENTS.md');
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const intakeGuide = readText('docs/knowledgebase/GitHub-Intake-Layer.md');
  const orchestrator = readText('tools/Branch-Orchestrator.ps1');
  const intakeModule = readText('tools/GitHubIntake.psm1');
  const oneButtonValidate = readText('tools/Run-OneButtonValidate.ps1');

  assert.match(snippets, /New-IssueBody\.ps1/);
  assert.match(snippets, /Branch-Orchestrator\.ps1/);
  assert.match(agents, /New-IssueBody\.ps1/);
  assert.match(agents, /-PRTemplate workflow-policy\|human-change/);
  assert.match(intakeGuide, /New-PullRequestBody\.ps1/);
  assert.match(intakeGuide, /gh pr create --title "<title>" --body-file pr-body\.md/);
  assert.match(orchestrator, /Import-Module \(Join-Path \$PSScriptRoot 'GitHubIntake\.psm1'\)/);
  assert.match(orchestrator, /'pr'\s+'create'\s+'--title'/);
  assert.match(orchestrator, /'pr'\s+'view'\s+\$branchName\s+'--json'\s+'number'/);
  assert.doesNotMatch(orchestrator, /'pr'\s+'create'\s+'--fill(?:-first)?'/);
  assert.doesNotMatch(orchestrator, /'pr'\s+'view'\s+'--json'\s+'number'\s+'--head'/);
  assert.match(oneButtonValidate, /gh pr view \$branch --json number/);
  assert.doesNotMatch(oneButtonValidate, /gh pr view --json number --head/);
  assert.match(intakeModule, /function Resolve-IssueBranchName/);
  assert.match(intakeModule, /function Resolve-PullRequestTitle/);

  const templateEntry = manifest.entries.find((entry) => entry.name === 'GitHub Templates');
  assert.ok(templateEntry);
  assert.ok(templateEntry.files.includes('.github/ISSUE_TEMPLATE/01-bug-report.yml'));
  assert.ok(templateEntry.files.includes('.github/PULL_REQUEST_TEMPLATE/workflow-policy.md'));

  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/GitHub-Intake-Layer.md'));
});
