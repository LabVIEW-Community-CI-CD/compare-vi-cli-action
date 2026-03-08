import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

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

test('validation approval decision schema validates a generated ready artifact', async (t) => {
  const { runValidationApprovalBroker } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-broker-schema-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const branchPolicy = JSON.parse(
    await readFile(path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'), 'utf8'),
  );
  const requiredChecks = branchPolicy.branches.develop;
  const headSha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  const prNumber = 869;
  const signalPath = path.join(tmpDir, 'signal.json');
  const attestationPath = path.join(tmpDir, 'attestation.json');
  const deploymentPath = path.join(tmpDir, 'deployment.json');
  const pullPath = path.join(tmpDir, 'pull.json');
  const outPath = path.join(tmpDir, 'decision.json');

  writeJson(signalPath, {
    schema: 'priority/copilot-review-signal@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'pass',
    reviewState: 'clean',
    pullRequest: {
      number: prNumber,
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
  });
  writeJson(attestationPath, {
    schema: 'validation-agent-attestation@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pullRequest: {
      number: prNumber,
      headSha,
    },
    reviewSignal: {
      actionableCommentCount: 0,
      unresolvedThreadCount: 0,
    },
    dispositions: {
      threads: [],
      comments: [],
    },
    validationEvidence: {
      commands: [
        {
          command: 'node tools/npm/run-script.mjs priority:validation:broker',
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
  });
  writeJson(deploymentPath, {
    schema: 'priority/deployment-determinism@v1',
    environment: 'validation',
    result: 'pass',
    issues: [],
    runId: '54321',
  });
  writeJson(pullPath, {
    number: prNumber,
    url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
    isDraft: false,
    headRefOid: headSha,
    headRefName: 'issue/869-shadow-broker',
    baseRefName: 'develop',
    headRepositoryOwner: {
      login: 'labview-community-ci-cd',
    },
    isCrossRepository: false,
    mergeStateStatus: 'CLEAN',
    statusCheckRollup: requiredChecks.map((name) => ({
      __typename: 'CheckRun',
      name,
      status: 'COMPLETED',
      conclusion: 'SUCCESS',
    })),
  });

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
    ],
    now: new Date('2026-03-08T08:04:00Z'),
  });

  assert.equal(result.exitCode, 0);

  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'validation-approval-decision-v1.schema.json'),
      'utf8',
    ),
  );
  const payload = JSON.parse(await readFile(outPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.schema, 'validation-approval-decision@v1');
  assert.equal(payload.decision.state, 'ready');
});
