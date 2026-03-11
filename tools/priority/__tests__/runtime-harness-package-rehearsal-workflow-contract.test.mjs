import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = path.join(repoRoot, '.github', 'workflows', 'runtime-harness-package-rehearsal.yml');

test('runtime-harness package rehearsal stays hosted-only and uses checked-in helpers', () => {
  const raw = readFileSync(workflowPath, 'utf8');
  const workflow = yaml.load(raw);
  const job = workflow?.jobs?.['rehearse-runtime-harness'];
  const steps = job?.steps ?? [];

  assert.equal(workflow?.permissions?.packages, 'write');
  assert.equal(workflow?.permissions?.contents, 'read');
  assert.equal(job?.['runs-on'], 'ubuntu-latest');
  assert.ok(workflow?.on?.workflow_dispatch, 'workflow should be dispatchable');
  assert.ok(steps.some((step) => step?.uses === 'actions/checkout@v5'));
  assert.ok(steps.some((step) => step?.uses === 'actions/setup-node@v5'));

  const resolveStep = steps.find((step) => step?.name === 'Resolve runtime-harness publish context');
  const stageStep = steps.find((step) => step?.name === 'Stage runtime-harness package candidate');
  const verifyStep = steps.find((step) => step?.name === 'Verify runtime-harness candidate from clean consumer context');
  const uploadStep = steps.find((step) => step?.name === 'Upload rehearsal artifacts');
  const publishStep = steps.find((step) => step?.name === 'Publish runtime-harness candidate');

  assert.ok(resolveStep, 'workflow should resolve publish context');
  assert.match(resolveStep.run, /node tools\/priority\/js-package-release\.mjs/);
  assert.match(resolveStep.run, /--action resolve/);
  assert.match(resolveStep.run, /--github-output "\$GITHUB_OUTPUT"/);

  assert.ok(stageStep, 'workflow should stage a packed candidate');
  assert.match(stageStep.run, /--action stage/);
  assert.match(stageStep.run, /--staging-dir tests\/results\/_agent\/release\/runtime-harness-package\/staging/);
  assert.match(stageStep.run, /--tarball-dir tests\/results\/_agent\/release\/runtime-harness-package\/tarballs/);

  assert.ok(publishStep, 'workflow should expose an optional publish step');
  assert.match(publishStep.run, /node tools\/npm\/cli\.mjs publish/);
  assert.equal(publishStep.env?.NODE_AUTH_TOKEN, '${{ github.token }}');

  assert.ok(verifyStep, 'workflow should verify from a clean consumer context');
  assert.match(verifyStep.run, /--action verify/);
  assert.match(verifyStep.run, /--consumer-dir tests\/results\/_agent\/release\/runtime-harness-package\/consumer/);

  assert.ok(uploadStep, 'workflow should upload machine-readable evidence');
  assert.equal(uploadStep.uses, 'actions/upload-artifact@v5');
  assert.doesNotMatch(raw, /self-hosted/i);
});
