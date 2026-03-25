import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_SNAPSHOT_PATH,
  MODE_DEFAULTS,
  REPORT_SCHEMA,
  SNAPSHOT_SCHEMA,
  buildBackgroundAgentSaturationReport,
  parseArgs,
  runBackgroundAgentSaturation
} from '../background-agent-saturation.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs applies defaults for snapshot and output paths', () => {
  const parsed = parseArgs(['node', 'background-agent-saturation.mjs', '--repo-root', 'C:/repo']);
  assert.match(parsed.snapshotPath, new RegExp(DEFAULT_SNAPSHOT_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(parsed.outputPath, new RegExp(DEFAULT_OUTPUT_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('buildBackgroundAgentSaturationReport weights awaiting-instruction less harshly than done', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'background-agent-saturation-build-'));
  writeJson(path.join(root, '.agent_priority_cache.json'), {
    number: 1967,
    state: 'OPEN'
  });
  writeJson(path.join(root, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: 1967
  });
  const report = buildBackgroundAgentSaturationReport(
    {
      schema: SNAPSHOT_SCHEMA,
      generatedAt: '2026-03-25T19:40:00Z',
      owner: 'Sagan',
      mode: 'custom',
      targetSaturation: 0.98,
      acceptableBand: { min: 0.83, max: 1.0 },
      measurementWindow: 'rolling-30m',
      availableAgents: 6,
      agents: [
        { id: 'a1', name: 'Alpha', state: 'productive', taskSummary: 'Root-cause analysis', detail: null },
        { id: 'a2', name: 'Beta', state: 'awaiting instruction', taskSummary: 'Waiting for next bounded task', detail: null },
        { id: 'a3', name: 'Gamma', state: 'done', taskSummary: 'Completed report', detail: null },
        { id: 'a4', name: 'Delta', state: 'blocked', taskSummary: 'Blocked on CI', detail: null }
      ]
    },
    { repoRoot: root }
  );

  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.productiveAgents, 1);
  assert.equal(report.awaitingInstructionAgents, 1);
  assert.equal(report.doneAgents, 1);
  assert.equal(report.weightedProductiveAgents, 1.25);
  assert.equal(report.effectiveSaturation, 0.2083);
  assert.equal(report.rawOccupancy, 0.6667);
  assert.equal(report.weights.awaitingInstruction, 0.25);
  assert.equal(report.status, 'active');
});

test('runBackgroundAgentSaturation marks queue-empty repos as constrained while keeping weighted counts', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'background-agent-saturation-constrained-'));
  writeJson(path.join(root, 'tests', 'results', '_agent', 'runtime', 'background-agent-state.json'), {
    schema: SNAPSHOT_SCHEMA,
    generatedAt: '2026-03-25T19:45:00Z',
    owner: 'Sagan',
    mode: 'balanced',
    targetSaturation: MODE_DEFAULTS.balanced.target,
    acceptableBand: MODE_DEFAULTS.balanced.band,
    measurementWindow: 'rolling-30m',
    availableAgents: 6,
    agents: [
      { id: 'a1', name: 'Alpha', state: 'awaiting-instruction', taskSummary: 'Ready for next slice', detail: null },
      { id: 'a2', name: 'Beta', state: 'done', taskSummary: 'Closed out prior slice', detail: null }
    ]
  });
  writeJson(path.join(root, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: null
  });
  writeJson(path.join(root, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    reason: 'queue-empty',
    openIssueCount: 0
  });

  const { report, outputPath } = await runBackgroundAgentSaturation({ repoRoot: root }, { now: new Date('2026-03-25T19:46:00Z') });

  assert.equal(report.status, 'constrained');
  assert.equal(report.constraintReason, 'queue-empty');
  assert.equal(report.awaitingInstructionAgents, 1);
  assert.equal(report.doneAgents, 1);
  assert.equal(report.weightedProductiveAgents, 0.25);
  assert.equal(report.effectiveSaturation, 0.0417);
  assert.equal(fs.existsSync(outputPath), true);
});
