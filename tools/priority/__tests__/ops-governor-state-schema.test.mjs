#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runRemediationSloEvaluator } from '../remediation-slo-evaluator.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('ops governor state validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'ops-governor-state-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            status: 'warn'
          }
        }
      };
    }
    if (normalized.includes('incident-events.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: [
          {
            id: 'evt-1',
            priority: 'P1',
            occurredAt: '2026-03-06T00:00:00Z',
            detectedAt: '2026-03-06T02:00:00Z',
            routedAt: '2026-03-06T03:00:00Z',
            resolvedAt: '2026-03-06T06:00:00Z',
            reopenedCount: 0
          }
        ]
      };
    }
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          throughputController: {
            retryPressure: {
              retryRatio: 0.1,
              quarantineRatio: 0
            }
          },
          health: {
            redMinutes: 10
          }
        }
      };
    }
    if (normalized.includes('slo-metrics.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            metrics: {
              failureRate: 0.1
            }
          }
        }
      };
    }
    if (normalized.includes('release-scorecard.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          summary: {
            blockerCount: 0,
            status: 'pass'
          }
        }
      };
    }
    if (normalized.includes('ops-governor-state.json')) {
      return {
        exists: true,
        path: filePath,
        error: null,
        payload: {
          schema: 'ops-governor-state@v1',
          mode: 'stabilize',
          healthyStreak: 1
        }
      };
    }
    throw new Error(`Unexpected path: ${filePath}`);
  };

  const { governorState } = await runRemediationSloEvaluator({
    repoRoot,
    now: new Date('2026-03-06T12:00:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      governorStatePath: 'tests/results/_agent/slo/ops-governor-state.json',
      issueEventsPath: 'tests/results/_agent/ops/incident-events.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      sloMetricsPath: 'tests/results/_agent/slo/slo-metrics.json',
      releaseScorecardPath: 'tests/results/_agent/release/release-scorecard.json',
      lookbackDays: 30,
      repo: 'owner/repo',
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo'
    },
    readJsonOptionalFn,
    writeJsonFn: async (outputPath) => outputPath
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(governorState);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
