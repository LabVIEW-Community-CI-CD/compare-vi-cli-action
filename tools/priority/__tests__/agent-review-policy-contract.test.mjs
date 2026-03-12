import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'agent-review-policy.yml');

test('agent-review-policy keeps heavyweight collection on pull_request_target and evaluates the queue gate on PR review and merge-group events', () => {
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /merge_group:/);
  assert.match(workflow, /pull_request_review:\s+types: \[submitted\]/);
  assert.match(workflow, /uses: actions\/checkout@v5/);
  assert.match(
    workflow,
    /uses: actions\/checkout@v5\s+with:\s+ref: \$\{\{ github\.event_name == 'pull_request_review' && github\.event\.pull_request\.base\.sha \|\| github\.sha \}\}/,
  );
  assert.match(workflow, /actions\/setup-node@v5\s+if: github\.event_name != 'merge_group'/);
  assert.match(workflow, /name: Install Node dependencies\s+if: github\.event_name == 'pull_request_target'\s+run: npm ci --ignore-scripts/);
  assert.match(workflow, /name: Build TypeScript utilities\s+if: github\.event_name == 'pull_request_target'\s+run: node tools\/npm\/run-script\.mjs build/);
  assert.match(workflow, /name: Collect Copilot review signal\s+if: github\.event_name == 'pull_request_target'/);
  assert.match(workflow, /node dist\/tools\/priority\/copilot-review-signal\.js/);
  assert.match(workflow, /name: Validate Copilot review signal schema\s+if: github\.event_name == 'pull_request_target'/);
  assert.match(workflow, /tests\/results\/_agent\/reviews\/copilot-review-signal\.json/);
  assert.match(workflow, /if: always\(\) && github\.event_name == 'pull_request_target'\s+uses: actions\/upload-artifact@v5/);
  assert.match(
    workflow,
    /name: Evaluate Copilot queue gate\s+if: always\(\) && \(github\.event_name == 'pull_request_target' \|\| github\.event_name == 'pull_request_review'\)/,
  );
  assert.match(workflow, /"--poll-attempts" "18"/);
  assert.match(workflow, /"--poll-delay-ms" "10000"/);
  assert.match(workflow, /node "\$\{args\[@\]\}"/);
  assert.match(workflow, /name: Evaluate Copilot queue gate \(merge_group\)\s+if: always\(\) && github\.event_name == 'merge_group'/);
  assert.match(workflow, /node tools\/priority\/copilot-review-gate\.mjs/);
  assert.match(workflow, /name: Upload Copilot queue gate artifact\s+if: always\(\)\s+uses: actions\/upload-artifact@v5/);
  assert.doesNotMatch(workflow, /Enforce required reviewer for agent-authored PRs/);
});
