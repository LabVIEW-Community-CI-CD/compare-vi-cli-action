import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  REPORT_SCHEMA,
  buildSubagentEpisodeReport,
  parseArgs,
  runSubagentEpisode
} from '../subagent-episode.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs requires input and keeps defaults', () => {
  const parsed = parseArgs([
    'node',
    'subagent-episode.mjs',
    '--input',
    'tmp/episode.json'
  ]);

  assert.equal(parsed.inputPath, 'tmp/episode.json');
  assert.equal(parsed.outputPath, null);
});

test('buildSubagentEpisodeReport normalizes source payload', () => {
  const report = buildSubagentEpisodeReport(
    {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      generatedAt: '2026-03-23T21:00:00Z',
      agent: {
        id: '019d11a9-3e6b-7073-b602-7a0a2085f106',
        name: 'Euler',
        role: 'explorer',
        model: 'gpt-5.4-mini'
      },
      task: {
        summary: 'Inspect handoff seams',
        class: 'exploration',
        issueNumber: 1909,
        issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
      },
      execution: {
        status: 'completed',
        lane: '1909-sagan-context-concentrator',
        branch: 'issue/upstream-1909-sagan-context-concentrator',
        executionPlane: 'windows-host',
        dockerLaneId: 'docker-euler-001',
        hostCapabilityLeaseId: 'lease-euler-001',
        cellId: 'cell-euler-001',
        executionCellLeaseId: 'cell-lease-euler-001',
        dockerLaneLeaseId: 'docker-lease-euler-001',
        cellClass: 'worker-cell',
        suiteClass: 'handoff-analysis',
        harnessKind: 'teststand-instance',
        harnessInstanceId: 'ts-euler-001',
        runtimeSurface: 'windows-native-teststand',
        processModelClass: 'sequential',
        operatorAuthorizationRef: null,
        premiumSaganMode: false
      },
      summary: {
        status: 'reported',
        outcome: 'handoff-seams-identified',
        blocker: null,
        nextAction: 'wire concentrator into Print-AgentHandoff',
        detail: 'Print-AgentHandoff and Import-HandoffState are the right seams.'
      },
      evidence: {
        filesTouched: ['tools/Print-AgentHandoff.ps1'],
        receipts: ['tests/results/_agent/handoff/autonomous-governor-summary.json'],
        commands: ['rg -n governor tools/Print-AgentHandoff.ps1'],
        notes: ['Focus on handoff refresh and render path.']
      },
      cost: {
        observedDurationSeconds: 90,
        tokenUsd: 0.14,
        operatorLaborUsd: 6.25,
        blendedLowerBoundUsd: 6.39
      }
    },
    {
      repoRoot: 'E:/comparevi-lanes/1909-sagan-context-concentrator',
      inputPath: 'tmp/subagent-input.json',
      now: new Date('2026-03-23T21:05:00Z')
    }
  );

  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.agent.name, 'Euler');
  assert.equal(report.task.issueNumber, 1909);
  assert.equal(report.execution.dockerLaneId, 'docker-euler-001');
  assert.equal(report.execution.cellId, 'cell-euler-001');
  assert.equal(report.execution.harnessInstanceId, 'ts-euler-001');
  assert.equal(report.execution.runtimeSurface, 'windows-native-teststand');
  assert.equal(report.execution.premiumSaganMode, false);
  assert.equal(report.summary.nextAction, 'wire concentrator into Print-AgentHandoff');
  assert.equal(report.cost.blendedLowerBoundUsd, 6.39);
});

test('runSubagentEpisode writes a normalized episode report', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'subagent-episode-'));
  const inputPath = path.join(repoRoot, 'tmp', 'episode-input.json');
  writeJson(inputPath, {
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    agent: {
      id: '019d11a9-3e7f-7331-a692-63a1c6c78904',
      name: 'Euclid',
      role: 'explorer',
      model: 'gpt-5.4-mini'
    },
    task: {
      summary: 'Catalog analogous receipt patterns',
      class: 'exploration',
      issueNumber: 1909
    },
    summary: {
      status: 'reported',
      outcome: 'receipt-templates-found',
      nextAction: 'reuse governor summary schema style'
    },
    execution: {
      cellId: 'cell-euclid-001',
      executionCellLeaseId: 'cell-lease-euclid-001',
      dockerLaneLeaseId: null,
      cellClass: 'worker-cell',
      suiteClass: 'receipt-catalog',
      harnessKind: 'teststand-instance',
      harnessInstanceId: 'ts-euclid-001',
      runtimeSurface: 'windows-native-teststand',
      processModelClass: 'sequential',
      operatorAuthorizationRef: null,
      premiumSaganMode: false
    },
    evidence: {
      notes: ['Use autonomous-governor-summary as the main receipt template.']
    }
  });

  const { report, outputPath } = await runSubagentEpisode(
    {
      repoRoot,
      inputPath
    },
    {
      now: new Date('2026-03-23T22:00:00Z')
    }
  );

  assert.ok(outputPath.includes('subagent-episodes'));
  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.agent.name, 'Euclid');
  assert.equal(report.summary.status, 'reported');
  assert.equal(report.execution.status, 'completed');
  assert.equal(report.execution.cellClass, 'worker-cell');
  assert.equal(report.execution.harnessInstanceId, 'ts-euclid-001');
  assert.ok(fs.existsSync(outputPath));
});
