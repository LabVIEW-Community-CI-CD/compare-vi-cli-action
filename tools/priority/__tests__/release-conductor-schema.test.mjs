import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runReleaseConductor } from '../release-conductor.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('release conductor report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'release-conductor-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.includes('queue-supervisor-report.json')) {
      return {
        exists: true,
        error: null,
        path: filePath,
        payload: {
          paused: false,
          throughputController: { mode: 'healthy' },
          retryHistory: {}
        }
      };
    }
    return {
      exists: true,
      error: null,
      path: filePath,
      payload: {
        schema: 'priority/policy-live-state@v1',
        generatedAt: '2026-03-06T10:00:00Z',
        state: {}
      }
    };
  };

  const runGhJsonFn = (args) => {
    if (args[0] !== 'api') {
      throw new Error(`unexpected gh args: ${args.join(' ')}`);
    }
    return {
      workflow_runs: [
        {
          id: 1,
          status: 'completed',
          conclusion: 'success',
          updated_at: '2026-03-06T11:50:00Z'
        }
      ]
    };
  };

  const { report } = await runReleaseConductor({
    repoRoot,
    now: new Date('2026-03-06T12:00:00.000Z'),
    args: {
      apply: false,
      dryRun: true,
      reportPath: 'tests/results/_agent/release/release-conductor-report.json',
      queueReportPath: 'tests/results/_agent/queue/queue-supervisor-report.json',
      policySnapshotPath: 'tests/results/_agent/policy/policy-state-snapshot.json',
      repo: 'owner/repo',
      stream: 'comparevi-cli',
      channel: 'stable',
      version: '0.8.0',
      dwellMinutes: 60,
      quarantineStaleHours: 24,
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo',
      RELEASE_CONDUCTOR_ENABLED: '0'
    },
    runGhJsonFn,
    runCommandFn: () => ({ status: 0, stdout: '', stderr: '' }),
    readJsonOptionalFn,
    writeReportFn: async (reportPath) => reportPath
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});