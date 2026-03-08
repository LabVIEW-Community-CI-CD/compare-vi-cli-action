import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(
  repoRoot,
  'dist',
  'tools',
  'priority',
  'validation-agent-attestation.js',
);

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(
      buildResult.status,
      0,
      [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'),
    );
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }

  return builtModulePromise;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function makeSignal({
  prNumber = 864,
  headSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  reviewId = '3912000001',
  latestReview = undefined,
} = {}) {
  const review =
    latestReview === undefined
      ? {
          id: reviewId,
          url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}#pullrequestreview-${reviewId}`,
          submittedAt: '2026-03-08T05:40:00Z',
          state: 'COMMENTED',
          isCurrentHead: true,
        }
      : latestReview;

  return {
    schema: 'priority/copilot-review-signal@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'pass',
    reviewState: 'attention',
    pullRequest: {
      number: prNumber,
      url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/${prNumber}`,
      headSha,
    },
    latestCopilotReview: review,
    summary: {
      unresolvedThreadCount: 1,
      actionableCommentCount: 1,
      staleReviewCount: 0,
    },
    unresolvedThreads: [
      {
        threadId: 'PRRT_attest_1',
        path: 'tools/priority/dispatch-validate.mjs',
        line: 42,
        latestComment: {
          id: 'PRRC_attest_thread_1',
          reviewId: reviewId,
          snippet: 'Thread latest comment.',
        },
      },
    ],
    actionableComments: [
      {
        id: 'PRRC_attest_actionable_1',
        threadId: 'PRRT_attest_1',
        reviewId: reviewId,
        path: 'tools/priority/dispatch-validate.mjs',
        line: 42,
        snippet: 'Actionable comment.',
      },
    ],
  };
}

function makeDispositions() {
  return {
    threads: [
      {
        threadId: 'PRRT_attest_1',
        disposition: 'addressed',
        note: 'Handled in this validation pass.',
      },
    ],
    comments: [
      {
        commentId: 'PRRC_attest_actionable_1',
        disposition: 'addressed',
        note: 'Fixed in the latest commit.',
      },
    ],
  };
}

function makeValidationEvidence() {
  return {
    summary: 'Targeted validation completed successfully.',
    commands: [
      {
        command: 'node --test tools/priority/__tests__/validation-agent-attestation.test.mjs',
        status: 'passed',
        exitCode: 0,
        details: 'Targeted attestation contract tests.',
        artifactPath: 'tests/results/_agent/reviews/validation-agent-attestation.json',
      },
    ],
    checks: [
      {
        name: 'attestation-contract',
        status: 'passed',
        details: 'Local write path passed.',
      },
    ],
    artifacts: ['tests/results/_agent/reviews/validation-agent-attestation.json'],
    notes: ['Local offline attestation capture.'],
  };
}

test('validation-agent-attestation fails on head SHA mismatch', async (t) => {
  const { runValidationAgentAttestation } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-agent-attestation-mismatch-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const signalPath = path.join(tmpDir, 'signal.json');
  const dispositionsPath = path.join(tmpDir, 'dispositions.json');
  const evidencePath = path.join(tmpDir, 'validation-evidence.json');

  writeJson(signalPath, makeSignal());
  writeJson(dispositionsPath, makeDispositions());
  writeJson(evidencePath, makeValidationEvidence());

  const result = runValidationAgentAttestation({
    argv: [
      'node',
      'validation-agent-attestation.js',
      '--signal',
      signalPath,
      '--dispositions',
      dispositionsPath,
      '--validation-evidence',
      evidencePath,
      '--head-sha',
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    ],
    now: new Date('2026-03-08T05:41:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.match(result.error ?? '', /does not match signal head SHA/i);
  assert.equal(result.reportPath, null);
});

test('validation-agent-attestation fails when the Copilot review id is missing', async (t) => {
  const { runValidationAgentAttestation } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-agent-attestation-noreview-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const signalPath = path.join(tmpDir, 'signal.json');
  const dispositionsPath = path.join(tmpDir, 'dispositions.json');
  const evidencePath = path.join(tmpDir, 'validation-evidence.json');

  writeJson(
    signalPath,
    makeSignal({
      latestReview: null,
    }),
  );
  writeJson(dispositionsPath, makeDispositions());
  writeJson(evidencePath, makeValidationEvidence());

  const result = runValidationAgentAttestation({
    argv: [
      'node',
      'validation-agent-attestation.js',
      '--signal',
      signalPath,
      '--dispositions',
      dispositionsPath,
      '--validation-evidence',
      evidencePath,
    ],
    now: new Date('2026-03-08T05:42:00Z'),
  });

  assert.equal(result.exitCode, 1);
  assert.match(result.error ?? '', /Copilot review id is required/i);
  assert.equal(result.reportPath, null);
});

test('validation-agent-attestation writes a normalized attestation artifact', async (t) => {
  const { runValidationAgentAttestation } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-agent-attestation-write-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const signalPath = path.join(tmpDir, 'signal.json');
  const dispositionsPath = path.join(tmpDir, 'dispositions.json');
  const evidencePath = path.join(tmpDir, 'validation-evidence.json');
  const outPath = path.join(tmpDir, 'validation-agent-attestation.json');

  writeJson(signalPath, makeSignal());
  writeJson(dispositionsPath, makeDispositions());
  writeJson(evidencePath, makeValidationEvidence());

  const result = runValidationAgentAttestation({
    argv: [
      'node',
      'validation-agent-attestation.js',
      '--signal',
      signalPath,
      '--dispositions',
      dispositionsPath,
      '--validation-evidence',
      evidencePath,
      '--out',
      outPath,
    ],
    now: new Date('2026-03-08T05:43:00Z'),
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.reportPath, outPath);
  assert.equal(result.attestation?.schema, 'validation-agent-attestation@v1');
  assert.equal(result.attestation?.pullRequest.headSha, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  assert.equal(result.attestation?.dispositions.threads[0]?.latestCommentId, 'PRRC_attest_thread_1');
  assert.equal(result.attestation?.commentPost.posted, false);
  assert.ok(fs.existsSync(outPath));
});

test('validation-agent-attestation can post a PR comment shape with the signed-in identity', async (t) => {
  const { runValidationAgentAttestation } = await loadModule();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-agent-attestation-post-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const signalPath = path.join(tmpDir, 'signal.json');
  const dispositionsPath = path.join(tmpDir, 'dispositions.json');
  const evidencePath = path.join(tmpDir, 'validation-evidence.json');
  const outPath = path.join(tmpDir, 'validation-agent-attestation.json');

  writeJson(signalPath, makeSignal());
  writeJson(dispositionsPath, makeDispositions());
  writeJson(evidencePath, makeValidationEvidence());

  let posted = null;
  const result = runValidationAgentAttestation({
    argv: [
      'node',
      'validation-agent-attestation.js',
      '--signal',
      signalPath,
      '--dispositions',
      dispositionsPath,
      '--validation-evidence',
      evidencePath,
      '--out',
      outPath,
      '--post-comment',
    ],
    now: new Date('2026-03-08T05:44:00Z'),
    lookupCurrentLoginFn: () => 'svelderrainruiz',
    postCommentFn: (repo, prNumber, body) => {
      posted = { repo, prNumber, body };
    },
  });

  assert.equal(result.exitCode, 0);
  assert.deepEqual(posted?.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(posted?.prNumber, 864);
  assert.match(posted?.body ?? '', /Validation Agent Attestation/);
  assert.match(posted?.body ?? '', /3912000001/);
  assert.equal(result.attestation?.commentPost.actorLogin, 'svelderrainruiz');
  assert.equal(result.attestation?.commentPost.posted, true);
});
