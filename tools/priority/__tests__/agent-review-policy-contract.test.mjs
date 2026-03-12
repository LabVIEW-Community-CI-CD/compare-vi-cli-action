import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'agent-review-policy.yml');

test('agent-review-policy keeps heavyweight collection on pull_request_target and evaluates the queue gate on workflow_run and merge-group events', () => {
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /merge_group:/);
  assert.match(workflow, /workflow_run:\s+workflows:\s+\['Copilot code review'\]\s+types: \[completed\]/);
  assert.doesNotMatch(workflow, /pull_request_review:/);
  assert.match(workflow, /uses: actions\/checkout@v5/);
  assert.match(workflow, /repository:\s+\$\{\{\s*github\.repository\s*\}\}/);
  assert.match(
    workflow,
    /ref:\s+\$\{\{\s*github\.event_name == 'pull_request_target' && github\.event\.pull_request\.base\.sha \|\| github\.event_name == 'workflow_run' && github\.event\.repository\.default_branch \|\| github\.sha\s*\}\}/
  );
  assert.doesNotMatch(workflow, /checkout-workflow-context/);
  assert.doesNotMatch(workflow, /repository:\s+\$\{\{\s*github\.event\.pull_request\.head\.repo\.full_name\s*\}\}/);
  assert.doesNotMatch(workflow, /ref:\s+\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}/);
  assert.match(workflow, /actions\/setup-node@v5/);
  assert.match(workflow, /name: Install Node dependencies\s+if: github\.event_name == 'pull_request_target'\s+run: npm ci --ignore-scripts/);
  assert.match(workflow, /name: Build TypeScript utilities\s+if: github\.event_name == 'pull_request_target'\s+run: node tools\/npm\/run-script\.mjs build/);
  assert.match(workflow, /name: Collect Copilot review signal\s+if: github\.event_name == 'pull_request_target'/);
  assert.match(workflow, /node dist\/tools\/priority\/copilot-review-signal\.js/);
  assert.match(workflow, /name: Validate Copilot review signal schema\s+if: github\.event_name == 'pull_request_target'/);
  assert.match(workflow, /tests\/results\/_agent\/reviews\/copilot-review-signal\.json/);
  assert.match(workflow, /if: always\(\) && github\.event_name == 'pull_request_target'\s+uses: actions\/upload-artifact@v5/);
  assert.match(workflow, /name: Resolve workflow-run PR context\s+if: github\.event_name == 'workflow_run'/);
  assert.match(workflow, /name: Load workflow-run pull request metadata\s+if: github\.event_name == 'workflow_run' && steps\.workflow_run_pr\.outputs\.has_pr == 'true'/);
  assert.match(workflow, /gh api "repos\/\$\{\{ github\.repository \}\}\/pulls\/\$\{\{ steps\.workflow_run_pr\.outputs\.pr \}\}"/);
  assert.match(
    workflow,
    /name: Evaluate Copilot queue gate\s+if: >[\s\S]*github\.event_name == 'pull_request_target'[\s\S]*github\.event_name == 'merge_group'[\s\S]*github\.event_name == 'workflow_run'/,
  );
  assert.match(workflow, /"--poll-attempts" "60"/);
  assert.match(workflow, /"--poll-delay-ms" "10000"/);
  assert.match(workflow, /if \[\[ "\$\{\{ github\.event_name \}\}" == "merge_group" \]\]; then/);
  assert.match(workflow, /"--head-sha" "\$\{\{ github\.sha \}\}"/);
  assert.match(workflow, /"--base-ref" "\$\{\{ github\.event\.merge_group\.base_ref \}\}"/);
  assert.match(workflow, /elif \[\[ "\$\{\{ github\.event_name \}\}" == "workflow_run" \]\]; then/);
  assert.match(workflow, /"--pr" "\$\{\{ steps\.workflow_run_pr\.outputs\.pr \}\}"/);
  assert.match(workflow, /"--head-sha" "\$\{\{ steps\.workflow_run_metadata\.outputs\.head_sha \|\| steps\.workflow_run_pr\.outputs\.head_sha \}\}"/);
  assert.match(workflow, /"--base-ref" "\$\{\{ steps\.workflow_run_metadata\.outputs\.base_ref \}\}"/);
  assert.match(workflow, /"--draft" "\$\{\{ steps\.workflow_run_metadata\.outputs\.draft \}\}"/);
  assert.match(workflow, /"--review-run-id" "\$\{\{ github\.event\.workflow_run\.id \}\}"/);
  assert.match(workflow, /"--review-run-status" "\$\{\{ github\.event\.workflow_run\.status \}\}"/);
  assert.match(workflow, /"--review-run-conclusion" "\$\{\{ github\.event\.workflow_run\.conclusion \}\}"/);
  assert.match(workflow, /"--review-run-url" "\$\{\{ github\.event\.workflow_run\.html_url \}\}"/);
  assert.match(workflow, /"--review-run-workflow-name" "\$\{\{ github\.event\.workflow_run\.name \}\}"/);
  assert.match(workflow, /else\s+args\+=\(\s+"--pr" "\$\{\{ github\.event\.pull_request\.number \}\}"/s);
  assert.match(workflow, /if \[\[ "\$\{\{ github\.event_name \}\}" == "pull_request_target" && -f tests\/results\/_agent\/reviews\/copilot-review-signal\.json \]\]; then/);
  assert.match(workflow, /node "\$\{args\[@\]\}"/);
  assert.doesNotMatch(workflow, /name: Evaluate Copilot queue gate \(merge_group\)/);
  assert.match(workflow, /name: Upload Copilot queue gate artifact\s+if: always\(\)\s+uses: actions\/upload-artifact@v5/);
  assert.doesNotMatch(workflow, /Enforce required reviewer for agent-authored PRs/);
});
