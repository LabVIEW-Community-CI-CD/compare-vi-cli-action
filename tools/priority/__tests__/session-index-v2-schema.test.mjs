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
const contractScriptPath = path.join(repoRoot, 'tools', 'Test-SessionIndexV2Contract.ps1');
const contractSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'session-index-v2-contract-v1.schema.json');
const dispositionSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'session-index-v2-disposition-summary-v1.schema.json');
const cutoverSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'session-index-v2-cutover-readiness-v1.schema.json');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function createAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false, $data: true });
  addFormats(ajv);
  return ajv;
}

function createSessionIndexFixture(tmpDir, name, { expectedContexts, actualContexts = expectedContexts }) {
  const resultsDir = path.join(tmpDir, name);
  fs.mkdirSync(resultsDir, { recursive: true });

  writeJson(path.join(resultsDir, 'session-index.json'), {
    schema: 'session-index/v1'
  });

  writeJson(path.join(resultsDir, 'session-index-v2.json'), {
    schema: 'session-index/v2',
    schemaVersion: '1.0.0',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    run: {
      workflow: 'Validate'
    },
    branchProtection: {
      status: 'ok',
      reason: 'aligned',
      expected: [...expectedContexts],
      actual: [...actualContexts]
    },
    artifacts: [
      {
        name: 'session-index-v2',
        path: 'session-index-v2.json'
      }
    ]
  });

  return resultsDir;
}

function writePolicy(tmpDir, name, requiredContexts) {
  const policyPath = path.join(tmpDir, `${name}.policy.json`);
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: requiredContexts
    }
  });
  return policyPath;
}

function invokeContractTool(resultsDir, policyPath) {
  const env = { ...process.env };
  delete env.GH_TOKEN;
  delete env.GITHUB_TOKEN;
  delete env.GITHUB_OUTPUT;
  delete env.GITHUB_STEP_SUMMARY;

  const result = spawnSync(
    'pwsh',
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-File',
      contractScriptPath,
      '-ResultsDir',
      resultsDir,
      '-PolicyPath',
      policyPath,
      '-Branch',
      'develop',
      '-Owner',
      'example-owner',
      '-Repository',
      'example-repo'
    ],
    {
      cwd: repoRoot,
      env,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr || result.stdout);

  return {
    contract: loadJson(path.join(resultsDir, 'session-index-v2-contract.json')),
    disposition: loadJson(path.join(resultsDir, 'session-index-v2-disposition.json')),
    cutover: loadJson(path.join(resultsDir, 'session-index-v2-cutover-readiness.json'))
  };
}

test('session-index-v2 burn-in schemas validate generated clean and mismatch artifacts', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-v2-schema-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const contractSchema = loadJson(contractSchemaPath);
  const dispositionSchema = loadJson(dispositionSchemaPath);
  const cutoverSchema = loadJson(cutoverSchemaPath);
  const ajv = createAjv();
  const validateContract = ajv.compile(contractSchema);
  const validateDisposition = ajv.compile(dispositionSchema);
  const validateCutover = ajv.compile(cutoverSchema);

  const cleanResultsDir = createSessionIndexFixture(tmpDir, 'clean', {
    expectedContexts: ['lint', 'session-index']
  });
  const cleanPolicyPath = writePolicy(tmpDir, 'clean', ['lint', 'session-index']);
  const clean = invokeContractTool(cleanResultsDir, cleanPolicyPath);

  assert.equal(validateContract(clean.contract), true, JSON.stringify(validateContract.errors, null, 2));
  assert.equal(validateDisposition(clean.disposition), true, JSON.stringify(validateDisposition.errors, null, 2));
  assert.equal(validateCutover(clean.cutover), true, JSON.stringify(validateCutover.errors, null, 2));
  assert.equal(clean.contract.status, 'pass');
  assert.equal(clean.contract.burnInReceipt.mismatchClass, 'none');
  assert.equal(clean.disposition.disposition, 'clean-burn-in');
  assert.equal(clean.cutover.schema, 'session-index-v2-cutover-readiness@v1');

  const mismatchResultsDir = createSessionIndexFixture(tmpDir, 'mismatch', {
    expectedContexts: ['lint'],
    actualContexts: ['lint']
  });
  const mismatchPolicyPath = writePolicy(tmpDir, 'mismatch', ['lint', 'session-index']);
  const mismatch = invokeContractTool(mismatchResultsDir, mismatchPolicyPath);

  assert.equal(validateContract(mismatch.contract), true, JSON.stringify(validateContract.errors, null, 2));
  assert.equal(validateDisposition(mismatch.disposition), true, JSON.stringify(validateDisposition.errors, null, 2));
  assert.equal(validateCutover(mismatch.cutover), true, JSON.stringify(validateCutover.errors, null, 2));
  assert.equal(mismatch.contract.status, 'fail');
  assert.equal(mismatch.contract.burnInReceipt.mismatchClass, 'missing-required-contexts');
  assert.equal(mismatch.disposition.disposition, 'burn-in-mismatch');
  assert.equal(mismatch.cutover.status, 'not-ready');
});

test('session-index-v2 burn-in schemas reject contradictory status projections', async () => {
  const contractSchema = loadJson(contractSchemaPath);
  const dispositionSchema = loadJson(dispositionSchemaPath);
  const ajv = createAjv();
  const validateContract = ajv.compile(contractSchema);
  const validateDisposition = ajv.compile(dispositionSchema);

  const contradictoryContract = {
    schema: 'session-index-v2-contract/v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    status: 'pass',
    enforce: false,
    failures: ['branchProtection.expected missing required contexts: session-index'],
    notes: [],
    branchProtection: {
      policyPath: 'tools/policy/branch-required-checks.json',
      requiredContexts: ['lint', 'session-index'],
      missingContexts: ['session-index']
    },
    burnIn: {
      threshold: 10,
      status: 'unavailable',
      reason: 'missing_token',
      consecutiveSuccess: 0,
      inspectedRuns: 0,
      promotionReady: false
    },
    burnInReceipt: {
      schema: 'session-index-v2-burn-in-receipt@v1',
      mode: 'burn-in',
      status: 'mismatch',
      mismatchClass: 'missing-required-contexts',
      mismatchFingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      mismatchSummary: ['branchProtection.expected missing required contexts: session-index'],
      recurrence: {
        classification: 'unknown',
        burnInStatus: 'unavailable',
        consecutiveSuccess: 0
      },
      evidence: {
        reportPath: 'tests/results/session-index-v2-contract.json',
        resultsDir: 'tests/results',
        sessionIndexV1Path: 'tests/results/session-index.json',
        sessionIndexV2Path: 'tests/results/session-index-v2.json',
        policyPath: 'tools/policy/branch-required-checks.json'
      }
    }
  };

  const contradictoryDisposition = {
    schema: 'session-index-v2-disposition-summary@v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    mode: 'burn-in',
    disposition: 'clean-burn-in',
    status: 'fail',
    promotionReady: false,
    mismatchClass: 'missing-required-contexts',
    recurrenceClassification: 'unknown',
    consecutiveSuccess: 0,
    threshold: 10,
    evidence: {
      contractReportPath: 'tests/results/session-index-v2-contract.json',
      sessionIndexV1Path: 'tests/results/session-index.json',
      sessionIndexV2Path: 'tests/results/session-index-v2.json',
      policyPath: 'tools/policy/branch-required-checks.json'
    }
  };

  assert.equal(validateContract(contradictoryContract), false);
  assert.equal(validateDisposition(contradictoryDisposition), false);
});
