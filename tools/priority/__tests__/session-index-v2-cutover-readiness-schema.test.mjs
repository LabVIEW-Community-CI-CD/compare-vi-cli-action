import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const scriptPath = path.join(repoRoot, 'tools', 'Write-SessionIndexV2CutoverReadiness.ps1');
const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'session-index-v2-cutover-readiness-v1.schema.json');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function writeMarkdown(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, 'utf8');
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function createAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false, $data: true });
  addFormats(ajv);
  return ajv;
}

function createFixture(
  tmpDir,
  name,
  { promotionReady, consecutiveSuccess, contractStatus, disposition, remainingChecklistItems, consumerRows }
) {
  const root = path.join(tmpDir, name);
  fs.mkdirSync(root, { recursive: true });

  const contractPath = path.join(root, 'session-index-v2-contract.json');
  const dispositionPath = path.join(root, 'session-index-v2-disposition.json');
  const consumerMatrixPath = path.join(root, 'SESSION_INDEX_V2_CONSUMER_MATRIX.md');
  const deprecationPath = path.join(root, 'SESSION_INDEX_V1_DEPRECATION.md');
  const outputPath = path.join(root, 'session-index-v2-cutover-readiness.json');

  writeJson(contractPath, {
    schema: 'session-index-v2-contract/v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    status: contractStatus,
    enforce: false,
    failures: contractStatus === 'pass' ? [] : ['contract mismatch'],
    notes: [],
    branchProtection: {
      policyPath: 'tools/policy/branch-required-checks.json',
      requiredContexts: ['lint', 'session-index'],
      missingContexts: []
    },
    burnIn: {
      threshold: 10,
      status: 'ok',
      reason: 'aligned',
      consecutiveSuccess,
      inspectedRuns: consecutiveSuccess,
      promotionReady
    },
    burnInReceipt: {
      schema: 'session-index-v2-burn-in-receipt@v1',
      mode: 'burn-in',
      status: contractStatus === 'pass' ? 'clean' : 'mismatch',
      mismatchClass: contractStatus === 'pass' ? 'none' : 'missing-required-contexts',
      mismatchFingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      mismatchSummary: contractStatus === 'pass' ? [] : ['contract mismatch'],
      recurrence: {
        classification: contractStatus === 'pass' ? 'clean' : 'unknown',
        burnInStatus: 'ok',
        consecutiveSuccess
      },
      evidence: {
        reportPath: contractPath,
        resultsDir: root,
        sessionIndexV1Path: path.join(root, 'session-index.json'),
        sessionIndexV2Path: path.join(root, 'session-index-v2.json'),
        policyPath: 'tools/policy/branch-required-checks.json'
      }
    }
  });

  writeJson(dispositionPath, {
    schema: 'session-index-v2-disposition-summary@v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    mode: 'burn-in',
    disposition,
    status: contractStatus,
    promotionReady,
    mismatchClass: contractStatus === 'pass' ? 'none' : 'missing-required-contexts',
    recurrenceClassification: contractStatus === 'pass' ? 'clean' : 'unknown',
    consecutiveSuccess,
    threshold: 10,
    evidence: {
      contractReportPath: contractPath,
      sessionIndexV1Path: path.join(root, 'session-index.json'),
      sessionIndexV2Path: path.join(root, 'session-index-v2.json'),
      policyPath: 'tools/policy/branch-required-checks.json'
    }
  });

  writeMarkdown(
    consumerMatrixPath,
    `# Session Index v2 Consumer Migration Matrix

## Matrix

| Consumer | Area | v2-first status | v1 fallback | Notes |
| --- | --- | --- | --- | --- |
${(consumerRows ?? [
      {
        consumer: '.github/actions/session-index-post/action.yml',
        area: 'CI post-processing summary',
        v2FirstStatus: '`v2-first-ready`',
        v1Fallback: '✅',
        notes: 'Reads session-index-v2.json first.'
      },
      {
        consumer: 'tools/Write-SessionIndexSummary.ps1',
        area: 'Step summary reporting',
        v2FirstStatus: '`v2-first-ready`',
        v1Fallback: '✅',
        notes: 'Uses shared reader module.'
      }
    ])
      .map(
        (row) =>
          `| ${row.consumer} | ${row.area} | ${row.v2FirstStatus} | ${row.v1Fallback} | ${row.notes} |`
      )
      .join('\n')}

## Burn-in tracking
`
  );

  const checklistLines = remainingChecklistItems.length === 0
    ? ['- [x] Remove v1 generation from producer paths/workflows.']
    : remainingChecklistItems.map((item) => `- [ ] ${item}`);
  writeMarkdown(
    deprecationPath,
    `# Session Index v1 Deprecation Policy

## Removal checklist
${checklistLines.join('\n')}

## Evidence package required for cutover
`
  );

  return { contractPath, dispositionPath, consumerMatrixPath, deprecationPath, outputPath };
}

function invokeCutoverTool(fixture) {
  const result = spawnSync(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-File',
      scriptPath,
      '-ContractReportPath',
      fixture.contractPath,
      '-DispositionReportPath',
      fixture.dispositionPath,
      '-ConsumerMatrixPath',
      fixture.consumerMatrixPath,
      '-DeprecationPolicyPath',
      fixture.deprecationPath,
      '-OutputPath',
      fixture.outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: { ...process.env, GITHUB_OUTPUT: '', GITHUB_STEP_SUMMARY: '' }
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);
  return loadJson(fixture.outputPath);
}

test('session-index-v2 cutover readiness schema validates generated ready and pending artifacts', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-cutover-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const schema = loadJson(schemaPath);
  const ajv = createAjv();
  const validate = ajv.compile(schema);

  const pendingFixture = createFixture(tmpDir, 'pending', {
    promotionReady: false,
    consecutiveSuccess: 4,
    contractStatus: 'pass',
    disposition: 'clean-burn-in',
    remainingChecklistItems: ['Remove v1 generation from producer paths/workflows.']
  });
  const pendingReport = invokeCutoverTool(pendingFixture);
  assert.equal(validate(pendingReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(pendingReport.status, 'not-ready');

  const readyFixture = createFixture(tmpDir, 'ready', {
    promotionReady: true,
    consecutiveSuccess: 10,
    contractStatus: 'pass',
    disposition: 'promotion-ready',
    remainingChecklistItems: []
  });
  const readyReport = invokeCutoverTool(readyFixture);
  assert.equal(validate(readyReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(readyReport.status, 'ready');
});

test('session-index-v2 cutover readiness schema validates generated consumer-not-ready artifacts', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-cutover-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const schema = loadJson(schemaPath);
  const ajv = createAjv();
  const validate = ajv.compile(schema);

  const notReadyFixture = createFixture(tmpDir, 'consumer-not-ready', {
    promotionReady: true,
    consecutiveSuccess: 10,
    contractStatus: 'pass',
    disposition: 'promotion-ready',
    remainingChecklistItems: [],
    consumerRows: [
      {
        consumer: '.github/actions/session-index-post/action.yml',
        area: 'CI post-processing summary',
        v2FirstStatus: '`v2-first-ready`',
        v1Fallback: '✅',
        notes: 'Reads session-index-v2.json first.'
      },
      {
        consumer: 'tools/Write-SessionIndexSummary.ps1',
        area: 'Step summary reporting',
        v2FirstStatus: 'v2-first ready',
        v1Fallback: '✅',
        notes: 'Near-match token is not enough for cutover.'
      }
    ]
  });
  const notReadyReport = invokeCutoverTool(notReadyFixture);
  assert.equal(validate(notReadyReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(notReadyReport.status, 'not-ready');
  assert.equal(notReadyReport.consumerMatrix.readyConsumerCount, 1);
  assert.equal(notReadyReport.consumerMatrix.allV2FirstReady, false);
});

test('session-index-v2 cutover readiness schema validates generated case-variant artifacts as not-ready', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-cutover-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const schema = loadJson(schemaPath);
  const ajv = createAjv();
  const validate = ajv.compile(schema);

  const notReadyFixture = createFixture(tmpDir, 'consumer-case-variant', {
    promotionReady: true,
    consecutiveSuccess: 10,
    contractStatus: 'pass',
    disposition: 'promotion-ready',
    remainingChecklistItems: [],
    consumerRows: [
      {
        consumer: '.github/actions/session-index-post/action.yml',
        area: 'CI post-processing summary',
        v2FirstStatus: '`v2-first-ready`',
        v1Fallback: '✅',
        notes: 'Reads session-index-v2.json first.'
      },
      {
        consumer: 'tools/Write-SessionIndexSummary.ps1',
        area: 'Step summary reporting',
        v2FirstStatus: '`V2-FIRST-READY`',
        v1Fallback: '✅',
        notes: 'Case-variant token is not enough for cutover.'
      }
    ]
  });
  const notReadyReport = invokeCutoverTool(notReadyFixture);
  assert.equal(validate(notReadyReport), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(notReadyReport.status, 'not-ready');
  assert.equal(notReadyReport.consumerMatrix.readyConsumerCount, 1);
  assert.equal(notReadyReport.consumerMatrix.allV2FirstReady, false);
});

test('session-index-v2 cutover readiness schema rejects contradictory ready projections', async () => {
  const schema = loadJson(schemaPath);
  const ajv = createAjv();
  const validate = ajv.compile(schema);

  const contradictory = {
    schema: 'session-index-v2-cutover-readiness@v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    status: 'ready',
    cutoverReady: true,
    promotionGate: {
      promotionReady: false,
      threshold: 10,
      consecutiveSuccess: 4,
      burnInStatus: 'ok',
      contractStatus: 'pass',
      disposition: 'clean-burn-in'
    },
    consumerRegressionGuard: {
      threshold: 5,
      consecutiveSuccess: 4,
      status: 'pending',
      reason: 'Only 4 consecutive successful runs are recorded; 5 are required.'
    },
    consumerMatrix: {
      path: 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md',
      criticalConsumerCount: 2,
      readyConsumerCount: 1,
      allV2FirstReady: true,
      notReadyConsumers: []
    },
    deprecationChecklist: {
      path: 'docs/SESSION_INDEX_V1_DEPRECATION.md',
      remainingCount: 1,
      remainingItems: ['Remove v1 generation from producer paths/workflows.'],
      completedItems: []
    },
    evidence: {
      contractReportPath: 'tests/results/session-index-v2-contract.json',
      dispositionReportPath: 'tests/results/session-index-v2-disposition.json',
      consumerMatrixPath: 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md',
      deprecationPolicyPath: 'docs/SESSION_INDEX_V1_DEPRECATION.md'
    },
    reasons: ['Promotion gate is not ready (4/10 consecutive successful runs).']
  };

  assert.equal(validate(contradictory), false);
});
