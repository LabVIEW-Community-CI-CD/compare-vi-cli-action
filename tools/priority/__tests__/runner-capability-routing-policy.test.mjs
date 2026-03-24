import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const repoRoot = path.resolve(import.meta.dirname, '..', '..', '..');
const policyPath = path.join(repoRoot, 'tools/policy/runner-capability-routing.json');
const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));

test('runner capability routing policy defines a stable ingress base and reserved specialized labels', () => {
  assert.equal(policy.version, 1);
  assert.deepEqual(policy.baseIngressLabels, [
    'self-hosted',
    'Windows',
    'X64',
    'comparevi',
    'capability-ingress'
  ]);
  assert.deepEqual(policy.optionalCapabilityLabels, [
    'labview-2026',
    'lv32',
    'docker-lane',
    'teststand'
  ]);
});

test('runner capability routing policy covers all current self-hosted compare workflows in scope', () => {
  const expectedWorkflows = [
    '.github/workflows/ci-orchestrated.yml',
    '.github/workflows/compare-artifacts.yml',
    '.github/workflows/labview-cli-compare.yml',
    '.github/workflows/pester-reusable.yml',
    '.github/workflows/runbook-validation.yml',
    '.github/workflows/smoke-on-label.yml',
    '.github/workflows/smoke.yml',
    '.github/workflows/vi-compare-pr.yml',
    '.github/workflows/vi-compare-refs.yml',
    '.github/workflows/vi-history-compare.yml',
    '.github/workflows/vi-staging-smoke.yml'
  ];

  assert.deepEqual(
    policy.workflowJobRouting.map((entry) => entry.workflow),
    expectedWorkflows
  );

  for (const entry of policy.workflowJobRouting) {
    assert.ok(fs.existsSync(path.join(repoRoot, entry.workflow)), `${entry.workflow} must exist`);
    assert.ok(entry.jobs.length > 0, `${entry.workflow} must list at least one self-hosted job`);
    for (const job of entry.jobs) {
      assert.equal(job.routingClass, 'ingress-only');
      assert.deepEqual(job.requiredCapabilityLabels, []);
    }
  }
});

test('runner capability routing policy records deferred specialization candidates explicitly', () => {
  assert.deepEqual(policy.deferredCapabilityCandidates, [
    {
      workflow: '.github/workflows/labview-cli-compare.yml',
      job: 'cli-compare',
      candidateLabels: ['lv32'],
      reason:
        'The job validates the Program Files (x86) LabVIEW CLI path today, but this slice keeps lv32 reserved for explicit native 32-bit plane consumers until that label contract is widened deliberately.'
    }
  ]);
});
