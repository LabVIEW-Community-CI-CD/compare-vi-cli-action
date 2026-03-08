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
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'copilot-review-signal.js');

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

test('copilot review signal schema validates a generated artifact with stale and actionable seams', async (t) => {
  const { runCopilotReviewSignal } = await loadModule();
  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'copilot-review-signal-v1.schema.json'), 'utf8'),
  );

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'copilot-review-signal-schema-'));
  t.after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  const reportPath = path.join(tmpDir, 'copilot-review-signal.json');
  const headSha = 'ffffffffffffffffffffffffffffffffffffffff';
  const staleSha = '1111111111111111111111111111111111111111';

  const result = runCopilotReviewSignal({
    argv: [
      'node',
      'copilot-review-signal.js',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '863',
      '--out',
      reportPath,
    ],
    now: new Date('2026-03-08T05:30:00Z'),
    loadPullFn: () => ({
      number: 863,
      html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/863',
      state: 'OPEN',
      draft: false,
      updated_at: '2026-03-08T05:29:00Z',
      user: { login: 'svelderrainruiz' },
      head: { sha: headSha, ref: 'issue/863-copilot-review-signal' },
      base: {
        ref: 'develop',
        repo: { full_name: 'LabVIEW-Community-CI-CD/compare-vi-cli-action' },
      },
    }),
    loadReviewsFn: () => ([
      {
        id: 10,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Latest current-head review with one actionable thread.',
        html_url: 'https://github.com/example/review/10',
        submitted_at: '2026-03-08T05:29:30Z',
        commit_id: headSha,
      },
      {
        id: 9,
        user: { login: 'copilot-pull-request-reviewer[bot]' },
        state: 'COMMENTED',
        body: 'Older stale review body.',
        html_url: 'https://github.com/example/review/9',
        submitted_at: '2026-03-08T05:20:00Z',
        commit_id: staleSha,
      },
    ]),
    loadThreadsFn: () => ({
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              nodes: [
                {
                  id: 'PRRT_schema_1',
                  isResolved: false,
                  isOutdated: false,
                  path: 'tools/priority/dispatch-validate.mjs',
                  line: 378,
                  originalLine: 362,
                  comments: {
                    nodes: [
                      {
                        id: 'PRRC_schema_1',
                        body: 'Whitespace-only sample ids should generate a new correlation id.',
                        publishedAt: '2026-03-08T05:29:40Z',
                        url: 'https://github.com/example/comment/schema-1',
                        author: { login: 'copilot-pull-request-reviewer' },
                        pullRequestReview: {
                          databaseId: 10,
                          state: 'COMMENTED',
                          author: { login: 'copilot-pull-request-reviewer' },
                          submittedAt: '2026-03-08T05:29:30Z',
                          commit: { oid: headSha },
                        },
                      },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    }),
  });

  assert.equal(result.exitCode, 0);

  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);

  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.schema, 'priority/copilot-review-signal@v1');
  assert.equal(report.summary.staleReviewCount, 1);
  assert.equal(report.summary.actionableCommentCount, 1);
});
