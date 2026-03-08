import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

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

test('validation-agent-attestation schema validates a generated attestation artifact', async (t) => {
  const { runValidationAgentAttestation } = await loadModule();
  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'validation-agent-attestation-v1.schema.json'),
      'utf8',
    ),
  );

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-agent-attestation-schema-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const signalPath = path.join(tmpDir, 'signal.json');
  const dispositionsPath = path.join(tmpDir, 'dispositions.json');
  const evidencePath = path.join(tmpDir, 'validation-evidence.json');
  const outPath = path.join(tmpDir, 'validation-agent-attestation.json');

  writeJson(signalPath, {
    schema: 'priority/copilot-review-signal@v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'pass',
    reviewState: 'attention',
    pullRequest: {
      number: 864,
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/864',
      headSha: 'cccccccccccccccccccccccccccccccccccccccc',
    },
    latestCopilotReview: {
      id: '3912000002',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/864#pullrequestreview-3912000002',
      submittedAt: '2026-03-08T05:45:00Z',
      state: 'COMMENTED',
      isCurrentHead: true,
    },
    summary: {
      unresolvedThreadCount: 1,
      actionableCommentCount: 1,
      staleReviewCount: 0,
    },
    unresolvedThreads: [
      {
        threadId: 'PRRT_schema_attest_1',
        path: 'tools/priority/validation-agent-attestation.ts',
        line: 10,
        latestComment: {
          id: 'PRRC_schema_attest_thread_1',
          reviewId: '3912000002',
        },
      },
    ],
    actionableComments: [
      {
        id: 'PRRC_schema_attest_actionable_1',
        threadId: 'PRRT_schema_attest_1',
        reviewId: '3912000002',
      },
    ],
  });

  writeJson(dispositionsPath, {
    threads: [
      {
        threadId: 'PRRT_schema_attest_1',
        disposition: 'accepted',
        note: 'Reviewed and accepted.',
      },
    ],
    comments: [
      {
        commentId: 'PRRC_schema_attest_actionable_1',
        disposition: 'addressed',
        note: 'Handled in follow-up.',
      },
    ],
  });

  writeJson(evidencePath, {
    summary: 'Schema validation evidence.',
    commands: [
      {
        command: 'node tools/npm/run-script.mjs build',
        status: 'passed',
        exitCode: 0,
        details: 'Build succeeded.',
        artifactPath: null,
      },
    ],
    checks: [
      {
        name: 'schema',
        status: 'passed',
        details: 'Attestation payload validated.',
      },
    ],
    artifacts: [outPath],
    notes: ['Schema test artifact.'],
  });

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
    now: new Date('2026-03-08T05:46:00Z'),
  });

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.schema, 'validation-agent-attestation@v1');
  assert.equal(report.dispositions.threads[0].disposition, 'accepted');
});
