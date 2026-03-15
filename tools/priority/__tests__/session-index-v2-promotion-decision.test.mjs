import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'session-index-v2-promotion-decision.mjs');
const reportSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'session-index-v2-promotion-decision-v1.schema.json');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function createAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

function createArtifactBundle(tmpDir, name, { promotionReady, cutoverReady, requiredCheckName = 'session-index-v2-contract' }) {
  const root = path.join(tmpDir, name);
  fs.mkdirSync(root, { recursive: true });

  writeJson(path.join(root, 'session-index-v2-contract.json'), {
    schema: 'session-index-v2-contract/v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    status: 'pass',
    enforce: false,
    failures: [],
    notes: [],
    branchProtection: {
      policyPath: 'tools/policy/branch-required-checks.json',
      requiredContexts: ['lint', requiredCheckName],
      missingContexts: []
    },
    burnIn: {
      threshold: 10,
      status: 'ok',
      reason: 'queried',
      consecutiveSuccess: promotionReady ? 10 : 4,
      inspectedRuns: promotionReady ? 10 : 4,
      promotionReady
    },
    burnInReceipt: {
      schema: 'session-index-v2-burn-in-receipt@v1',
      mode: 'burn-in',
      status: 'clean',
      mismatchClass: 'none',
      mismatchFingerprint: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      mismatchSummary: [],
      recurrence: {
        classification: 'clean',
        burnInStatus: 'ok',
        consecutiveSuccess: promotionReady ? 10 : 4
      },
      evidence: {
        reportPath: path.join(root, 'session-index-v2-contract.json'),
        resultsDir: root,
        sessionIndexV1Path: path.join(root, 'session-index.json'),
        sessionIndexV2Path: path.join(root, 'session-index-v2.json'),
        policyPath: 'tools/policy/branch-required-checks.json'
      }
    }
  });

  writeJson(path.join(root, 'session-index-v2-disposition.json'), {
    schema: 'session-index-v2-disposition-summary@v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    branch: 'develop',
    mode: 'burn-in',
    disposition: promotionReady ? 'promotion-ready' : 'clean-burn-in',
    status: 'pass',
    promotionReady,
    mismatchClass: 'none',
    recurrenceClassification: 'clean',
    consecutiveSuccess: promotionReady ? 10 : 4,
    threshold: 10,
    evidence: {
      contractReportPath: path.join(root, 'session-index-v2-contract.json'),
      sessionIndexV1Path: path.join(root, 'session-index.json'),
      sessionIndexV2Path: path.join(root, 'session-index-v2.json'),
      policyPath: 'tools/policy/branch-required-checks.json'
    }
  });

  writeJson(path.join(root, 'session-index-v2-cutover-readiness.json'), {
    schema: 'session-index-v2-cutover-readiness@v1',
    generatedAtUtc: '2026-03-15T00:00:00.000Z',
    status: cutoverReady ? 'ready' : 'not-ready',
    cutoverReady,
    promotionGate: {
      promotionReady,
      threshold: 10,
      consecutiveSuccess: promotionReady ? 10 : 4,
      burnInStatus: 'ok',
      contractStatus: 'pass',
      disposition: promotionReady ? 'promotion-ready' : 'clean-burn-in'
    },
    consumerRegressionGuard: {
      threshold: 5,
      consecutiveSuccess: promotionReady ? 5 : 2,
      status: cutoverReady ? 'satisfied' : 'pending',
      reason: cutoverReady ? '5 consecutive upstream runs without consumer regressions recorded.' : 'Consumer regression guard is still accumulating evidence.'
    },
    consumerMatrix: {
      path: 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md',
      criticalConsumerCount: 6,
      readyConsumerCount: 6,
      allV2FirstReady: true,
      notReadyConsumers: []
    },
    deprecationChecklist: {
      path: 'docs/SESSION_INDEX_V1_DEPRECATION.md',
      remainingCount: cutoverReady ? 0 : 2,
      remainingItems: cutoverReady ? [] : ['Remove v1 generation from producer paths/workflows.', 'Publish final cutover report with evidence links.'],
      completedItems: cutoverReady ? ['Remove v1 generation from producer paths/workflows.'] : []
    },
    evidence: {
      contractReportPath: path.join(root, 'session-index-v2-contract.json'),
      dispositionReportPath: path.join(root, 'session-index-v2-disposition.json'),
      consumerMatrixPath: 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md',
      deprecationPolicyPath: 'docs/SESSION_INDEX_V1_DEPRECATION.md'
    },
    reasons: cutoverReady ? [] : ['Promotion gate is not ready (4/10 consecutive successful runs).']
  });

  return root;
}

function createValidateRun(databaseId, headBranch, overrides = {}) {
  return {
    databaseId,
    name: 'Validate',
    headBranch,
    headSha: overrides.headSha ?? `sha-${databaseId}`,
    event: overrides.event ?? 'push',
    status: overrides.status ?? 'completed',
    conclusion: overrides.conclusion ?? 'success',
    createdAt: overrides.createdAt ?? '2026-03-15T09:00:00Z',
    updatedAt: overrides.updatedAt ?? '2026-03-15T09:10:00Z',
  };
}

async function copyBundleDownload({ artifactRoot, destinationRoot, reportPath, artifactName, now }) {
  const destination = path.join(destinationRoot, encodeURIComponent(artifactName));
  fs.cpSync(artifactRoot, destination, { recursive: true });
  const files = [];
  const walk = (currentPath) => {
    for (const entry of fs.readdirSync(currentPath, { withFileTypes: true })) {
      const fullPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
        continue;
      }
      if (entry.isFile()) {
        files.push(path.relative(destination, fullPath));
      }
    }
  };
  walk(destination);
  const report = {
    schema: 'priority/run-artifact-download@v1',
    generatedAt: new Date(now).toISOString(),
    status: 'pass',
    discovery: {
      status: 'pass',
      failureClass: null,
      availableArtifacts: [{ name: artifactName }]
    },
    downloads: [
      {
        name: artifactName,
        status: 'downloaded',
        failureClass: null,
        destination,
        files,
      }
    ],
    summary: {
      requestedArtifactCount: 1,
      availableArtifactCount: 1,
      downloadedCount: 1,
      missingCount: 0,
      failedCount: 0,
    },
    errors: [],
  };
  writeJson(reportPath, report);
  return { reportPath, report };
}
test('parseArgs uses the injected environment instead of leaking repository defaults from process.env', async (t) => {
  const { parseArgs } = await loadModule();
  const isolatedRepoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-parseargs-'));
  t.after(() => fs.rmSync(isolatedRepoRoot, { recursive: true, force: true }));
  const priorRepository = process.env.GITHUB_REPOSITORY;
  t.after(() => {
    if (priorRepository === undefined) {
      delete process.env.GITHUB_REPOSITORY;
      return;
    }
    process.env.GITHUB_REPOSITORY = priorRepository;
  });
  process.env.GITHUB_REPOSITORY = 'global-owner/global-repo';

  assert.throws(
    () =>
      parseArgs(
        ['node', modulePath, '--workflow', 'validate.yml'],
        {},
        isolatedRepoRoot,
      ),
    /Repository is required/,
  );

  const parsed = parseArgs(
    ['node', modulePath, '--workflow', 'validate.yml'],
    { GITHUB_REPOSITORY: 'injected-owner/injected-repo' },
    isolatedRepoRoot,
  );
  assert.equal(parsed.repo, 'injected-owner/injected-repo');
});

test('parseArgs resolves the repository from the common git config in a worktree checkout', async (t) => {
  const { parseArgs } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-worktree-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const repoRoot = path.join(tmpDir, 'repo');
  const worktreeGitDir = path.join(tmpDir, '.git', 'worktrees', 'repo');
  const commonGitDir = path.join(tmpDir, '.git');
  fs.mkdirSync(repoRoot, { recursive: true });
  fs.mkdirSync(worktreeGitDir, { recursive: true });
  fs.writeFileSync(path.join(repoRoot, '.git'), `gitdir: ${worktreeGitDir}\n`, 'utf8');
  fs.writeFileSync(path.join(worktreeGitDir, 'commondir'), '..\\..\n', 'utf8');
  fs.writeFileSync(
    path.join(commonGitDir, 'config'),
    '[remote "upstream"]\n  url = https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git\n',
    'utf8',
  );

  const parsed = parseArgs(['node', modulePath], {}, repoRoot);
  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
});

test('runSessionIndexV2PromotionDecision reports ready-to-promote when evidence is ready and config is not applied', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-ready-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branchClassBindings: {
      develop: 'upstream-integration'
    },
    branchClassRequiredChecks: {
      'upstream-integration': ['lint', 'session-index']
    },
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const reportPath = path.join(tmpDir, 'report.json');
  const downloadReportPath = path.join(tmpDir, 'download.json');
  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--workflow',
      'validate.yml',
      '--policy',
      policyPath,
      '--out',
      reportPath,
      '--download-report',
      downloadReportPath,
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    now: new Date('2026-03-15T09:30:00.000Z'),
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [
            createValidateRun(42, 'develop', {
              headSha: 'abc123',
            }),
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'abc123';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.decision.state, 'ready-to-promote');
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.policy.requiredCheckPolicy.hasCheck, false);
  assert.equal(result.report.policy.branchProtection.hasCheck, false);

  const schema = loadJson(reportSchemaPath);
  const ajv = createAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(loadJson(reportPath)), true, JSON.stringify(validate.errors, null, 2));
});

test('runSessionIndexV2PromotionDecision reports promotion-config-drift when config is enabled before evidence is ready', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-drift-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: false,
    cutoverReady: false,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index', 'session-index-v2-contract']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [
            createValidateRun(43, 'develop', {
              headSha: 'def456',
            }),
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'set',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: 'true',
        enabled: true,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index', 'session-index-v2-contract'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'def456';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.equal(result.report.status, 'fail');
});

test('runSessionIndexV2PromotionDecision reports missing-evidence when the latest run does not publish the artifact bundle', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-missing-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [
            createValidateRun(44, 'develop', {
              headSha: 'ghi789',
            }),
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      const report = {
        schema: 'priority/run-artifact-download@v1',
        generatedAt: new Date(options.now).toISOString(),
        status: 'fail',
        discovery: {
          status: 'pass',
          failureClass: null,
          availableArtifacts: [],
        },
        downloads: [
          {
            name: options.artifactNames[0],
            status: 'missing',
            failureClass: 'artifact-not-found',
            destination: path.join(options.destinationRoot, encodeURIComponent(options.artifactNames[0])),
            files: [],
            errorMessage: 'Artifact validate-session-index-v2-contract was not found for run 44.',
          }
        ],
        summary: {
          requestedArtifactCount: 1,
          availableArtifactCount: 0,
          downloadedCount: 0,
          missingCount: 1,
          failedCount: 0,
        },
        errors: ['Artifact validate-session-index-v2-contract was not found for run 44.'],
      };
      writeJson(options.reportPath, report);
      return { reportPath: options.reportPath, report };
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'ghi789';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.decision.state, 'missing-evidence');
  assert.equal(result.report.status, 'warn');
});

test('runSessionIndexV2PromotionDecision fails closed when repo config queries are unreadable', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-config-error-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(45, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'error',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: 'gh api rate limit',
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-45';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.equal(result.report.status, 'fail');
  assert.match(result.report.decision.summary, /could not be read deterministically/i);
});

test('runSessionIndexV2PromotionDecision requires live branch protection before reporting already-enforced', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-live-protection-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index', 'session-index-v2-contract']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(46, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'set',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: 'true',
        enabled: true,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'unavailable',
        contexts: [],
        notes: ['Branch protection required status checks not configured for this branch.'],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-46';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.equal(result.report.status, 'fail');
  assert.match(result.report.decision.reasons.join('\n'), /not configured/i);
});

test('runSessionIndexV2PromotionDecision only trusts files listed in the current download report', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-current-files-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const currentBundle = createArtifactBundle(tmpDir, 'current', {
    promotionReady: true,
    cutoverReady: true,
  });
  const staleBundle = createArtifactBundle(tmpDir, 'stale', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(47, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      const destination = path.join(options.destinationRoot, encodeURIComponent(options.artifactNames[0]));
      fs.mkdirSync(destination, { recursive: true });
      fs.copyFileSync(
        path.join(currentBundle, 'session-index-v2-contract.json'),
        path.join(destination, 'session-index-v2-contract.json'),
      );
      fs.copyFileSync(
        path.join(currentBundle, 'session-index-v2-disposition.json'),
        path.join(destination, 'session-index-v2-disposition.json'),
      );
      fs.copyFileSync(
        path.join(staleBundle, 'session-index-v2-cutover-readiness.json'),
        path.join(destination, 'session-index-v2-cutover-readiness.json'),
      );
      const report = {
        schema: 'priority/run-artifact-download@v1',
        generatedAt: new Date(options.now).toISOString(),
        status: 'pass',
        discovery: {
          status: 'pass',
          failureClass: null,
          availableArtifacts: [{ name: options.artifactNames[0] }],
        },
        downloads: [
          {
            name: options.artifactNames[0],
            status: 'downloaded',
            failureClass: null,
            destination,
            files: ['session-index-v2-contract.json', 'session-index-v2-disposition.json'],
          }
        ],
        summary: {
          requestedArtifactCount: 1,
          availableArtifactCount: 1,
          downloadedCount: 1,
          missingCount: 0,
          failedCount: 0,
        },
        errors: [],
      };
      writeJson(options.reportPath, report);
      return { reportPath: options.reportPath, report };
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-47';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.decision.state, 'missing-evidence');
  assert.equal(result.report.status, 'warn');
  assert.match(result.report.decision.reasons.join('\n'), /Cutover readiness report is missing/);
});

test('runSessionIndexV2PromotionDecision paginates workflow runs until it finds the latest matching develop run', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-pagination-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  let pageCount = 0;
  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('branch=develop') && /(?:\?|&)page=1(?:&|$)/.test(args[1])) {
        pageCount += 1;
        return {
          workflow_runs: Array.from({ length: 100 }, (_, index) =>
            createValidateRun(index + 100, 'develop', {
              updatedAt: `2026-03-15T08:${String(index % 60).padStart(2, '0')}:00Z`,
            }),
          ),
        };
      }
      if (args[0] === 'api' && args[1].includes('branch=develop') && /(?:\?|&)page=2(?:&|$)/.test(args[1])) {
        pageCount += 1;
        return {
          workflow_runs: [createValidateRun(48, 'develop', { updatedAt: '2026-03-15T09:59:00Z' })],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-48';
    },
  });

  assert.equal(pageCount, 2);
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.sourceRun.id, 48);
  assert.equal(result.report.decision.state, 'ready-to-promote');
});

test('runSessionIndexV2PromotionDecision deterministically breaks same-timestamp ties by run id', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-tiebreak-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [
            createValidateRun(53, 'develop', { headSha: 'shared-head', updatedAt: '2026-03-15T09:10:00Z' }),
            createValidateRun(54, 'develop', { headSha: 'shared-head', updatedAt: '2026-03-15T09:10:00Z' }),
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'shared-head';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.sourceRun.id, 54);
});

test('runSessionIndexV2PromotionDecision writes a fail report when policy loading throws', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-policy-error-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const reportPath = path.join(tmpDir, 'report.json');
  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.join(tmpDir, 'missing-policy.json'),
      '--out',
      reportPath,
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(49, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async getBranchHeadShaFn() {
      return 'sha-49';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.equal(fs.existsSync(reportPath), true);
  assert.match(loadJson(reportPath).decision.summary, /could not be resolved deterministically/i);
});

test('runSessionIndexV2PromotionDecision fails closed when enforcement is enabled but current evidence is missing', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-missing-drift-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index', 'session-index-v2-contract']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(55, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      const report = {
        schema: 'priority/run-artifact-download@v1',
        generatedAt: new Date(options.now).toISOString(),
        status: 'fail',
        discovery: {
          status: 'pass',
          failureClass: null,
          availableArtifacts: [],
        },
        downloads: [
          {
            name: options.artifactNames[0],
            status: 'missing',
            failureClass: 'artifact-not-found',
            destination: path.join(options.destinationRoot, encodeURIComponent(options.artifactNames[0])),
            files: [],
            errorMessage: 'Artifact validate-session-index-v2-contract was not found for run 55.',
          }
        ],
        summary: {
          requestedArtifactCount: 1,
          availableArtifactCount: 0,
          downloadedCount: 0,
          missingCount: 1,
          failedCount: 0,
        },
        errors: ['Artifact validate-session-index-v2-contract was not found for run 55.'],
      };
      writeJson(options.reportPath, report);
      return { reportPath: options.reportPath, report };
    },
    async getRepositoryVariableFn() {
      return {
        status: 'set',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: 'true',
        enabled: true,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index', 'session-index-v2-contract'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-55';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.equal(result.report.status, 'fail');
});

test('runSessionIndexV2PromotionDecision rejects explicit runs that do not match the requested branch', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-explicit-run-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '50',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].endsWith('/actions/runs/50')) {
        return {
          id: 50,
          databaseId: 50,
          name: 'Validate',
          path: '.github/workflows/validate.yml@refs/heads/develop',
          headBranch: 'feature/not-develop',
          headSha: 'explicit-sha',
          status: 'completed',
          conclusion: 'success',
          createdAt: '2026-03-15T09:00:00Z',
          updatedAt: '2026-03-15T09:10:00Z',
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async getBranchHeadShaFn() {
      return 'explicit-current-sha';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'invalid-evidence');
  assert.equal(result.report.selection.failureClass, 'run-mismatch');
  assert.match(result.report.evidence.errors.join('\n'), /does not match develop/i);
});

test('runSessionIndexV2PromotionDecision rejects explicit runs from a stale branch head', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-explicit-stale-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '57',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].endsWith('/actions/runs/57')) {
        return {
          id: 57,
          databaseId: 57,
          name: 'Validate',
          path: '.github/workflows/validate.yml@refs/heads/develop',
          headBranch: 'develop',
          headSha: 'stale-sha',
          status: 'completed',
          conclusion: 'success',
          createdAt: '2026-03-15T09:00:00Z',
          updatedAt: '2026-03-15T09:10:00Z',
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async getBranchHeadShaFn() {
      return 'current-sha';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.selection.failureClass, 'run-mismatch');
  assert.match(result.report.evidence.errors.join('\n'), /does not match current branch head/i);
});

test('runSessionIndexV2PromotionDecision rejects contradictory disposition evidence', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-contradiction-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });
  writeJson(path.join(artifactRoot, 'session-index-v2-disposition.json'), {
    ...loadJson(path.join(artifactRoot, 'session-index-v2-disposition.json')),
    disposition: 'clean-burn-in',
    promotionReady: false,
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(51, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-51';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'invalid-evidence');
  assert.equal(result.report.status, 'fail');
  assert.match(result.report.evidence.errors.join('\n'), /Disposition promotionReady does not match contract/);
});

test('runSessionIndexV2PromotionDecision recognizes ruleset-only enforcement as already-enforced', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-ruleset-enforced-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const testRepoRoot = path.join(tmpDir, 'repo');
  const schemaDir = path.join(testRepoRoot, 'docs', 'schemas');
  const policyPath = path.join(testRepoRoot, 'tools', 'policy', 'branch-required-checks.json');
  const priorityPolicyPath = path.join(testRepoRoot, 'tools', 'priority', 'policy.json');
  fs.mkdirSync(schemaDir, { recursive: true });
  fs.mkdirSync(path.dirname(policyPath), { recursive: true });
  fs.mkdirSync(path.dirname(priorityPolicyPath), { recursive: true });
  for (const schemaFile of [
    'session-index-v2-contract-v1.schema.json',
    'session-index-v2-disposition-summary-v1.schema.json',
    'session-index-v2-cutover-readiness-v1.schema.json',
  ]) {
    fs.copyFileSync(path.join(repoRoot, 'docs', 'schemas', schemaFile), path.join(schemaDir, schemaFile));
  }
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index', 'session-index-v2-contract']
    }
  });
  writeJson(priorityPolicyPath, {
    rulesets: {
      develop: {
        name: 'develop',
        includes: ['refs/heads/develop']
      }
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.relative(testRepoRoot, policyPath),
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot: testRepoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(56, 'develop')],
        };
      }
      if (args[0] === 'api' && args[1].includes('/branches/develop/protection')) {
        throw new Error('404 Not Found');
      }
      if (args[0] === 'api' && args[1].includes('/rulesets') && !/\/rulesets\/\d+$/.test(args[1])) {
        return [{ id: 8811898, name: 'develop' }];
      }
      if (args[0] === 'api' && args[1].endsWith('/rulesets/8811898')) {
        return {
          id: 8811898,
          name: 'develop',
          rules: [
            {
              type: 'required_status_checks',
              parameters: {
                required_status_checks: [
                  { context: 'lint' },
                  { context: 'session-index' },
                  { context: 'session-index-v2-contract' },
                ],
              },
            },
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'set',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: 'true',
        enabled: true,
        errorMessage: null,
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-56';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.decision.state, 'already-enforced');
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.policy.branchProtection.hasCheck, true);
});

test('runSessionIndexV2PromotionDecision reports missing-evidence when the current head has no completed run yet', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-head-fallback-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const policyPath = path.join(tmpDir, 'branch-required-checks.json');
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      policyPath,
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [
            createValidateRun(58, 'develop', { headSha: 'previous-head', updatedAt: '2026-03-15T09:10:00Z' }),
          ],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn() {
      throw new Error('downloadArtifactsFn should not run when no current-head run is available');
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'current-head-without-completed-run';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.sourceRun, null);
  assert.equal(result.report.decision.state, 'missing-evidence');
  assert.equal(result.report.status, 'warn');
});

test('runSessionIndexV2PromotionDecision fails closed when priority policy required checks drift ahead of branch-required-check projection', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-policy-drift-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const testRepoRoot = path.join(tmpDir, 'repo');
  const branchRequiredChecksPath = path.join(testRepoRoot, 'tools', 'policy', 'branch-required-checks.json');
  const priorityPolicyPath = path.join(testRepoRoot, 'tools', 'priority', 'policy.json');
  const schemaDir = path.join(testRepoRoot, 'docs', 'schemas');
  fs.mkdirSync(path.dirname(branchRequiredChecksPath), { recursive: true });
  fs.mkdirSync(path.dirname(priorityPolicyPath), { recursive: true });
  fs.mkdirSync(schemaDir, { recursive: true });
  for (const schemaFile of [
    'session-index-v2-contract-v1.schema.json',
    'session-index-v2-disposition-summary-v1.schema.json',
    'session-index-v2-cutover-readiness-v1.schema.json',
  ]) {
    fs.copyFileSync(path.join(repoRoot, 'docs', 'schemas', schemaFile), path.join(schemaDir, schemaFile));
  }
  writeJson(branchRequiredChecksPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });
  writeJson(priorityPolicyPath, {
    branches: {
      develop: {
        required_status_checks: ['lint', 'session-index', 'session-index-v2-contract']
      }
    }
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.relative(testRepoRoot, branchRequiredChecksPath),
      '--out',
      path.join(tmpDir, 'report.json'),
      '--download-report',
      path.join(tmpDir, 'download.json'),
      '--destination-root',
      path.join(tmpDir, 'downloads'),
    ],
    repoRoot: testRepoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(59, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-59';
    },
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.decision.state, 'promotion-config-drift');
  assert.match(result.report.decision.summary, /required-check policy surfaces disagree/i);
});

test('runSessionIndexV2PromotionDecision resolves relative report paths from repoRoot instead of process.cwd()', async (t) => {
  const { runSessionIndexV2PromotionDecision } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'session-index-promotion-reporoot-'));

  const testRepoRoot = path.join(tmpDir, 'repo');
  const nestedCwd = path.join(testRepoRoot, 'nested', 'cwd');
  fs.mkdirSync(nestedCwd, { recursive: true });
  const artifactRoot = createArtifactBundle(tmpDir, 'artifact', {
    promotionReady: true,
    cutoverReady: true,
  });
  const schemaDir = path.join(testRepoRoot, 'docs', 'schemas');
  fs.mkdirSync(schemaDir, { recursive: true });
  for (const schemaFile of [
    'session-index-v2-contract-v1.schema.json',
    'session-index-v2-disposition-summary-v1.schema.json',
    'session-index-v2-cutover-readiness-v1.schema.json',
  ]) {
    fs.copyFileSync(path.join(repoRoot, 'docs', 'schemas', schemaFile), path.join(schemaDir, schemaFile));
  }

  const policyPath = path.join(testRepoRoot, 'tools', 'policy', 'branch-required-checks.json');
  fs.mkdirSync(path.dirname(policyPath), { recursive: true });
  writeJson(policyPath, {
    schema: 'branch-required-checks/v1',
    schemaVersion: '1.0.0',
    branches: {
      develop: ['lint', 'session-index']
    }
  });

  const priorCwd = process.cwd();
  process.chdir(nestedCwd);
  t.after(() => {
    process.chdir(priorCwd);
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const result = await runSessionIndexV2PromotionDecision({
    argv: [
      'node',
      modulePath,
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.relative(testRepoRoot, policyPath),
      '--out',
      path.join('tests', 'results', '_agent', 'session-index-v2', 'report.json'),
      '--download-report',
      path.join('tests', 'results', '_agent', 'session-index-v2', 'download.json'),
      '--destination-root',
      path.join('tests', 'results', '_agent', 'session-index-v2', 'downloads'),
    ],
    repoRoot: testRepoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && args[1].includes('/actions/workflows/validate.yml/runs?')) {
        return {
          workflow_runs: [createValidateRun(52, 'develop')],
        };
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    async downloadArtifactsFn(options) {
      return copyBundleDownload({
        artifactRoot,
        destinationRoot: options.destinationRoot,
        reportPath: options.reportPath,
        artifactName: options.artifactNames[0],
        now: options.now,
      });
    },
    async getRepositoryVariableFn() {
      return {
        status: 'unset',
        name: 'SESSION_INDEX_V2_CONTRACT_ENFORCE',
        value: null,
        enabled: false,
        errorMessage: null,
      };
    },
    async getBranchProtectionFn() {
      return {
        status: 'available',
        contexts: ['lint', 'session-index'],
        notes: [],
      };
    },
    async getBranchHeadShaFn() {
      return 'sha-52';
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.reportPath, path.join(testRepoRoot, 'tests', 'results', '_agent', 'session-index-v2', 'report.json'));
  assert.equal(
    result.report.artifact.destinationRoot,
    path.join(testRepoRoot, 'tests', 'results', '_agent', 'session-index-v2', 'downloads', '52'),
  );
});
