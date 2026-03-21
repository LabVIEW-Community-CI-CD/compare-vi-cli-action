import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { buildContinuityTelemetry } from '../continuity-telemetry.mjs';

const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('continuity telemetry report matches the checked-in schema', () => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'continuity-schema-'));
  fs.mkdirSync(path.join(fixtureRoot, '.git', 'agent-writer-leases'), { recursive: true });
  fs.mkdirSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue'), { recursive: true });
  fs.mkdirSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'handoff'), { recursive: true });
  fs.mkdirSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime'), { recursive: true });
  fs.mkdirSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'sessions'), { recursive: true });

  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-schema',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:58:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: 1663,
    updatedAt: '2026-03-21T19:59:00.000Z',
    actions: []
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'handoff', 'entrypoint-status.json'), {
    schema: 'agent-handoff/entrypoint-status-v1',
    generatedAt: '2026-03-21T19:58:00.000Z',
    handoffPath: 'AGENT_HANDOFF.txt',
    maxLines: 80,
    actualLineCount: 40,
    status: 'pass',
    checks: {
      primaryHeading: true,
      lineBudget: true,
      requiredHeadings: true,
      liveArtifactGuidance: true,
      stableEntrypointGuidance: true,
      noStatusLogGuidance: true,
      machineGeneratedArtifactGuidance: true,
      noDatedHistorySections: true
    },
    commands: {
      bootstrap: 'pwsh -File tools/priority/bootstrap.ps1',
      standingPriority: 'pwsh -File tools/Get-StandingPriority.ps1 -Plain',
      printHandoff: 'pwsh -File tools/Print-AgentHandoff.ps1',
      projectPortfolio: 'node tools/npm/run-script.mjs priority:project:portfolio:check',
      developSync: 'node tools/npm/run-script.mjs priority:develop:sync'
    },
    artifacts: {
      priorityCache: '.agent_priority_cache.json',
      router: 'tests/results/_agent/issue/router.json',
      noStandingPriority: 'tests/results/_agent/issue/no-standing-priority.json',
      dockerReviewLoopSummary: 'tests/results/_agent/verification/docker-review-loop-summary.json',
      continuitySummary: 'tests/results/_agent/handoff/continuity-summary.json',
      entrypointStatus: 'tests/results/_agent/handoff/entrypoint-status.json',
      handoffGlob: 'tests/results/_agent/handoff/*.json',
      sessionGlob: 'tests/results/_agent/sessions/*.json'
    },
    violations: []
  });

  const schema = JSON.parse(fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'continuity-telemetry-report-v1.schema.json'), 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const { report } = buildContinuityTelemetry({ repoRoot: fixtureRoot }, new Date('2026-03-21T20:00:00.000Z'));
  const valid = validate(report);
  if (!valid) {
    const errors = (validate.errors || [])
      .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
      .join('\n');
    assert.fail(`Continuity telemetry report failed schema validation:\n${errors}`);
  }
});
