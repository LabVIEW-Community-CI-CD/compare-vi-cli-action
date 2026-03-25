import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const repoRoot = path.resolve(import.meta.dirname, '..', '..', '..');
const routingPolicy = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'tools/policy/runner-capability-routing.json'), 'utf8')
);

const ingressRunOnPattern = /\bruns-on:\s*\[[^\]\r\n]*\bself-hosted\b[^\]\r\n]*\]/g;
const expectedBaseRunsOn = `runs-on: [${routingPolicy.baseIngressLabels.join(', ')}]`;

function readWorkflow(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function extractJobBlock(workflowText, jobId) {
  const pattern = new RegExp(
    `\\n  ${escapeRegex(jobId)}:\\r?\\n([\\s\\S]*?)(?=\\n  [A-Za-z0-9_-]+:\\r?\\n|$)`
  );
  const match = workflowText.match(pattern);
  assert.ok(match, `job ${jobId} must exist in workflow`);
  return match[1];
}

test('self-hosted compare workflows stay ingress-only until they need specialized planes', () => {
  for (const workflow of routingPolicy.workflowJobRouting) {
    const content = readWorkflow(workflow.workflow);
    const selfHostedCount = content.match(ingressRunOnPattern)?.length ?? 0;

    assert.equal(
      selfHostedCount,
      workflow.jobs.length,
      `${workflow.workflow} must keep policy coverage for every self-hosted compare job`
    );

    for (const job of workflow.jobs) {
      assert.deepEqual(
        job.requiredCapabilityLabels,
        [],
        `${workflow.workflow}#${job.id} should remain ingress-only in this slice`
      );

      const jobBlock = extractJobBlock(content, job.id);
      assert.match(
        jobBlock,
        new RegExp(escapeRegex(expectedBaseRunsOn)),
        `${workflow.workflow}#${job.id} must route through compare capability ingress`
      );
    }
  }
});

test('workflow updater probe job defaults to compare capability ingress labels', () => {
  const updater = fs.readFileSync(
    path.join(repoRoot, 'tools/workflows/_update_workflows_impl.py'),
    'utf8'
  );

  assert.match(updater, /COMPARE_CAPABILITY_INGRESS_RUNS_ON\s*=\s*\[/);
  assert.match(updater, /'comparevi'/);
  assert.match(updater, /'capability-ingress'/);
  assert.doesNotMatch(
    updater,
    /'runs-on': \['self-hosted', 'Windows', 'X64'\]/,
    'workflow updater must not reintroduce generic self-hosted routing'
  );
});
