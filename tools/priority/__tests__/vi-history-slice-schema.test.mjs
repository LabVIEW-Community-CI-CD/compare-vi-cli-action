import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

async function loadSchema() {
  return JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'vi-history-slice-v1.schema.json'), 'utf8')
  );
}

function makeSlice(overrides = {}) {
  return {
    schema: 'vi-history-slice@v1',
    generatedAt: '2026-03-16T16:40:00Z',
    repoPath: '/opt/comparevi/repo',
    resultsDir: '/opt/comparevi/results',
    targetPath: 'src/Sample.vi',
    sourceBranchRef: 'consumer/branch',
    baselineRef: 'develop',
    requestedStartRef: 'head-2',
    startRef: 'head-2',
    endRef: 'base-1',
    maxPairs: 2,
    candidatePairs: 3,
    selectedPairs: 2,
    stopReason: 'max-pairs',
    pairPlanPath: '/opt/comparevi/results/pair-plan.tsv',
    resultLedgerPath: '/opt/comparevi/results/pair-results.tsv',
    pairs: [
      {
        index: 1,
        label: 'pair-001',
        baseRef: 'base-1',
        headRef: 'head-2',
        baseViPath: '/opt/comparevi/results/bootstrap-work/pair-001/base-Sample.vi',
        headViPath: '/opt/comparevi/results/bootstrap-work/pair-001/head-Sample.vi',
        reportPath: '/opt/comparevi/results/default/pair-001-report.html'
      }
    ],
    ...overrides
  };
}

test('vi-history-slice schema validates a planned multi-pair slice contract', async () => {
  const validate = makeAjv().compile(await loadSchema());
  const payload = makeSlice();

  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
});

test('vi-history-slice schema rejects missing per-pair report paths', async () => {
  const validate = makeAjv().compile(await loadSchema());
  const payload = makeSlice({
    pairs: [
      {
        index: 1,
        label: 'pair-001',
        baseRef: 'base-1',
        headRef: 'head-2',
        baseViPath: null,
        headViPath: null
      }
    ]
  });

  assert.equal(validate(payload), false);
  assert.match(JSON.stringify(validate.errors), /reportPath/);
});
