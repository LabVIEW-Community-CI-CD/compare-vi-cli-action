#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA = 'comparevi/local-collab-vi-history-assistance@v1';
export const LOCAL_COLLAB_VI_HISTORY_ASSIST_LATEST_SCHEMA = 'comparevi/local-collab-vi-history-assistance-latest@v1';
export const DEFAULT_LOCAL_COLLAB_VI_HISTORY_ASSIST_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'local-collab',
  'assist',
  'vi-history'
);
export const DEFAULT_COMPARE_VI_HISTORY_SCRIPT = path.join('tools', 'Compare-VIHistory.ps1');
export const DEFAULT_HISTORY_INSPECTOR_SCRIPT = path.join('tools', 'Inspect-VIHistorySuiteArtifacts.ps1');

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeInteger(value, fallback = 0) {
  if (Number.isInteger(value)) {
    return value;
  }
  const normalized = Number.parseInt(normalizeText(value), 10);
  return Number.isInteger(normalized) ? normalized : fallback;
}

function normalizePositiveInteger(value, name) {
  const normalized = normalizeInteger(value, Number.NaN);
  if (!Number.isInteger(normalized) || normalized <= 0) {
    throw new Error(`${name} must be a positive integer.`);
  }
  return normalized;
}

function normalizePathFragment(value, fallback = 'target') {
  const normalized = normalizeText(value)
    .replace(/\\/g, '/')
    .replace(/[^a-zA-Z0-9/_-]+/g, '-')
    .replace(/\/+/g, '/')
    .replace(/^-+|-+$/g, '')
    .replace(/^\/+|\/+$/g, '')
    .replace(/\//g, '__');
  return normalized || fallback;
}

function toRepoRelativePath(repoRoot, targetPath, description = 'path') {
  const absolutePath = path.resolve(targetPath);
  const relativePath = path.relative(repoRoot, absolutePath);
  if (!relativePath || relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    throw new Error(`${description} must stay within the repository root: ${targetPath}`);
  }
  return relativePath.replace(/\\/g, '/');
}

function resolveTargetPath(repoRoot, targetPath) {
  const requestedTargetPath = normalizeText(targetPath);
  if (!requestedTargetPath) {
    throw new Error('targetPath is required.');
  }
  const absolutePath = path.resolve(repoRoot, requestedTargetPath);
  if (!existsSync(absolutePath)) {
    throw new Error(`VI history target not found: ${requestedTargetPath}`);
  }
  return {
    absolutePath,
    relativePath: toRepoRelativePath(repoRoot, absolutePath, 'VI history target')
  };
}

function runGit(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const stdout = normalizeText(result.stdout);
  const stderr = normalizeText(result.stderr);
  if (result.status !== 0) {
    throw new Error(stderr || stdout || `git ${args.join(' ')} failed`);
  }
  return stdout;
}

function resolveGitCommit(repoRoot, ref) {
  const normalized = normalizeText(ref);
  if (!normalized) {
    throw new Error('A git ref is required.');
  }
  return runGit(repoRoot, ['rev-parse', `${normalized}^{commit}`]);
}

function resolveGitContext(repoRoot, branchRef, baselineRef) {
  const headSha = resolveGitCommit(repoRoot, 'HEAD');
  const branchSha = resolveGitCommit(repoRoot, branchRef);
  const baselineSha = normalizeText(baselineRef) ? resolveGitCommit(repoRoot, baselineRef) : '';
  return {
    headSha,
    branchSha,
    baselineSha
  };
}

function buildFirstParentRange(branchSha, baselineSha) {
  if (baselineSha && baselineSha !== branchSha) {
    return `${baselineSha}..${branchSha}`;
  }
  return branchSha;
}

function countRangeCommits(repoRoot, range) {
  return normalizePositiveInteger(runGit(repoRoot, ['rev-list', '--count', '--first-parent', range]), 'range commit count');
}

function listTouchingCommits(repoRoot, range, targetPath) {
  const output = runGit(repoRoot, ['rev-list', '--first-parent', range, '--', targetPath]);
  return output
    .split(/\r?\n/)
    .map((value) => normalizeText(value))
    .filter(Boolean);
}

function defaultResultsDir(repoRoot, targetPath, headSha) {
  return path.join(
    repoRoot,
    DEFAULT_LOCAL_COLLAB_VI_HISTORY_ASSIST_ROOT,
    'results',
    normalizePathFragment(targetPath),
    headSha
  );
}

function defaultReceiptPath(repoRoot, targetPath, headSha) {
  return path.join(
    repoRoot,
    DEFAULT_LOCAL_COLLAB_VI_HISTORY_ASSIST_ROOT,
    'receipts',
    normalizePathFragment(targetPath),
    `${headSha}.json`
  );
}

function defaultLatestIndexPath(repoRoot, targetPath) {
  return path.join(
    repoRoot,
    DEFAULT_LOCAL_COLLAB_VI_HISTORY_ASSIST_ROOT,
    'latest',
    `${normalizePathFragment(targetPath)}.json`
  );
}

function defaultCommandRunner({ command, args, cwd }) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: normalizeText(result.stdout),
    stderr: normalizeText(result.stderr)
  };
}

function parseJsonFileContents(raw, description) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Unable to parse ${description}: ${normalizeText(error?.message) || 'invalid JSON'}`);
  }
}

async function loadJsonFile(filePath, description) {
  const raw = await readFile(filePath, 'utf8');
  return parseJsonFileContents(raw, description);
}

async function ensureSuiteManifestCompatibility(resultsDir) {
  const aggregateManifestPath = path.join(resultsDir, 'manifest.json');
  const suiteManifestPath = path.join(resultsDir, 'suite-manifest.json');
  if (!existsSync(aggregateManifestPath)) {
    throw new Error(`VI history aggregate manifest missing: ${aggregateManifestPath}`);
  }
  if (!existsSync(suiteManifestPath)) {
    await copyFile(aggregateManifestPath, suiteManifestPath);
  }
  return {
    aggregateManifestPath,
    suiteManifestPath
  };
}

function buildCompactSummary(receiptPath, receipt) {
  return {
    schema: LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA,
    receiptPath,
    status: receipt.status,
    targetPath: receipt.request.targetPath,
    headSha: receipt.git.headSha,
    totalCommitsScanned: receipt.history.totalCommitsScanned,
    touchingCommitCount: receipt.history.touchingCommitCount,
    processedComparisons: receipt.history.processedComparisons,
    inspectionStatus: receipt.inspection.overallStatus
  };
}

export function parseArgs(argv = process.argv) {
  const args = Array.isArray(argv) ? argv.slice(2) : [];
  const parsed = {
    repoRoot: process.cwd(),
    targetPath: '',
    branchRef: 'HEAD',
    baselineRef: '',
    expectedHeadSha: '',
    maxBranchCommits: 0,
    maxPairs: 2,
    resultsDir: '',
    receiptPath: '',
    latestIndexPath: ''
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    switch (token) {
      case '--repo-root':
        parsed.repoRoot = normalizeText(args[index + 1]) || parsed.repoRoot;
        index += 1;
        break;
      case '--target-path':
        parsed.targetPath = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--branch-ref':
        parsed.branchRef = normalizeText(args[index + 1]) || parsed.branchRef;
        index += 1;
        break;
      case '--baseline-ref':
        parsed.baselineRef = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--expected-head-sha':
        parsed.expectedHeadSha = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--max-branch-commits':
        parsed.maxBranchCommits = normalizePositiveInteger(args[index + 1], 'maxBranchCommits');
        index += 1;
        break;
      case '--max-pairs':
        parsed.maxPairs = normalizePositiveInteger(args[index + 1], 'maxPairs');
        index += 1;
        break;
      case '--results-dir':
        parsed.resultsDir = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--receipt-path':
        parsed.receiptPath = normalizeText(args[index + 1]);
        index += 1;
        break;
      case '--latest-index-path':
        parsed.latestIndexPath = normalizeText(args[index + 1]);
        index += 1;
        break;
      default:
        throw new Error(`Unknown argument: ${token}`);
    }
  }

  if (!normalizeText(parsed.targetPath)) {
    throw new Error('--target-path is required.');
  }
  if (!normalizeText(parsed.branchRef)) {
    throw new Error('--branch-ref is required.');
  }
  if (!Number.isInteger(parsed.maxBranchCommits) || parsed.maxBranchCommits <= 0) {
    throw new Error('--max-branch-commits is required.');
  }
  return parsed;
}

export async function runViHistoryOperatorAssistance(options = {}) {
  const repoRoot = path.resolve(normalizeText(options.repoRoot) || process.cwd());
  const target = resolveTargetPath(repoRoot, options.targetPath);
  const branchRef = normalizeText(options.branchRef) || 'HEAD';
  const baselineRef = normalizeText(options.baselineRef);
  const expectedHeadSha = normalizeText(options.expectedHeadSha);
  const maxBranchCommits = normalizePositiveInteger(options.maxBranchCommits, 'maxBranchCommits');
  const maxPairs = normalizePositiveInteger(options.maxPairs ?? 2, 'maxPairs');
  const runCommandFn = typeof options.runCommandFn === 'function' ? options.runCommandFn : defaultCommandRunner;
  const compareScriptPath = path.resolve(repoRoot, DEFAULT_COMPARE_VI_HISTORY_SCRIPT);
  const inspectorScriptPath = path.resolve(repoRoot, DEFAULT_HISTORY_INSPECTOR_SCRIPT);

  if (!existsSync(compareScriptPath)) {
    throw new Error(`Compare-VIHistory.ps1 not found: ${compareScriptPath}`);
  }
  if (!existsSync(inspectorScriptPath)) {
    throw new Error(`Inspect-VIHistorySuiteArtifacts.ps1 not found: ${inspectorScriptPath}`);
  }

  const git = resolveGitContext(repoRoot, branchRef, baselineRef);
  if (expectedHeadSha && git.headSha !== expectedHeadSha) {
    throw new Error(`Stale VI history assistance request: expected head ${expectedHeadSha} but current head is ${git.headSha}.`);
  }
  if (git.branchSha !== git.headSha) {
    throw new Error(`VI history assistance only supports the current branch head. '${branchRef}' resolved to ${git.branchSha}, current HEAD is ${git.headSha}.`);
  }

  const range = buildFirstParentRange(git.branchSha, git.baselineSha);
  const totalCommitsScanned = countRangeCommits(repoRoot, range);
  if (totalCommitsScanned > maxBranchCommits) {
    throw new Error(`VI history source branch exceeds the commit safeguard (${totalCommitsScanned} > ${maxBranchCommits}).`);
  }

  const touchingCommits = listTouchingCommits(repoRoot, range, target.relativePath);
  if (touchingCommits.length === 0) {
    throw new Error(`No commits touching '${target.relativePath}' were found in the bounded first-parent range.`);
  }

  const resultsDir = path.resolve(
    repoRoot,
    normalizeText(options.resultsDir) || defaultResultsDir(repoRoot, target.relativePath, git.headSha)
  );
  const receiptPath = path.resolve(
    repoRoot,
    normalizeText(options.receiptPath) || defaultReceiptPath(repoRoot, target.relativePath, git.headSha)
  );
  const latestIndexPath = path.resolve(
    repoRoot,
    normalizeText(options.latestIndexPath) || defaultLatestIndexPath(repoRoot, target.relativePath)
  );

  await mkdir(resultsDir, { recursive: true });
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await mkdir(path.dirname(latestIndexPath), { recursive: true });

  const compareResult = await Promise.resolve(
    runCommandFn({
      command: 'pwsh',
      args: [
        '-NoLogo',
        '-NoProfile',
        '-File',
        compareScriptPath,
        '-TargetPath',
        target.relativePath,
        '-StartRef',
        git.branchSha,
        '-SourceBranchRef',
        branchRef,
        '-MaxBranchCommits',
        String(maxBranchCommits),
        '-MaxPairs',
        String(maxPairs),
        '-ResultsDir',
        resultsDir,
        '-RenderReport',
        '-ReportFormat',
        'html'
      ],
      cwd: repoRoot
    })
  );
  if (compareResult.status !== 0) {
    throw new Error(compareResult.stderr || compareResult.stdout || 'Compare-VIHistory.ps1 failed.');
  }

  const { aggregateManifestPath, suiteManifestPath } = await ensureSuiteManifestCompatibility(resultsDir);
  const historyReportMarkdownPath = path.join(resultsDir, 'history-report.md');
  const historyReportHtmlPath = path.join(resultsDir, 'history-report.html');
  const historySummaryPath = path.join(resultsDir, 'history-summary.json');
  const historyInspectionJsonPath = path.join(resultsDir, 'history-suite-inspection.json');
  const historyInspectionHtmlPath = path.join(resultsDir, 'history-suite-inspection.html');

  for (const requiredPath of [historyReportMarkdownPath, historyReportHtmlPath, historySummaryPath]) {
    if (!existsSync(requiredPath)) {
      throw new Error(`VI history assistance missing required artifact: ${requiredPath}`);
    }
  }

  const inspectResult = await Promise.resolve(
    runCommandFn({
      command: 'pwsh',
      args: [
        '-NoLogo',
        '-NoProfile',
        '-File',
        inspectorScriptPath,
        '-ResultsDir',
        resultsDir,
        '-HistoryReportPath',
        historyReportHtmlPath,
        '-HistorySummaryPath',
        historySummaryPath,
        '-OutputJsonPath',
        historyInspectionJsonPath,
        '-OutputHtmlPath',
        historyInspectionHtmlPath,
        '-GitHubOutputPath',
        '',
        '-GitHubStepSummaryPath',
        ''
      ],
      cwd: repoRoot
    })
  );
  if (inspectResult.status !== 0) {
    throw new Error(inspectResult.stderr || inspectResult.stdout || 'Inspect-VIHistorySuiteArtifacts.ps1 failed.');
  }

  const historySummary = await loadJsonFile(historySummaryPath, 'history summary JSON');
  const inspection = await loadJsonFile(historyInspectionJsonPath, 'VI history inspection JSON');
  const generatedAt = new Date().toISOString();
  const processedComparisons = normalizeInteger(historySummary?.summary?.comparisons);
  const selectedPairCount = Math.min(touchingCommits.length, maxPairs);

  const receipt = {
    schema: LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA,
    receiptId: `vi-history:${normalizePathFragment(target.relativePath)}:${git.headSha}`,
    generatedAt,
    repoRoot,
    request: {
      targetPath: target.relativePath,
      branchRef,
      baselineRef: baselineRef || null,
      expectedHeadSha: expectedHeadSha || null,
      maxBranchCommits,
      maxPairs
    },
    git: {
      headSha: git.headSha,
      branchSha: git.branchSha,
      baselineSha: git.baselineSha || null,
      range
    },
    history: {
      totalCommitsScanned,
      touchingCommitCount: touchingCommits.length,
      touchingCommitShas: touchingCommits,
      selectedPairCount,
      processedComparisons,
      diffs: normalizeInteger(historySummary?.summary?.diffs),
      signalDiffs: normalizeInteger(historySummary?.summary?.signalDiffs),
      errors: normalizeInteger(historySummary?.summary?.errors)
    },
    artifacts: {
      resultsDir: toRepoRelativePath(repoRoot, resultsDir, 'VI history results directory'),
      aggregateManifestPath: toRepoRelativePath(repoRoot, aggregateManifestPath, 'VI history aggregate manifest'),
      suiteManifestPath: toRepoRelativePath(repoRoot, suiteManifestPath, 'VI history suite manifest'),
      historyReportMarkdownPath: toRepoRelativePath(repoRoot, historyReportMarkdownPath, 'VI history markdown report'),
      historyReportHtmlPath: toRepoRelativePath(repoRoot, historyReportHtmlPath, 'VI history HTML report'),
      historySummaryPath: toRepoRelativePath(repoRoot, historySummaryPath, 'VI history summary'),
      historyInspectionJsonPath: toRepoRelativePath(repoRoot, historyInspectionJsonPath, 'VI history inspection JSON'),
      historyInspectionHtmlPath: toRepoRelativePath(repoRoot, historyInspectionHtmlPath, 'VI history inspection HTML')
    },
    inspection: {
      schema: normalizeText(inspection?.schema) || null,
      overallStatus: normalizeText(inspection?.overallStatus) || 'unknown',
      summary: inspection?.summary && typeof inspection.summary === 'object' ? inspection.summary : {}
    },
    status: normalizeText(inspection?.overallStatus) === 'ok' ? 'passed' : 'failed',
    outcome: normalizeText(inspection?.overallStatus) === 'ok' ? 'completed' : 'blocked'
  };

  const latestIndex = {
    schema: LOCAL_COLLAB_VI_HISTORY_ASSIST_LATEST_SCHEMA,
    updatedAt: generatedAt,
    targetPath: target.relativePath,
    headSha: git.headSha,
    receiptId: receipt.receiptId,
    receiptPath: toRepoRelativePath(repoRoot, receiptPath, 'VI history assistance receipt'),
    status: receipt.status,
    outcome: receipt.outcome
  };

  await writeFile(receiptPath, JSON.stringify(receipt, null, 2), 'utf8');
  await writeFile(latestIndexPath, JSON.stringify(latestIndex, null, 2), 'utf8');

  return {
    receipt,
    receiptPath,
    latestIndex,
    latestIndexPath,
    summary: buildCompactSummary(toRepoRelativePath(repoRoot, receiptPath, 'VI history assistance receipt'), receipt)
  };
}

export async function assessLatestViHistoryOperatorAssistance(options = {}) {
  const repoRoot = path.resolve(normalizeText(options.repoRoot) || process.cwd());
  const targetPath = normalizeText(options.targetPath);
  if (!targetPath) {
    throw new Error('targetPath is required to assess the latest VI history assistance receipt.');
  }
  const latestIndexPath = path.resolve(
    repoRoot,
    normalizeText(options.latestIndexPath) || defaultLatestIndexPath(repoRoot, targetPath)
  );

  if (!existsSync(latestIndexPath)) {
    return {
      ok: false,
      status: 'missing-index',
      reason: `No latest VI history assistance index exists for '${targetPath}'.`,
      latestIndexPath,
      receiptPath: null,
      receipt: null
    };
  }

  let latestIndex;
  try {
    latestIndex = await loadJsonFile(latestIndexPath, 'VI history latest index');
  } catch (error) {
    return {
      ok: false,
      status: 'invalid-index',
      reason: normalizeText(error?.message) || 'Latest VI history assistance index is invalid.',
      latestIndexPath,
      receiptPath: null,
      receipt: null
    };
  }

  if (
    normalizeText(latestIndex?.schema) !== LOCAL_COLLAB_VI_HISTORY_ASSIST_LATEST_SCHEMA ||
    normalizeText(latestIndex?.targetPath) !== targetPath ||
    !normalizeText(latestIndex?.headSha) ||
    !normalizeText(latestIndex?.receiptPath)
  ) {
    return {
      ok: false,
      status: 'invalid-index',
      reason: 'Latest VI history assistance index is missing required fields.',
      latestIndexPath,
      receiptPath: null,
      receipt: null
    };
  }

  const receiptPath = path.resolve(repoRoot, latestIndex.receiptPath);
  let receipt;
  try {
    if (!existsSync(receiptPath)) {
      return {
        ok: false,
        status: 'missing-receipt',
        reason: 'Latest VI history assistance receipt file is missing.',
        latestIndexPath,
        receiptPath,
        receipt: null
      };
    }
    receipt = await loadJsonFile(receiptPath, 'VI history assistance receipt');
  } catch (error) {
    return {
      ok: false,
      status: 'invalid-receipt',
      reason: normalizeText(error?.message) || 'VI history assistance receipt is invalid.',
      latestIndexPath,
      receiptPath,
      receipt: null
    };
  }

  if (
    normalizeText(receipt?.schema) !== LOCAL_COLLAB_VI_HISTORY_ASSIST_SCHEMA ||
    normalizeText(receipt?.request?.targetPath) !== targetPath ||
    normalizeText(receipt?.receiptId) !== normalizeText(latestIndex?.receiptId) ||
    normalizeText(receipt?.git?.headSha) !== normalizeText(latestIndex?.headSha)
  ) {
    return {
      ok: false,
      status: 'invalid-receipt',
      reason: 'VI history assistance receipt does not match the latest index contract.',
      latestIndexPath,
      receiptPath,
      receipt
    };
  }

  const expectedHeadSha = normalizeText(options.expectedHeadSha);
  if (expectedHeadSha && normalizeText(receipt?.git?.headSha) !== expectedHeadSha) {
    return {
      ok: false,
      status: 'stale',
      reason: `Latest VI history assistance receipt is stale for '${targetPath}'.`,
      latestIndexPath,
      receiptPath,
      receipt
    };
  }

  return {
    ok: true,
    status: 'valid',
    reason: `Latest VI history assistance receipt is valid for '${targetPath}'.`,
    latestIndexPath,
    receiptPath,
    receipt
  };
}

export async function main(argv = process.argv) {
  const parsed = parseArgs(argv);
  const result = await runViHistoryOperatorAssistance(parsed);
  process.stdout.write(`${JSON.stringify(result.summary, null, 2)}\n`);
  return 0;
}

const isEntrypoint = fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || '');

if (isEntrypoint) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}
