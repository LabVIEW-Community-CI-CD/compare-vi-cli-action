import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const repoRoot = path.resolve(import.meta.dirname, '..', '..', '..');
const routingPolicy = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'tools/policy/runner-capability-routing.json'), 'utf8')
);

const ingressRunOnPattern = /\bruns-on:\s*\[[^\]\r\n]*\bself-hosted\b[^\]\r\n]*\]/g;

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

function expectedRunsOn(job) {
  return `runs-on: [${routingPolicy.baseIngressLabels.concat(job.requiredCapabilityLabels ?? []).join(', ')}]`;
}

test('self-hosted compare workflows follow the checked-in routing policy', () => {
  for (const workflow of routingPolicy.workflowJobRouting) {
    const content = readWorkflow(workflow.workflow);
    const selfHostedCount = content.match(ingressRunOnPattern)?.length ?? 0;

    assert.equal(
      selfHostedCount,
      workflow.jobs.length,
      `${workflow.workflow} must keep policy coverage for every self-hosted compare job`
    );

    for (const job of workflow.jobs) {
      if ((job.requiredCapabilityLabels ?? []).length === 0) {
        assert.equal(
          job.routingClass,
          'ingress-only',
          `${workflow.workflow}#${job.id} should stay ingress-only when no specialized labels are required`
        );
      } else {
        assert.equal(
          job.routingClass,
          'specialized-opt-in',
          `${workflow.workflow}#${job.id} must declare a specialized opt-in routing class`
        );
      }

      const jobBlock = extractJobBlock(content, job.id);
      assert.match(
        jobBlock,
        new RegExp(escapeRegex(expectedRunsOn(job))),
        `${workflow.workflow}#${job.id} must route through its declared compare capability contract`
      );
    }
  }
});

test('labview-cli-compare consumes an explicit LV32 host-plane readiness receipt', () => {
  const workflow = readWorkflow('.github/workflows/labview-cli-compare.yml');
  const jobBlock = extractJobBlock(workflow, 'cli-compare');

  assert.match(jobBlock, /id:\s*host_plane/);
  assert.match(jobBlock, /Write-LabVIEW2026HostPlaneDiagnostics\.ps1 -OutputPath \$reportPath/);
  assert.match(jobBlock, /tests\/results\/_agent\/host-planes\/labview-2026-host-plane-report\.json/);
  assert.match(jobBlock, /\$report\.native\.planes\.x32\.status -ne 'ready'/);
  assert.match(jobBlock, /LABVIEW_CLI_PATH:\s*\$\{\{\s*steps\.host_plane\.outputs\.cli\s*\}\}/);
  assert.doesNotMatch(
    jobBlock,
    /Program Files \(x86\)\\National Instruments\\Shared\\LabVIEW CLI\\LabVIEWCLI\.exe/,
    'specialized LV32 workflow should derive its CLI path from the host-plane receipt instead of a hard-coded fallback'
  );
});

test('pester-reusable generic ingress preflight stays off implicit x86 LVCompare fallback', () => {
  const workflow = readWorkflow('.github/workflows/pester-reusable.yml');
  const jobBlock = extractJobBlock(workflow, 'preflight');

  assert.match(jobBlock, /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress\]/);
  assert.match(jobBlock, /LVCOMPARE_PATH:\s*\$\{\{\s*vars\.LVCOMPARE_PATH \|\| ''\s*\}\}/);
  assert.match(jobBlock, /C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare\.exe/);
  assert.doesNotMatch(
    jobBlock,
    /Program Files \(x86\)\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare\.exe/,
    'generic ingress preflight should not silently fall back to the specialized x86 compare path'
  );
  assert.match(
    jobBlock,
    /does not silently fall back to Program Files \(x86\); use LVCOMPARE_PATH or an explicit specialized LV32 workflow/,
    'generic ingress preflight should explain how to use the specialized path explicitly when needed'
  );
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
