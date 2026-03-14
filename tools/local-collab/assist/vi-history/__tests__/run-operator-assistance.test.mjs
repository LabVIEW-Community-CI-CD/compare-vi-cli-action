import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import {
  LOCAL_COLLAB_VI_HISTORY_ASSIST_LATEST_SCHEMA,
  LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA,
  assessLatestViHistoryOperatorAssistance,
  parseArgs,
  runViHistoryOperatorAssistance
} from '../run-operator-assistance.mjs';

async function createGitRepo() {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-collab-vi-history-assist-'));
  spawnSync('git', ['init', '--initial-branch=develop'], { cwd: repoRoot, encoding: 'utf8' });
  await mkdir(path.join(repoRoot, 'tools'), { recursive: true });
  await writeFile(path.join(repoRoot, 'tools', 'Compare-VIHistory.ps1'), '# placeholder', 'utf8');
  await writeFile(path.join(repoRoot, 'tools', 'Inspect-VIHistorySuiteArtifacts.ps1'), '# placeholder', 'utf8');
  await mkdir(path.join(repoRoot, 'fixtures', 'vi-attr'), { recursive: true });
  await writeFile(path.join(repoRoot, 'fixtures', 'vi-attr', 'Head.vi'), 'base', 'utf8');
  await writeFile(path.join(repoRoot, 'README.md'), '# root\n', 'utf8');
  spawnSync('git', ['add', '.'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  await writeFile(path.join(repoRoot, 'README.md'), '# root 2\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'docs only'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  await writeFile(path.join(repoRoot, 'fixtures', 'vi-attr', 'Head.vi'), 'touch-1', 'utf8');
  spawnSync('git', ['add', 'fixtures/vi-attr/Head.vi'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'touch vi'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  await mkdir(path.join(repoRoot, 'docs'), { recursive: true });
  await writeFile(path.join(repoRoot, 'docs', 'note.md'), 'note', 'utf8');
  spawnSync('git', ['add', 'docs/note.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'docs note'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  await writeFile(path.join(repoRoot, 'fixtures', 'vi-attr', 'Head.vi'), 'touch-2', 'utf8');
  spawnSync('git', ['add', 'fixtures/vi-attr/Head.vi'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'touch vi again'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  return repoRoot;
}

function createFakeCommandRunner(repoRoot) {
  return async ({ args }) => {
    const scriptPath = args[3];
    if (scriptPath.endsWith('Compare-VIHistory.ps1')) {
      const resultsDir = args[args.indexOf('-ResultsDir') + 1];
      const absoluteResultsDir = path.resolve(repoRoot, resultsDir);
      const historyReportMarkdownPath = path.join(absoluteResultsDir, 'history-report.md');
      const historyReportHtmlPath = path.join(absoluteResultsDir, 'history-report.html');
      const historySummaryPath = path.join(absoluteResultsDir, 'history-summary.json');
      const aggregateManifestPath = path.join(absoluteResultsDir, 'manifest.json');
      const historySummary = {
        schema: 'comparevi-tools/history-facade@v1',
        target: {
          path: 'fixtures/vi-attr/Head.vi',
          sourceBranchRef: 'HEAD',
          branchBudget: {
            maxCommitCount: 8,
            commitCount: 5,
            status: 'ok',
            reason: 'within-limit'
          }
        },
        execution: {
          status: 'ok',
          manifestPath: aggregateManifestPath
        },
        summary: {
          comparisons: 2,
          diffs: 1,
          signalDiffs: 1,
          errors: 0
        },
        reports: {
          markdownPath: historyReportMarkdownPath,
          htmlPath: historyReportHtmlPath
        }
      };
      await mkdir(absoluteResultsDir, { recursive: true });
      await writeFile(historyReportMarkdownPath, '# history report\n', 'utf8');
      await writeFile(historyReportHtmlPath, '<html><body>history</body></html>', 'utf8');
      await writeFile(historySummaryPath, JSON.stringify(historySummary, null, 2), 'utf8');
      await writeFile(
        aggregateManifestPath,
        JSON.stringify({ schema: 'vi-compare/history-suite@v1', stats: { processed: 2 } }, null, 2),
        'utf8'
      );
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    }

    if (scriptPath.endsWith('Inspect-VIHistorySuiteArtifacts.ps1')) {
      const outputJsonPath = args[args.indexOf('-OutputJsonPath') + 1];
      const outputHtmlPath = args[args.indexOf('-OutputHtmlPath') + 1];
      await writeFile(
        outputJsonPath,
        JSON.stringify(
          {
            schema: 'vi-history-suite-inspection@v1',
            overallStatus: 'ok',
            summary: {
              comparisons: 2,
              missingReports: 0
            }
          },
          null,
          2
        ),
        'utf8'
      );
      await writeFile(outputHtmlPath, '<html><body>inspection</body></html>', 'utf8');
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    }

    throw new Error(`Unexpected command invocation: ${args.join(' ')}`);
  };
}

async function runWithFakeCommands(repoRoot, options = {}) {
  return runViHistoryOperatorAssistance({
    repoRoot,
    targetPath: 'fixtures/vi-attr/Head.vi',
    branchRef: 'HEAD',
    maxBranchCommits: 8,
    maxPairs: 2,
    runCommandFn: createFakeCommandRunner(repoRoot),
    ...options
  });
}

test('parseArgs enforces bounded VI history assistance requests', () => {
  const parsed = parseArgs([
    'node',
    'run-operator-assistance.mjs',
    '--repo-root',
    '/tmp/repo',
    '--target-path',
    'fixtures/vi-attr/Head.vi',
    '--branch-ref',
    'HEAD',
    '--max-branch-commits',
    '16',
    '--max-pairs',
    '2'
  ]);

  assert.equal(parsed.repoRoot, '/tmp/repo');
  assert.equal(parsed.targetPath, 'fixtures/vi-attr/Head.vi');
  assert.equal(parsed.branchRef, 'HEAD');
  assert.equal(parsed.maxBranchCommits, 16);
  assert.equal(parsed.maxPairs, 2);
});

test('runViHistoryOperatorAssistance writes deterministic receipts and latest indexes', async () => {
  const repoRoot = await createGitRepo();
  const result = await runWithFakeCommands(repoRoot);

  assert.equal(result.receipt.schema, LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA);
  assert.equal(result.latestIndex.schema, LOCAL_COLLAB_VI_HISTORY_ASSIST_LATEST_SCHEMA);
  assert.equal(result.receipt.request.targetPath, 'fixtures/vi-attr/Head.vi');
  assert.equal(result.receipt.history.totalCommitsScanned, 5);
  assert.equal(result.receipt.history.touchingCommitCount, 3);
  assert.equal(result.receipt.history.selectedPairCount, 2);
  assert.equal(result.receipt.history.processedComparisons, 2);
  assert.equal(result.receipt.inspection.overallStatus, 'ok');
  assert.match(result.receipt.artifacts.historyReportMarkdownPath, /history-report\.md$/);
  assert.match(result.receipt.artifacts.suiteManifestPath, /suite-manifest\.json$/);

  const persistedReceipt = JSON.parse(await readFile(result.receiptPath, 'utf8'));
  const persistedLatest = JSON.parse(await readFile(result.latestIndexPath, 'utf8'));
  assert.equal(persistedReceipt.status, 'passed');
  assert.equal(persistedLatest.status, 'passed');

  const assessed = await assessLatestViHistoryOperatorAssistance({
    repoRoot,
    targetPath: 'fixtures/vi-attr/Head.vi',
    expectedHeadSha: result.receipt.git.headSha
  });
  assert.equal(assessed.ok, true);
  assert.equal(assessed.status, 'valid');
});

test('runViHistoryOperatorAssistance fails closed on stale head requests', async () => {
  const repoRoot = await createGitRepo();

  await assert.rejects(
    () =>
      runWithFakeCommands(repoRoot, {
        expectedHeadSha: 'deadbeef'
      }),
    /Stale VI history assistance request/
  );
});

test('runViHistoryOperatorAssistance fails closed when the bounded branch range does not touch the VI', async () => {
  const repoRoot = await createGitRepo();

  await assert.rejects(
    () =>
      runWithFakeCommands(repoRoot, {
        targetPath: 'README.md',
        baselineRef: 'HEAD~1'
      }),
    /No commits touching 'README\.md'/
  );
});

test('runViHistoryOperatorAssistance fails closed on missing targets', async () => {
  const repoRoot = await createGitRepo();

  await assert.rejects(
    () =>
      runWithFakeCommands(repoRoot, {
        targetPath: 'fixtures/vi-attr/Missing.vi'
      }),
    /VI history target not found/
  );
});

test('assessLatestViHistoryOperatorAssistance fails closed on corrupt latest indexes', async () => {
  const repoRoot = await createGitRepo();
  const latestIndexPath = path.join(
    repoRoot,
    'tests',
    'results',
    '_agent',
    'local-collab',
    'assist',
    'vi-history',
    'latest',
    'fixtures__vi-attr__Head-vi.json'
  );
  await mkdir(path.dirname(latestIndexPath), { recursive: true });
  await writeFile(latestIndexPath, '{not-json', 'utf8');

  const result = await assessLatestViHistoryOperatorAssistance({
    repoRoot,
    targetPath: 'fixtures/vi-attr/Head.vi',
    latestIndexPath
  });

  assert.equal(result.ok, false);
  assert.equal(result.status, 'invalid-index');
});
