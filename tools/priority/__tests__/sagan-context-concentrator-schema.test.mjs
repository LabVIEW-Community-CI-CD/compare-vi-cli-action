import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runSaganContextConcentrator } from '../sagan-context-concentrator.mjs';

const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('sagan context concentrator report matches schema', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sagan-context-concentrator-schema-'));
  writeJson(path.join(tmpDir, '.agent_priority_cache.json'), {
    number: 1909,
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    title: '[governor]: build Sagan context concentrator for durable subagent memory',
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909',
    state: 'OPEN'
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json'), {
    schema: 'priority/autonomous-governor-summary-report@v1',
    generatedAt: '2026-03-23T23:00:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      queueEmptyReportPath: 'tests/results/_agent/issue/no-standing-priority.json',
      continuitySummaryPath: 'tests/results/_agent/handoff/continuity-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      wakeLifecyclePath: 'tests/results/_agent/issue/wake-lifecycle.json',
      wakeInvestmentAccountingPath: 'tests/results/_agent/capital/wake-investment-accounting.json',
      deliveryRuntimeStatePath: 'tests/results/_agent/runtime/delivery-agent-state.json',
      releaseSigningReadinessPath: 'tests/results/_agent/release/release-signing-readiness.json'
    },
    compare: {},
    wake: {},
    funding: {},
    summary: {
      governorMode: 'compare-governance-work',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'keep-building-concentrator',
      queueState: 'active',
      monitoringStatus: 'active',
      releaseSigningStatus: 'missing'
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-portfolio-summary.json'), {
    schema: 'priority/autonomous-governor-portfolio-summary-report@v1',
    generatedAt: '2026-03-23T23:00:10Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      compareGovernorSummaryPath: 'tests/results/_agent/handoff/autonomous-governor-summary.json',
      monitoringModePath: 'tests/results/_agent/handoff/monitoring-mode.json',
      repoGraphTruthPath: 'tests/results/_agent/handoff/downstream-repo-graph-truth.json'
    },
    compare: {},
    portfolio: {
      repositoryCount: 1,
      repositories: [],
      dependencies: [],
      unsupportedPaths: []
    },
    summary: {
      status: 'active',
      governorMode: 'compare-governance-work',
      currentOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      nextAction: 'keep-building-concentrator',
      ownerDecisionSource: 'compare-governor-summary',
      templateMonitoringStatus: 'pass',
      supportedProofStatus: 'pass',
      repoGraphStatus: 'pass',
      queueHandoffStatus: 'none',
      queueHandoffNextWakeCondition: null,
      queueHandoffPrUrl: null,
      queueAuthoritySource: 'none',
      viHistoryDistributorDependencyStatus: 'unknown',
      viHistoryDistributorDependencyTargetRepository: null,
      viHistoryDistributorDependencyExternalBlocker: null,
      viHistoryDistributorDependencyPublicationState: null,
      viHistoryDistributorDependencyPublishedBundleState: null,
      viHistoryDistributorDependencyPublishedBundleReleaseTag: null,
      viHistoryDistributorDependencyAuthoritativeConsumerPin: null,
      viHistoryDistributorDependencySigningAuthorityState: null
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), {
    schema: 'agent-handoff/monitoring-mode-v1',
    generatedAt: '2026-03-23T23:00:20Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    summary: {
      status: 'active',
      futureAgentAction: 'continue-compare-governance-work',
      wakeConditionCount: 0
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'memory', 'subagent-episodes', 'episode.json'), {
    schema: 'priority/subagent-episode-report@v1',
    generatedAt: '2026-03-23T22:59:00Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      sourcePath: 'tmp/episode.json'
    },
    episodeId: 'episode-1',
    agent: {
      id: 'euler-id',
      name: 'Euler',
      role: 'explorer',
      model: 'gpt-5.4-mini'
    },
    task: {
      summary: 'Inspect concentrator seams',
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
      outcome: 'seams-found',
      blocker: null,
      nextAction: 'patch handoff',
      detail: null
    },
    evidence: {
      filesTouched: [],
      receipts: [],
      commands: [],
      notes: []
    },
    cost: {
      observedDurationSeconds: 30,
      tokenUsd: 0.02,
      operatorLaborUsd: 2.083333,
      blendedLowerBoundUsd: 2.103333
    }
  });

  const { report } = await runSaganContextConcentrator(
    {
      repoRoot: tmpDir
    },
    {
      now: new Date('2026-03-23T23:01:00Z')
    }
  );

  const schema = readJson(path.join(repoRoot, 'docs', 'schemas', 'sagan-context-concentrator-report-v1.schema.json'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
