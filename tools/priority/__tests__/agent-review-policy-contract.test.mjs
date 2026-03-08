import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'agent-review-policy.yml');

test('agent-review-policy emits and validates the Copilot review signal artifact', () => {
  const workflow = readFileSync(workflowPath, 'utf8');

  assert.match(workflow, /actions\/checkout@v5/);
  assert.match(workflow, /actions\/setup-node@v5/);
  assert.match(workflow, /npm ci --ignore-scripts/);
  assert.match(workflow, /node tools\/npm\/run-script\.mjs build/);
  assert.match(workflow, /node dist\/tools\/priority\/copilot-review-signal\.js/);
  assert.match(workflow, /schema:copilot-review-signal:validate/);
  assert.match(workflow, /tests\/results\/_agent\/reviews\/copilot-review-signal\.json/);
  assert.match(workflow, /actions\/upload-artifact@v5/);
});
