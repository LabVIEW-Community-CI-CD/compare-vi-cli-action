import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runWeeklyScorecard } from '../weekly-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('weekly scorecard report validates schema', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'weekly-scorecard-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const readJsonOptionalFn = async (filePath) => {
    const normalized = String(filePath);
    if (normalized.endsWith('weekly-scorecard.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'warn'
          }
        },
        error: null
      };
    }
    if (normalized.includes('remediation-slo-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          summary: {
            status: 'fail'
          }
        },
        error: null
      };
    }
    if (normalized.includes('canary-replay-conformance-report.json')) {
      return {
        exists: true,
        path: filePath,
        payload: {
          status: 'warn'
        },
        error: null
      };
    }
    throw new Error(`Unexpected path: ${filePath}`);
  };

  const { report } = await runWeeklyScorecard({
    repoRoot,
    now: new Date('2026-03-07T00:00:00Z'),
    args: {
      outputPath: 'tests/results/_agent/slo/weekly-scorecard.json',
      remediationReportPath: 'tests/results/_agent/slo/remediation-slo-report.json',
      canaryReportPath: 'tests/results/_agent/canary/canary-replay-conformance-report.json',
      mode: 'gameday',
      requireCanary: true,
      routeOnPersistentBreach: true,
      issueTitlePrefix: '[Governance] Weekly scorecard breach',
      issueLabels: ['governance', 'slo', 'canary'],
      repo: 'owner/repo',
      help: false
    },
    environment: {
      GITHUB_REPOSITORY: 'owner/repo'
    },
    githubToken: 'test-token',
    routeIssueFn: async () => ({
      action: 'comment',
      issueNumber: 42,
      issueUrl: 'https://example.test/issues/42',
      error: null
    }),
    readJsonOptionalFn,
    writeJsonFn: async (reportPath) => reportPath
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
