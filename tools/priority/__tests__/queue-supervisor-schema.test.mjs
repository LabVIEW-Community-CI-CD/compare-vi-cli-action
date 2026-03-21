#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runQueueSupervisor } from '../queue-supervisor.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function successCheck(name) {
  return {
    __typename: 'CheckRun',
    name,
    status: 'COMPLETED',
    conclusion: 'SUCCESS'
  };
}

test('queue supervisor report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'queue-supervisor-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const runGhJsonFn = (args) => {
    if (args[0] === 'pr' && args[1] === 'list') {
      return [
        {
          number: 501,
          title: '[P0] queue-ready',
          body: 'Coupling: independent',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'owner' },
          isDraft: false,
          mergeStateStatus: 'CLEAN',
          mergeable: 'MERGEABLE',
          updatedAt: '2026-03-06T11:00:00Z',
          url: 'https://example.test/pr/501',
          labels: [],
          statusCheckRollup: [successCheck('lint')],
          autoMergeRequest: null
        }
      ];
    }
    if (args[0] === 'api' && String(args[1]).includes('validate.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-06T10:40:00Z', updated_at: '2026-03-06T10:41:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('policy-guard-upstream.yml')) {
      return {
        workflow_runs: [
          { conclusion: 'success', status: 'completed', created_at: '2026-03-06T10:30:00Z', updated_at: '2026-03-06T10:31:00Z' }
        ]
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('fixture-drift.yml')) return { workflow_runs: [] };
    if (args[0] === 'api' && String(args[1]).includes('commit-integrity.yml')) return { workflow_runs: [] };
    throw new Error(`Unexpected gh args: ${args.join(' ')}`);
  };

  const runCommandFn = (command, args) => {
    if (command === 'node' && args[0] === 'tools/priority/merge-sync-pr.mjs') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (command === 'gh' && args[0] === 'pr' && args[1] === 'edit') {
      return { status: 0, stdout: '', stderr: '' };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const readJsonFileFn = async (filePath) => {
    if (String(filePath).endsWith('branch-required-checks.json')) {
      return { branches: { develop: ['lint'] } };
    }
    if (String(filePath).endsWith('policy.json')) {
      return {
        rulesets: {
          develop: {
            includes: ['refs/heads/develop'],
            merge_queue: { merge_method: 'SQUASH' }
          }
        }
      };
    }
    throw new Error(`Unexpected read path: ${filePath}`);
  };

  const { report } = await runQueueSupervisor({
    repoRoot,
    args: {
      apply: true,
      dryRun: false,
      reportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      maxInflight: 5,
      minInflight: 1,
      adaptiveCap: false,
      maxQueuedRuns: 6,
      maxInProgressRuns: 8,
      stallThresholdMinutes: 45,
      repo: 'owner/repo',
      baseBranches: ['develop', 'main'],
      healthBranch: 'develop',
      help: false
    },
    now: new Date('2026-03-06T12:00:00Z'),
    runGhJsonFn,
    runCommandFn,
    readJsonFileFn,
    readOptionalJsonFn: async (filePath) => {
      if (String(filePath).includes('delivery-agent-state.json')) {
        return {
          activeCodingLanes: 1,
          workerPool: {
            targetSlotCount: 2,
            occupiedSlotCount: 1,
            availableSlotCount: 1,
            releasedLaneCount: 0,
            utilizationRatio: 0.5
          }
        };
      }
      return {};
    },
    writeReportFn: async (reportPath) => reportPath
  });

  assert.equal(report.workerOccupancy.available, true);
  assert.equal(report.workerOccupancy.targetSlotCount, 2);
  assert.equal(report.workerOccupancy.occupiedSlotCount, 1);

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
