import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'agent-review-policy.yml');

test('agent-review-policy validates existing draft-phase review state from pull_request_target, pull_request_review, and merge_group', () => {
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /merge_group:/);
  assert.doesNotMatch(workflow, /workflow_run:/);
  assert.match(workflow, /pull_request_review:\s+types:\s+\[submitted\]/);
  assert.match(workflow, /permissions:\s+actions: read\s+pull-requests: read\s+contents: read/ms);
  assert.match(workflow, /uses: actions\/checkout@v5/);
  assert.match(workflow, /repository:\s+\$\{\{\s*github\.repository\s*\}\}/);
  assert.match(
    workflow,
    /ref:\s+\$\{\{\s*github\.event\.pull_request\.base\.sha \|\| github\.sha\s*\}\}/
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
  assert.match(workflow, /if: always\(\) && github\.event_name == 'pull_request_target'\s+uses: actions\/upload-artifact@v6/);
  assert.doesNotMatch(workflow, /name: Resolve workflow-run PR context/);
  assert.doesNotMatch(workflow, /name: Load workflow-run pull request metadata/);
  assert.match(
    workflow,
    /name: Evaluate Copilot queue gate\s+if: >[\s\S]*github\.event_name == 'pull_request_target'[\s\S]*github\.event_name == 'pull_request_review'[\s\S]*github\.event_name == 'merge_group'/,
  );
  assert.match(workflow, /delivery-agent\.policy\.json/);
  assert.match(workflow, /"--copilot-review-strategy" "\$review_strategy"/);
  assert.match(workflow, /"--poll-attempts" "60"/);
  assert.match(workflow, /"--poll-delay-ms" "10000"/);
  assert.match(workflow, /if \[\[ "\$\{\{ github\.event_name \}\}" == "merge_group" \]\]; then/);
  assert.match(workflow, /"--head-sha" "\$\{\{ github\.sha \}\}"/);
  assert.match(workflow, /"--head-branch" "\$\{\{ github\.event\.merge_group\.head_ref \|\| github\.ref_name \}\}"/);
  assert.match(workflow, /"--base-ref" "\$\{\{ github\.event\.merge_group\.base_ref \}\}"/);
  assert.doesNotMatch(workflow, /elif \[\[ "\$\{\{ github\.event_name \}\}" == "workflow_run" \]\]; then/);
  assert.doesNotMatch(workflow, /"--review-run-id"/);
  assert.match(workflow, /else\s+args\+=\(\s+"--pr" "\$\{\{ github\.event\.pull_request\.number \}\}"/s);
  assert.match(workflow, /if \[\[ "\$\{\{ github\.event_name \}\}" == "pull_request_target" && -f tests\/results\/_agent\/reviews\/copilot-review-signal\.json \]\]; then/);
  assert.match(workflow, /node "\$\{args\[@\]\}"/);
  assert.doesNotMatch(workflow, /name: Evaluate Copilot queue gate \(merge_group\)/);
  assert.match(workflow, /name: Upload Copilot queue gate artifact\s+if: always\(\)\s+uses: actions\/upload-artifact@v6/);
  assert.doesNotMatch(workflow, /Enforce required reviewer for agent-authored PRs/);
});
