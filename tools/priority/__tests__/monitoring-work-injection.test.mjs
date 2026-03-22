import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runMonitoringWorkInjection } from '../monitoring-work-injection.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/monitoring-work-injection-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    requireQueueEmpty: true,
    rules: [
      {
        id: 'runner-conflict',
        requireMonitoringMode: 'active',
        when: {
          hostSignalStatus: 'runner-conflict'
        },
        issue: {
          title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
          dedupeMarker: 'monitoring-work-injector:runner-conflict',
          labels: ['standing-priority', 'governance'],
          bodyLines: ['## Summary', 'Injected from automated monitoring.']
        }
      }
    ]
  };
}

function createInputs(tmpDir) {
  const policyPath = path.join(tmpDir, 'policy.json');
  const queuePath = path.join(tmpDir, 'queue.json');
  const monitoringPath = path.join(tmpDir, 'monitoring.json');
  const hostSignalPath = path.join(tmpDir, 'host-signal.json');
  writeJson(policyPath, createPolicy());
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(monitoringPath, {
    schema: 'agent-handoff/monitoring-mode-v1',
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  });
  writeJson(hostSignalPath, {
    schema: 'priority/delivery-agent-host-signal@v1',
    status: 'runner-conflict',
    provider: 'native-wsl',
    daemonFingerprint: 'abc123'
  });
  return { policyPath, queuePath, monitoringPath, hostSignalPath };
}

test('runMonitoringWorkInjection reports no-trigger when queue is not empty', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-noop-'));
  const { policyPath, monitoringPath, hostSignalPath } = createInputs(tmpDir);
  const queuePath = path.join(tmpDir, 'queue.json');
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'labels-missing',
    openIssueCount: 1
  });

  const { report } = await runMonitoringWorkInjection({
    repoRoot: tmpDir,
    policyPath,
    queueEmptyReportPath: queuePath,
    monitoringModePath: monitoringPath,
    hostSignalPath,
    repository: 'owner/repo'
  });

  assert.equal(report.summary.status, 'no-trigger');
  assert.equal(report.summary.injected, false);
});

test('runMonitoringWorkInjection creates an issue when runner-conflict fires in queue-empty monitoring mode', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-create-'));
  const { policyPath, queuePath, monitoringPath, hostSignalPath } = createInputs(tmpDir);
  const ghCalls = [];

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      monitoringModePath: monitoringPath,
      hostSignalPath,
      repository: 'owner/repo'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'create') {
          return {
            stdout: 'https://github.com/owner/repo/issues/123\n'
          };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'created-issue');
  assert.equal(report.summary.issueNumber, 123);
  assert.equal(report.summary.triggerId, 'runner-conflict');
  assert.ok(ghCalls.some((entry) => entry.startsWith('issue create')));
});

test('runMonitoringWorkInjection reuses an existing injected issue and restores missing labels', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitoring-work-injection-existing-'));
  const { policyPath, queuePath, monitoringPath, hostSignalPath } = createInputs(tmpDir);
  const ghCalls = [];

  const { report } = await runMonitoringWorkInjection(
    {
      repoRoot: tmpDir,
      policyPath,
      queueEmptyReportPath: queuePath,
      monitoringModePath: monitoringPath,
      hostSignalPath,
      repository: 'owner/repo'
    },
    {
      runGhJsonFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'list') {
          return [
            {
              number: 77,
              title: '[monitoring]: reconcile runner-conflict blocking autonomous loop',
              url: 'https://github.com/owner/repo/issues/77',
              body: '<!-- monitoring-work-injector:runner-conflict -->',
              labels: [{ name: 'governance' }]
            }
          ];
        }
        throw new Error(`unexpected gh json args: ${args.join(' ')}`);
      },
      runGhFn: (args) => {
        ghCalls.push(args.join(' '));
        if (args[0] === 'issue' && args[1] === 'edit') {
          return { stdout: '' };
        }
        throw new Error(`unexpected gh args: ${args.join(' ')}`);
      }
    }
  );

  assert.equal(report.summary.status, 'existing-issue');
  assert.equal(report.summary.issueNumber, 77);
  assert.ok(ghCalls.some((entry) => entry.includes('--add-label standing-priority')));
});
