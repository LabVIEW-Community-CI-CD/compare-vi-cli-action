import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function readYaml(relativePath) {
  return yaml.load(readText(relativePath));
}

function readJson(relativePath) {
  return JSON.parse(readText(relativePath));
}

function assertSchemaValid(schemaRelativePath, dataRelativePath) {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(readJson(schemaRelativePath));
  const data = readJson(dataRelativePath);
  const valid = validate(data);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
}

test('github intake catalog matches schema and routes the supported scenarios', () => {
  const catalog = readJson('tools/priority/github-intake-catalog.json');

  assertSchemaValid('docs/schemas/github-intake-catalog-v1.schema.json', 'tools/priority/github-intake-catalog.json');
  assert.equal(catalog.schema, 'github-intake/catalog@v1');
  assert.deepEqual(
    catalog.issueTemplates.map((entry) => entry.key),
    ['bug-report', 'feature-program', 'workflow-policy-agent-ux', 'investigation-anomaly']
  );
  assert.deepEqual(
    catalog.pullRequestTemplates.map((entry) => entry.key),
    ['default', 'agent-maintenance', 'workflow-policy', 'human-change']
  );
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'bug' && entry.targetKey === 'bug-report'));
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'workflow-policy' && entry.targetKey === 'workflow-policy-agent-ux'));
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'automation-pr' && entry.targetKey === 'default'));
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'human-pr' && entry.targetKey === 'human-change'));
  assert.ok(catalog.routes.every((entry) => String(entry.helperPath).includes('New-GitHubIntakeDraft.ps1')));
  assert.ok(catalog.routes.every((entry) => typeof entry.executeCommand === 'string' && entry.executeCommand.length > 0));
  assert.ok(catalog.routes.every((entry) => entry.execution && typeof entry.execution.kind === 'string' && entry.execution.kind.length > 0));
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'workflow-policy-pr' && entry.execution.kind === 'branch-orchestrator'));
  assert.ok(catalog.routes.some((entry) => entry.scenario === 'human-pr' && entry.execution.kind === 'gh-pr-create'));
});

test('github intake layer ships the expected PR template variants', () => {
  const catalog = readJson('tools/priority/github-intake-catalog.json');
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
  for (const entry of catalog.pullRequestTemplates) {
    assert.ok(existsSync(path.join(repoRoot, entry.path)), `missing PR template path ${entry.path}`);
  }
});

test('github intake layer issue forms are structured and blank issues are disabled', () => {
  const catalog = readJson('tools/priority/github-intake-catalog.json');
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
  assert.ok(config.contact_links.some((link) => String(link.url).includes('/wiki')));
  assert.deepEqual(
    catalog.contactLinks.map((entry) => ({ name: entry.name, url: entry.url, about: entry.about })),
    config.contact_links.map((entry) => ({ name: entry.name, url: entry.url, about: entry.about }))
  );

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
  const readme = readText('README.md');
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const pkg = readJson('package.json');
  const intakeGuide = readText('docs/knowledgebase/GitHub-Intake-Layer.md');
  const automationGuide = readText('docs/knowledgebase/GitHub-Wiki-Portal-Automation-Evaluation.md');
  const wikiGuide = readText('docs/knowledgebase/GitHub-Wiki-Portal.md');
  const orchestrator = readText('tools/Branch-Orchestrator.ps1');
  const getStandingPriority = readText('tools/Get-StandingPriority.ps1');
  const intakeModule = readText('tools/GitHubIntake.psm1');
  const intakeResolver = readText('tools/Resolve-GitHubIntakeRoute.ps1');
  const intakeDraft = readText('tools/New-GitHubIntakeDraft.ps1');
  const intakeAtlas = readText('tools/Write-GitHubIntakeAtlas.ps1');
  const intakeInvoke = readText('tools/Invoke-GitHubIntakeScenario.ps1');
  const oneButtonValidate = readText('tools/Run-OneButtonValidate.ps1');

  assert.match(snippets, /New-IssueBody\.ps1/);
  assert.match(snippets, /New-GitHubIntakeDraft\.ps1/);
  assert.match(snippets, /Invoke-GitHubIntakeScenario\.ps1/);
  assert.match(snippets, /Write-GitHubIntakeAtlas\.ps1/);
  assert.match(snippets, /Resolve-GitHubIntakeRoute\.ps1/);
  assert.match(snippets, /Branch-Orchestrator\.ps1/);
  assert.match(agents, /New-IssueBody\.ps1/);
  assert.match(agents, /New-GitHubIntakeDraft\.ps1/);
  assert.match(agents, /Invoke-GitHubIntakeScenario\.ps1/);
  assert.match(agents, /Write-GitHubIntakeAtlas\.ps1/);
  assert.match(agents, /Resolve-GitHubIntakeRoute\.ps1/);
  assert.match(agents, /GitHub wiki as a curated portal only/);
  assert.match(agents, /queue-empty/);
  assert.match(readme, /compare-vi-cli-action\/wiki/);
  assert.match(agents, /-PRTemplate workflow-policy\|human-change/);
  assert.match(intakeGuide, /New-GitHubIntakeDraft\.ps1/);
  assert.match(intakeGuide, /Invoke-GitHubIntakeScenario\.ps1/);
  assert.match(intakeGuide, /Write-GitHubIntakeAtlas\.ps1/);
  assert.match(intakeGuide, /github-intake-catalog\.json/);
  assert.match(intakeGuide, /default dry-run execution plan/i);
  assert.match(intakeGuide, /issue snapshot/i);
  assert.match(intakeGuide, /Resolve-GitHubIntakeRoute\.ps1/);
  assert.match(intakeGuide, /New-PullRequestBody\.ps1/);
  assert.match(intakeGuide, /GitHub-Wiki-Portal\.md/);
  assert.match(intakeGuide, /Idle Repository Mode/);
  assert.match(intakeGuide, /reason = queue-empty/);
  assert.match(intakeGuide, /gh pr create --title "<title>" --body-file pr-body\.md/);
  assert.match(automationGuide, /Keep manual curation for now/);
  assert.match(automationGuide, /compare-vi-cli-action\.wiki\.git/);
  assert.match(wikiGuide, /Authoritative repo docs/);
  assert.match(wikiGuide, /GitHub-Wiki-Portal-Automation-Evaluation\.md/);
  assert.match(wikiGuide, /README\.md/);
  assert.match(orchestrator, /Import-Module \(Join-Path \$PSScriptRoot 'GitHubIntake\.psm1'\)/);
  assert.match(orchestrator, /'pr'\s+'create'\s+'--title'/);
  assert.match(orchestrator, /'pr'\s+'view'\s+\$branchName\s+'--json'\s+'number'/);
  assert.match(orchestrator, /'pr'\s+'edit'\s+\$pr\.number\s+'--title'\s+\$prTitle\s+'--body-file'/);
  assert.match(orchestrator, /Standing-priority queue is empty/);
  assert.match(orchestrator, /router\.json/);
  assert.match(orchestrator, /no-standing-priority\.json/);
  assert.match(getStandingPriority, /Standing priority not set \(queue empty\)/);
  assert.doesNotMatch(orchestrator, /'pr'\s+'create'\s+'--fill(?:-first)?'/);
  assert.doesNotMatch(orchestrator, /'pr'\s+'view'\s+'--json'\s+'number'\s+'--head'/);
  assert.match(oneButtonValidate, /gh pr view \$branch --json number/);
  assert.doesNotMatch(oneButtonValidate, /gh pr view --json number --head/);
  assert.match(intakeModule, /function Get-GitHubIntakeCatalog/);
  assert.match(intakeModule, /function Resolve-GitHubIntakeDraftContext/);
  assert.match(intakeModule, /function Resolve-GitHubIssueSnapshot/);
  assert.match(intakeModule, /function Resolve-GitHubIntakeRoute/);
  assert.match(intakeModule, /function New-GitHubIntakeExecutionPlan/);
  assert.match(intakeModule, /function Invoke-GitHubIntakeExecutionPlan/);
  assert.match(intakeModule, /function Resolve-IssueBranchName/);
  assert.match(intakeModule, /function Resolve-PullRequestTitle/);
  assert.match(intakeResolver, /-ListScenarios/);
  assert.match(intakeDraft, /Resolve-GitHubIntakeDraftContext/);
  assert.match(intakeDraft, /New-PullRequestBody\.ps1/);
  assert.match(intakeInvoke, /New-GitHubIntakeExecutionPlan/);
  assert.match(intakeInvoke, /Invoke-GitHubIntakeExecutionPlan/);
  assert.match(intakeModule, /function New-GitHubIntakeAtlasReport/);
  assert.match(intakeModule, /function ConvertTo-GitHubIntakeAtlasMarkdown/);
  assert.match(intakeAtlas, /New-GitHubIntakeAtlasReport/);
  assert.match(intakeAtlas, /ConvertTo-GitHubIntakeAtlasMarkdown/);
  assert.equal(pkg.scripts['intake:invoke'], 'pwsh -NoLogo -NoProfile -File tools/Invoke-GitHubIntakeScenario.ps1');

  const templateEntry = manifest.entries.find((entry) => entry.name === 'GitHub Templates');
  assert.ok(templateEntry);
  assert.ok(templateEntry.files.includes('.github/ISSUE_TEMPLATE/01-bug-report.yml'));
  assert.ok(templateEntry.files.includes('.github/PULL_REQUEST_TEMPLATE/workflow-policy.md'));

  const intakeEntry = manifest.entries.find((entry) => entry.name === 'GitHub Intake Contracts');
  assert.ok(intakeEntry);
  assert.ok(intakeEntry.files.includes('tools/priority/github-intake-catalog.json'));
  assert.ok(intakeEntry.files.includes('docs/schemas/github-intake-atlas-v1.schema.json'));
  assert.ok(intakeEntry.files.includes('docs/schemas/github-intake-catalog-v1.schema.json'));
  assert.ok(intakeEntry.files.includes('docs/schemas/github-intake-execution-plan-v1.schema.json'));
  assert.ok(intakeEntry.files.includes('tools/New-GitHubIntakeDraft.ps1'));
  assert.ok(intakeEntry.files.includes('tools/Invoke-GitHubIntakeScenario.ps1'));
  assert.ok(intakeEntry.files.includes('tools/Resolve-GitHubIntakeRoute.ps1'));
  assert.ok(intakeEntry.files.includes('tools/Write-GitHubIntakeAtlas.ps1'));

  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/GitHub-Intake-Layer.md'));
  assert.ok(docsEntry.files.includes('docs/knowledgebase/GitHub-Wiki-Portal-Automation-Evaluation.md'));
  assert.ok(docsEntry.files.includes('docs/knowledgebase/GitHub-Wiki-Portal.md'));
});
