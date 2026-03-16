import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'release-cadence-check.yml');

test('release-cadence-check workflow uses the checked-in helper and uploads a machine-readable report', () => {
  const raw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(raw);
  const cadenceJob = workflow?.jobs?.['cadence-check'];
  const steps = cadenceJob?.steps ?? [];
  const evaluateStep = steps.find((step) => step?.name === 'Evaluate package freshness and reconcile stale issue');
  const uploadStep = steps.find((step) => step?.name === 'Upload cadence report');

  assert.equal(cadenceJob?.permissions?.actions, undefined);
  assert.equal(workflow?.permissions?.actions, 'read');
  assert.equal(workflow?.permissions?.issues, 'write');
  assert.equal(workflow?.permissions?.contents, 'read');
  assert.ok(steps.some((step) => step?.uses === 'actions/checkout@v5'), 'workflow should check out the repository');
  assert.ok(evaluateStep, 'workflow should invoke the cadence helper step');
  assert.match(evaluateStep.run, /node tools\/priority\/release-cadence-check\.mjs/);
  assert.match(evaluateStep.run, /--repo "\$\{\{\s*github\.repository\s*\}\}"/);
  assert.match(evaluateStep.run, /--out tests\/results\/_agent\/release\/release-cadence-check-report\.json/);
  assert.equal(evaluateStep.env?.GH_TOKEN, '${{ github.token }}');
  assert.ok(uploadStep, 'workflow should upload the cadence report artifact');
  assert.equal(uploadStep.uses, 'actions/upload-artifact@v7');
  assert.match(raw, /name: release-cadence-check-report-\$\{\{\s*github\.run_id\s*\}\}/);
  assert.doesNotMatch(raw, /GET \/orgs\/\{org\}\/packages\/\{package_type\}\/\{package_name\}\/versions/);
});
