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
const modulePath = path.join(repoRoot, 'tools', 'priority', 'validation-approval-proof.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

function readDevelopRequiredChecks() {
  const payload = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'), 'utf8'),
  );
  return payload.branches.develop;
}

function createSuccessRollup(contexts) {
  return contexts.map((name) => ({
    __typename: 'CheckRun',
    name,
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
  }));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('validation approval proof report validates schema', async (t) => {
  const { runValidationApprovalProof } = await loadModule();
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'validation-approval-proof-v1.schema.json'), 'utf8'),
  );
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'validation-approval-proof-schema-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const requiredChecks = createSuccessRollup(readDevelopRequiredChecks());
  const reportPath = path.join(tmpDir, 'proof.json');
  const result = await runValidationApprovalProof({
    argv: [
      'node',
      'validation-approval-proof.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--policy',
      path.join(repoRoot, 'tools', 'policy', 'validation-approval-policy.json'),
      '--max-deployments',
      '1',
      '--min-samples',
      '1',
      '--lookback-days',
      '2',
      '--artifacts-dir',
      path.join(tmpDir, 'artifacts'),
      '--report',
      reportPath,
    ],
    now: new Date('2026-03-08T08:30:00.000Z'),
    repoRoot,
    runGhJsonFn(args) {
      if (args[0] === 'api' && String(args[1]).includes('/deployments?environment=')) {
        return [
          {
            id: 4201,
            sha: 'cccccccccccccccccccccccccccccccccccccccc',
            ref: 'issue/902-test',
            created_at: '2026-03-08T08:10:00.000Z',
          },
        ];
      }
      if (args[0] === 'api' && /\/deployments\/4201\/statuses$/.test(args[1])) {
        return [
          {
            id: 1,
            state: 'waiting',
            created_at: '2026-03-08T08:10:10.000Z',
            target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7101/job/1',
          },
          {
            id: 2,
            state: 'success',
            created_at: '2026-03-08T08:11:10.000Z',
            target_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7101/job/1',
          },
        ];
      }
      if (args[0] === 'api' && /\/actions\/runs\/7101$/.test(args[1])) {
        return {
          id: 7101,
          name: 'Validate',
          path: '.github/workflows/validate.yml',
          html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/7101',
          head_branch: 'issue/902-test',
          head_sha: 'cccccccccccccccccccccccccccccccccccccccc',
          event: 'pull_request',
          status: 'completed',
          conclusion: 'success',
          created_at: '2026-03-08T08:10:00.000Z',
          updated_at: '2026-03-08T08:12:00.000Z',
        };
      }
      if (args[0] === 'api' && args.at(-1) === 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/commits/cccccccccccccccccccccccccccccccccccccccc/pulls') {
        return [
          {
            number: 902,
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/902',
            state: 'closed',
            merged_at: '2026-03-08T08:20:00.000Z',
            head: { ref: 'issue/902-test', sha: 'cccccccccccccccccccccccccccccccccccccccc' },
            base: { ref: 'develop' },
          },
        ];
      }
      if (args[0] === 'pr' && args[1] === 'view' && args[2] === '902') {
        return {
          number: 902,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/902',
          isDraft: false,
          headRefOid: 'cccccccccccccccccccccccccccccccccccccccc',
          headRefName: 'issue/902-test',
          baseRefName: 'develop',
          headRepositoryOwner: { login: 'labview-community-ci-cd' },
          isCrossRepository: false,
          mergeStateStatus: 'CLEAN',
          statusCheckRollup: requiredChecks,
        };
      }
      throw new Error(`Unexpected gh invocation: ${args.join(' ')}`);
    },
    runSignalCollectorFn({ outPath }) {
      writeJson(outPath, {
        schema: 'priority/copilot-review-signal@v1',
        schemaVersion: '1.0.0',
        generatedAt: '2026-03-08T08:00:00.000Z',
        status: 'pass',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        reviewState: 'clean',
        pullRequest: {
          number: 902,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/902',
          state: 'closed',
          draft: false,
          headSha: 'cccccccccccccccccccccccccccccccccccccccc',
          headRef: 'issue/902-test',
          baseRef: 'develop',
          author: 'svelderrainruiz',
          updatedAt: '2026-03-08T08:00:00.000Z',
        },
        summary: {
          copilotReviewCount: 1,
          currentHeadReviewCount: 1,
          staleReviewCount: 0,
          unresolvedThreadCount: 0,
          actionableThreadCount: 0,
          actionableCommentCount: 0,
          staleThreadCount: 0,
          suppressedNotesObservedInLatestReview: false,
          suppressedNoteCountInLatestReview: null,
        },
        signals: {
          hasCopilotReview: true,
          hasCurrentHeadReview: true,
          hasStaleReview: false,
          hasUnresolvedThreads: false,
          hasActionableComments: false,
          hasSuppressedNotesInLatestReview: false,
        },
        latestCopilotReview: {
          id: '3900000902',
          state: 'COMMENTED',
          commitId: 'cccccccccccccccccccccccccccccccccccccccc',
          submittedAt: '2026-03-08T08:00:00.000Z',
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/902#pullrequestreview-3900000902',
          isCurrentHead: true,
          suppressedNotesObserved: false,
          suppressedNoteCount: null,
          bodySummary: 'Historical replay fixture',
        },
        staleReviews: [],
        unresolvedThreads: [],
        actionableComments: [],
        errors: [],
      });
    },
    downloadArtifactFn({ runId, destination }) {
      writeJson(path.join(destination, 'validation-deployment-determinism.json'), {
        schema: 'priority/deployment-determinism@v1',
        generatedAt: '2026-03-08T08:00:00.000Z',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        environment: 'validation',
        runId: String(runId),
        result: 'pass',
        issues: [],
      });
      return true;
    },
  });

  assert.equal(result.exitCode, 0);
  const report = JSON.parse(await readFile(reportPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.schema, 'validation-approval-proof@v1');
  assert.equal(report.summary.samplesEvaluated, 1);
});
