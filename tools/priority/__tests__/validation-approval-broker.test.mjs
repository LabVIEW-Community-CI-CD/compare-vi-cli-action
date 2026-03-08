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

function createSignal(headSha, prNumber) {
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

function createPullContext({ headSha, prNumber, headOwner = 'labview-community-ci-cd', isCrossRepository = false, statusCheckRollup }) {
  return {
    number: prNumber,
    url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
    isDraft: false,
    headRefOid: headSha,
    headRefName: `issue/${prNumber}-test`,
    baseRefName: 'develop',
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
  assert.deepEqual(result.report?.decision.reasons, ['approval-ready-shadow-mode']);

  const lines = (await readFile(eventsPath, 'utf8')).trim().split(/\r?\n/);
  assert.ok(lines.length >= 2);
  const firstEvent = JSON.parse(lines[0]);
  assert.equal(firstEvent.schema, 'comparevi/runtime-event/v1');
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
