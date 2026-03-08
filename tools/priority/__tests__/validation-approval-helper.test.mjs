import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'validation-approval-helper.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function createReadyDecision({ prNumber = 866, headSha = 'a'.repeat(40), repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action' } = {}) {
  return {
    schema: 'validation-approval-decision@v1',
    schemaVersion: '1.0.0',
    generatedAt: '2026-03-08T08:30:00.000Z',
    status: 'pass',
    mode: 'evaluate',
    repository,
    environment: 'validation',
    pullRequest: {
      number: prNumber,
      url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
      isDraft: false,
      headSha,
      headRefName: `issue/${prNumber}-test`,
      baseRefName: 'develop',
      headRepositoryOwner: 'labview-community-ci-cd',
      isCrossRepository: false,
      mergeStateStatus: 'CLEAN',
    },
    policy: {
      schema: 'validation-approval-policy/v1',
      schemaVersion: '1.0.0',
      path: 'tools/policy/validation-approval-policy.json',
      shadowMode: true,
      allowedBaseRefs: ['develop'],
      trust: {
        requireRepositoryMatch: true,
        allowCrossRepository: false,
        allowedHeadOwners: ['labview-community-ci-cd'],
      },
      providers: {
        requireReviewSignal: true,
        requireAgentAttestation: true,
        requireDeploymentDeterminism: true,
        requireRequiredChecks: true,
      },
      attestation: {
        requireValidationEvidencePass: true,
        requireDispositionsForActionableComments: true,
        requireDispositionsForUnresolvedThreads: true,
      },
    },
    providers: {
      reviewSignal: {
        path: 'tests/results/_agent/reviews/copilot-review-signal.json',
        available: true,
        status: 'pass',
        reviewState: 'clean',
        headSha,
        pullRequestNumber: prNumber,
        hasCurrentHeadReview: true,
        actionableCommentCount: 0,
        unresolvedThreadCount: 0,
        staleReviewCount: 0,
        errorCount: 0,
      },
      agentAttestation: {
        path: 'tests/results/_agent/reviews/validation-agent-attestation.json',
        available: true,
        repository,
        pullRequestNumber: prNumber,
        headSha,
        reviewSignalActionableCommentCount: 0,
        reviewSignalUnresolvedThreadCount: 0,
        threadDispositionCount: 0,
        commentDispositionCount: 0,
        failedEvidenceCount: 0,
        commandFailureCount: 0,
        checkFailureCount: 0,
      },
      deploymentDeterminism: {
        path: 'tests/results/_agent/deployments/validation-deployment-determinism.json',
        available: true,
        environment: 'validation',
        result: 'pass',
        issueCount: 0,
        issues: [],
        runId: '12345',
      },
      trustContext: {
        trusted: true,
        repository,
        targetOwner: 'labview-community-ci-cd',
        baseRef: 'develop',
        headOwner: 'labview-community-ci-cd',
        isCrossRepository: false,
        denialReasons: [],
      },
      requiredChecks: {
        policyPath: 'tools/policy/branch-required-checks.json',
        baseRef: 'develop',
        mergeStateStatus: 'CLEAN',
        required: ['lint'],
        missing: [],
        failing: [],
        ready: true,
      },
    },
    decision: {
      state: 'ready',
      ready: true,
      blockers: [],
      denials: [],
      reasons: ['approval-ready-shadow-mode'],
      notes: [],
      summary: 'All required broker inputs are trusted and ready. Shadow mode only; no approval was performed.',
    },
    artifacts: {
      decisionPath: 'tests/results/_agent/approvals/validation-approval-decision.json',
      eventsPath: 'tests/results/_agent/approvals/validation-approval-events.ndjson',
    },
  };
}

function createRunGhJsonStub({
  runId = 12345,
  prNumber = 866,
  runHeadSha = 'a'.repeat(40),
  prHeadSha = runHeadSha,
  pendingDeployments = [{ environment: { id: 9667872140, name: 'validation' }, current_user_can_approve: true }],
  runName = 'Validate',
}) {
  const calls = [];
  const fn = (args) => {
    calls.push([...args]);
    if (args[0] === 'api' && args[1] === `repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/${runId}`) {
      return {
        id: runId,
        name: runName,
        path: '.github/workflows/validate.yml',
        html_url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/${runId}`,
        head_branch: `issue/${prNumber}-test`,
        head_sha: runHeadSha,
        status: 'waiting',
        conclusion: null,
      };
    }
    if (args[0] === 'api' && args[1] === `repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/${runId}/pending_deployments` && !args.includes('--method')) {
      return pendingDeployments;
    }
    if (args[0] === 'pr' && args[1] === 'view') {
      return {
        number: prNumber,
        url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
        state: 'OPEN',
        isDraft: false,
        headRefOid: prHeadSha,
        headRefName: `issue/${prNumber}-test`,
      };
    }
    if (args[0] === 'api' && args[1] === `repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/${runId}/pending_deployments` && args.includes('--method')) {
      return { state: 'approved', environment_ids: [9667872140] };
    }
    throw new Error(`Unexpected gh invocation: ${args.join(' ')}`);
  };
  return { fn, calls };
}

test('validation approval helper consumes a ready decision and approves the validation deployment', async (t) => {
  const { runValidationApprovalHelper } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-helper-consume-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const decisionPath = path.join(tmpDir, 'incoming-decision.json');
  const decisionOutPath = path.join(tmpDir, 'decision.json');
  const reportPath = path.join(tmpDir, 'helper-report.json');
  writeJson(decisionPath, createReadyDecision());

  const gh = createRunGhJsonStub({});
  const result = await runValidationApprovalHelper({
    argv: [
      'node',
      'validation-approval-helper.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '12345',
      '--decision',
      decisionPath,
      '--decision-out',
      decisionOutPath,
      '--out',
      reportPath,
      '--approve',
    ],
    now: new Date('2026-03-08T08:31:00Z'),
    runGhJsonFn: gh.fn,
    appendStepSummaryFn: async () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.status, 'pass');
  assert.equal(result.report?.approval.state, 'approved');
  assert.equal(result.report?.approval.performed, true);
  assert.deepEqual(result.report?.approval.environmentIds, [9667872140]);
  assert.ok(
    gh.calls.some(
      (args) =>
        args[0] === 'api' &&
        args[1] === 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/12345/pending_deployments' &&
        args.includes('--method') &&
        args.includes('state=approved'),
    ),
  );
  assert.equal(JSON.parse(fs.readFileSync(decisionOutPath, 'utf8')).schema, 'validation-approval-decision@v1');
});

test('validation approval helper denies non-validation target environments', async (t) => {
  const { runValidationApprovalHelper } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-helper-env-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const decisionPath = path.join(tmpDir, 'incoming-decision.json');
  const reportPath = path.join(tmpDir, 'helper-report.json');
  writeJson(decisionPath, createReadyDecision());

  const gh = createRunGhJsonStub({});
  const result = await runValidationApprovalHelper({
    argv: [
      'node',
      'validation-approval-helper.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '12345',
      '--environment',
      'production',
      '--decision',
      decisionPath,
      '--out',
      reportPath,
      '--approve',
    ],
    now: new Date('2026-03-08T08:32:00Z'),
    runGhJsonFn: gh.fn,
    appendStepSummaryFn: async () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'denied');
  assert.ok(result.report?.decision.reasons.includes('environment-not-allowed'));
  assert.ok(
    !gh.calls.some(
      (args) =>
        args[0] === 'api' &&
        args[1] === 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/12345/pending_deployments' &&
        args.includes('--method'),
    ),
  );
});

test('validation approval helper refuses stale pull request head combinations', async (t) => {
  const { runValidationApprovalHelper } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-helper-stale-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const decisionPath = path.join(tmpDir, 'incoming-decision.json');
  writeJson(decisionPath, createReadyDecision({ headSha: 'a'.repeat(40) }));

  const gh = createRunGhJsonStub({
    runHeadSha: 'a'.repeat(40),
    prHeadSha: 'b'.repeat(40),
  });
  const result = await runValidationApprovalHelper({
    argv: [
      'node',
      'validation-approval-helper.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '12345',
      '--decision',
      decisionPath,
      '--out',
      path.join(tmpDir, 'helper-report.json'),
      '--approve',
    ],
    now: new Date('2026-03-08T08:33:00Z'),
    runGhJsonFn: gh.fn,
    appendStepSummaryFn: async () => {},
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'blocked');
  assert.ok(result.report?.decision.reasons.includes('pull-request-head-mismatch'));
  assert.equal(result.report?.approval.performed, false);
});

test('validation approval helper can evaluate the broker before checking the target run', async (t) => {
  const { runValidationApprovalHelper } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-helper-evaluate-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const decisionOutPath = path.join(tmpDir, 'decision.json');
  const brokerCalls = [];
  const gh = createRunGhJsonStub({});
  const result = await runValidationApprovalHelper({
    argv: [
      'node',
      'validation-approval-helper.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '12345',
      '--pr',
      '866',
      '--signal',
      path.join(tmpDir, 'signal.json'),
      '--attestation',
      path.join(tmpDir, 'attestation.json'),
      '--deployment-determinism',
      path.join(tmpDir, 'deployment.json'),
      '--decision-out',
      decisionOutPath,
      '--out',
      path.join(tmpDir, 'helper-report.json'),
    ],
    now: new Date('2026-03-08T08:34:00Z'),
    runGhJsonFn: gh.fn,
    runBrokerFn: (args) => {
      brokerCalls.push([...args]);
      writeJson(decisionOutPath, createReadyDecision());
      return { status: 0, stdout: '', stderr: '', error: null };
    },
    appendStepSummaryFn: async () => {},
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.source.mode, 'evaluate');
  assert.equal(result.report?.source.brokerExitCode, 0);
  assert.ok(
    brokerCalls.some((args) => args.includes('--signal') && args.includes('--attestation') && args.includes('--deployment-determinism')),
  );
  assert.ok(brokerCalls.some((args) => args.includes('--environment') && args.includes('validation')));
});
