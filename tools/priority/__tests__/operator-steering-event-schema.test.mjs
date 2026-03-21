import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runOperatorSteeringEvent } from '../operator-steering-event.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('operator steering event schema validates a generated receipt', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-steering-schema-'));
  const continuityPath = path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json');
  const runtimeOutputPath = path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json');
  const handoffOutputPath = path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json');
  const historyDir = path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events');
  const invoiceTurnDir = path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns');

  writeJson(continuityPath, {
    schema: 'priority/continuity-telemetry-report@v1',
    generatedAt: '2026-03-21T23:10:00.000Z',
    repoRoot: root,
    status: 'at-risk',
    issueContext: {
      mode: 'issue',
      issue: 1718,
      present: true,
      fresh: true,
      observedAt: '2026-03-21T23:09:00.000Z',
      reason: null
    },
    continuity: {
      status: 'at-risk',
      preservedWithoutPrompt: true,
      promptDependency: 'medium',
      unattendedSignalCount: 4,
      quietPeriod: {
        status: 'degrading',
        continuityReferenceAt: '2026-03-21T23:09:00.000Z',
        silenceGapSeconds: 0,
        operatorQuietPeriodTreatedAsPause: true
      },
      turnBoundary: {
        status: 'active-work-pending',
        operatorTurnEndWouldCreateIdleGap: true,
        activeLaneIssue: 1718,
        wakeCondition: 'checks-green',
        source: 'delivery-state',
        reason: 'standing issue #1718 still has active work pending'
      },
      recommendation: 'keep the live lane active'
    }
  });

  writeJson(path.join(invoiceTurnDir, 'invoice-turn.json'), {
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    policy: {
      fundingPurpose: 'operational',
      activationState: 'active'
    }
  });

  const result = runOperatorSteeringEvent({
    repoRoot: root,
    continuityPath,
    runtimeOutputPath,
    handoffOutputPath,
    historyDir,
    invoiceTurnDir
  }, new Date('2026-03-21T23:15:00.000Z'));

  assert.equal(result.status, 'created');

  const schema = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'docs', 'schemas', 'operator-steering-event-v1.schema.json'), 'utf8'));
  const report = JSON.parse(fs.readFileSync(runtimeOutputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
