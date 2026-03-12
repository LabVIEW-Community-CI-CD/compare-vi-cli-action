import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'validation-approval-broker.mjs');

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

function readDevelopRequiredChecks() {
  const policy = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'), 'utf8'),
  );
  return policy.branches.develop;
}

function createSuccessRollup(contexts) {
  return contexts.map((name) => ({
    __typename: 'CheckRun',
    name,
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
  }));
}

function createSignal(headSha, prNumber, reviewRun = null) {
  return {
    schema: 'priority/copilot-review-signal@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'pass',
    reviewState: 'clean',
    pullRequest: {
      number: prNumber,
      url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
      headSha,
    },
    signals: {
      hasCurrentHeadReview: true,
    },
    reviewRun: reviewRun ?? {
      workflowName: 'Copilot code review',
      runId: null,
      event: null,
      status: null,
      conclusion: null,
      url: null,
      headSha,
      headBranch: `issue/${prNumber}-test`,
      createdAt: null,
      updatedAt: null,
      isCurrentHead: false,
      observationState: 'unobserved',
    },
    summary: {
      actionableCommentCount: 0,
      unresolvedThreadCount: 0,
      staleReviewCount: 0,
    },
    errors: [],
  };
}

function createAttestation(headSha, prNumber, actionableCommentCount = 0, unresolvedThreadCount = 0) {
  return {
    schema: 'validation-agent-attestation@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pullRequest: {
      number: prNumber,
      headSha,
    },
    reviewSignal: {
      actionableCommentCount,
      unresolvedThreadCount,
    },
    dispositions: {
      threads: Array.from({ length: unresolvedThreadCount }, (_, index) => ({
        threadId: `thread-${index + 1}`,
      })),
      comments: Array.from({ length: actionableCommentCount }, (_, index) => ({
        commentId: `comment-${index + 1}`,
      })),
    },
    validationEvidence: {
      commands: [
        {
          command: 'node --test tools/priority/__tests__/validation-approval-broker.test.mjs',
          status: 'passed',
        },
      ],
      checks: [
        {
          name: 'shadow-broker',
          status: 'passed',
        },
      ],
    },
  };
}

function createDeploymentDeterminism(result = 'pass', issues = []) {
  return {
    schema: 'priority/deployment-determinism@v1',
    environment: 'validation',
    result,
    issues,
    runId: '12345',
  };
}

function createPullContext({
  headSha,
  prNumber,
  headOwner = 'labview-community-ci-cd',
  headRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  isCrossRepository = false,
  statusCheckRollup,
}) {
  return {
    number: prNumber,
    url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
    isDraft: false,
    headRefOid: headSha,
    headRefName: `issue/${prNumber}-test`,
    baseRefName: 'develop',
    headRepository: {
      nameWithOwner: headRepository,
    },
    headRepositoryOwner: {
      login: headOwner,
    },
    isCrossRepository,
    mergeStateStatus: 'CLEAN',
    statusCheckRollup,
  };
}

test('validation approval broker returns ready for trusted clean inputs', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-ready-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const prNumber = 865;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');
  const outPath = path.join(tmpDir, 'decision.json');
  const eventsPath = path.join(tmpDir, 'events.ndjson');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
      '--out',
      outPath,
      '--events-out',
      eventsPath,
    ],
    now: new Date('2026-03-08T08:00:00Z'),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.decision.state, 'ready');
  assert.deepEqual(result.report?.decision.reasons, ['approval-ready']);

  const lines = (await readFile(eventsPath, 'utf8')).trim().split(/\r?\n/);
  assert.ok(lines.length >= 2);
  const firstEvent = JSON.parse(lines[0]);
  assert.equal(firstEvent.schema, 'comparevi/runtime-event/v1');
});

test('validation approval broker accepts a fresh current-head Copilot review even when the initial review remains as stale history', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-stale-and-current-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'abababababababababababababababababababab';
  const prNumber = 8651;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(signalPath, {
    ...createSignal(headSha, prNumber),
    summary: {
      actionableCommentCount: 0,
      unresolvedThreadCount: 0,
      staleReviewCount: 1,
    },
  });
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:00:30Z'),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.decision.state, 'ready');
  assert.deepEqual(result.report?.decision.reasons, ['approval-ready']);
  assert.equal(result.report?.providers.reviewSignal.staleReviewCount, 1);
  assert.equal(result.report?.providers.reviewSignal.hasCurrentHeadReview, true);
});

test('validation approval broker accepts a completed clean Copilot review run for the current head when no current-head review object was emitted', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-run-clean-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'afafafafafafafafafafafafafafafafafafafaf';
  const prNumber = 8652;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(
    signalPath,
    {
      ...createSignal(headSha, prNumber, {
        workflowName: 'Copilot code review',
        runId: 94001,
        event: 'pull_request',
        status: 'COMPLETED',
        conclusion: 'SUCCESS',
        url: 'https://github.com/example/actions/runs/94001',
        headSha,
        headBranch: `issue/${prNumber}-test`,
        createdAt: '2026-03-08T08:00:00.000Z',
        updatedAt: '2026-03-08T08:01:00.000Z',
        isCurrentHead: true,
        observationState: 'completed-clean',
      }),
      signals: {
        hasCurrentHeadReview: false,
      },
      summary: {
        actionableCommentCount: 0,
        unresolvedThreadCount: 0,
        staleReviewCount: 1,
      },
      latestCopilotReview: {
        id: 'stale-1',
        state: 'COMMENTED',
        commitId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        submittedAt: '2026-03-08T07:50:00.000Z',
        url: 'https://github.com/example/review/stale-1',
        isCurrentHead: false,
        bodySummary: 'Older stale review.',
      },
    },
  );
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:01:30Z'),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report?.decision.state, 'ready');
  assert.deepEqual(result.report?.decision.reasons, ['approval-ready']);
  assert.equal(result.report?.providers.reviewSignal.hasCurrentHeadReview, false);
  assert.equal(result.report?.providers.reviewSignal.reviewRunCompletedClean, true);
});

test('validation approval broker blocks when required checks are not ready', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-blocked-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const prNumber = 866;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks().filter((name) => name !== 'agent-review-policy')),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:01:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'blocked');
  assert.ok(result.report?.decision.reasons.includes('required-checks-not-ready'));
  assert.ok(result.report?.providers.requiredChecks.missing.includes('agent-review-policy'));
});

test('validation approval broker denies untrusted cross-repository contexts', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-denied-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'cccccccccccccccccccccccccccccccccccccccc';
  const prNumber = 867;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      headOwner: 'external-contributor',
      isCrossRepository: true,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:02:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'denied');
  assert.ok(result.report?.decision.reasons.includes('cross-repository-disallowed'));
});

test('validation approval broker denies repository mismatch when cross-repository heads are otherwise allowed', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-repository-mismatch-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'edededededededededededededededededededed';
  const prNumber = 869;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');
  const policyPath = path.join(tmpDir, 'policy.json');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      headRepository: 'LabVIEW-Community-CI-CD/comparevi-history',
      isCrossRepository: true,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );
  writeJson(policyPath, {
    schema: 'validation-approval-policy/v1',
    schemaVersion: '1.0.0',
    environment: 'validation',
    shadowMode: true,
    allowedBaseRefs: ['develop'],
    trust: {
      requireRepositoryMatch: true,
      allowCrossRepository: true,
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
  });

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--policy',
      policyPath,
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:02:30Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'denied');
  assert.ok(result.report?.decision.reasons.includes('repository-mismatch'));
  assert.deepEqual(result.report?.providers.trustContext.denialReasons, ['repository-mismatch']);
});

test('validation approval broker fails closed when a required provider is unavailable', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-fail-closed-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'dddddddddddddddddddddddddddddddddddddddd';
  const prNumber = 868;
  const signalPath = path.join(tmpDir, 'signal.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      path.join(tmpDir, 'missing-attestation.json'),
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:03:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'blocked');
  assert.ok(result.report?.decision.reasons.includes('agent-attestation-unavailable'));
  assert.equal(result.report?.providers.agentAttestation.available, false);
});

test('validation approval broker reports specific attestation review-signal mismatch blockers', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-mismatch-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  const prNumber = 869;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');

  writeJson(signalPath, {
    ...createSignal(headSha, prNumber),
    summary: {
      actionableCommentCount: 2,
      unresolvedThreadCount: 1,
      staleReviewCount: 0,
    },
  });
  writeJson(attestationPath, createAttestation(headSha, prNumber, 1, 0));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:04:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'blocked');
  assert.ok(result.report?.decision.reasons.includes('attestation-actionable-comment-count-mismatch'));
  assert.ok(result.report?.decision.reasons.includes('attestation-unresolved-thread-count-mismatch'));
  assert.equal(result.report?.decision.reasons.includes('attestation-review-signal-mismatch'), false);
});

test('validation approval broker uses built-in fail-closed policy when requested and default policy loads both fail', async (t) => {
  const { DEFAULT_POLICY_PATH, runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-policy-fallback-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const headSha = 'ffffffffffffffffffffffffffffffffffffffff';
  const prNumber = 870;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');
  const requestedPolicyPath = path.join(tmpDir, 'missing-policy.json');

  writeJson(signalPath, createSignal(headSha, prNumber));
  writeJson(attestationPath, createAttestation(headSha, prNumber));
  writeJson(deploymentPath, createDeploymentDeterminism());
  writeJson(
    pullPath,
    createPullContext({
      headSha,
      prNumber,
      statusCheckRollup: createSuccessRollup(readDevelopRequiredChecks()),
    }),
  );

  const readJsonFn = (filePath) => {
    if (filePath === requestedPolicyPath) {
      throw new Error('requested policy missing');
    }
    if (filePath === DEFAULT_POLICY_PATH) {
      throw new Error('default policy missing');
    }
    return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
  };

  const result = await runValidationApprovalBroker({
    argv: [
      'node',
      'validation-approval-broker.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      String(prNumber),
      '--policy',
      requestedPolicyPath,
      '--signal',
      signalPath,
      '--attestation',
      attestationPath,
      '--deployment-determinism',
      deploymentPath,
      '--pull-file',
      pullPath,
    ],
    now: new Date('2026-03-08T08:05:00Z'),
    readJsonFn,
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report?.decision.state, 'blocked');
  assert.ok(result.report?.decision.reasons.includes('policy-unavailable'));
  assert.ok(result.report?.decision.reasons.includes('default-policy-unavailable'));
  assert.equal(result.report?.policy.path, 'builtin:validation-approval-policy');
  assert.equal(result.report?.policy.shadowMode, true);
  assert.ok(result.report?.decision.notes.includes('requested policy missing'));
  assert.ok(result.report?.decision.notes.includes('default policy missing'));
});
