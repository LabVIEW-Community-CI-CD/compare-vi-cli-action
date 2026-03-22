#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { runSessionIndexV2PromotionDecision } from './session-index-v2-promotion-decision.mjs';

export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'session-index-v2-promotion-decision.json',
);
export const DEFAULT_DOWNLOAD_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'session-index-v2-promotion-decision-download.json',
);
export const DEFAULT_DESTINATION_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'session-index-v2-promotion-decision-artifacts',
);

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function toRepoRelative(repoRoot, targetPath) {
  return path.relative(repoRoot, targetPath).replace(/\\/g, '/');
}

function toRepoRelativeOrAbsolute(repoRoot, targetPath) {
  if (!targetPath) {
    return null;
  }
  const resolvedTargetPath = path.resolve(targetPath);
  const relativePath = path.relative(repoRoot, resolvedTargetPath);
  if (relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath))) {
    return relativePath.replace(/\\/g, '/');
  }
  return resolvedTargetPath;
}

export function clearProjectionOutputs(repoRoot) {
  for (const relativePath of [DEFAULT_REPORT_PATH, DEFAULT_DOWNLOAD_REPORT_PATH, DEFAULT_DESTINATION_ROOT]) {
    fs.rmSync(path.join(repoRoot, relativePath), { recursive: true, force: true });
  }
}

export function parseArgs(argv = process.argv, env = process.env) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeText(env.GITHUB_REPOSITORY),
    branch: 'develop',
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--repo' || token === '--branch') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') {
        options.repo = normalizeText(next);
      }
      if (token === '--branch') {
        options.branch = normalizeText(next);
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.branch) {
    throw new Error('--branch must not be empty.');
  }

  return options;
}

function printUsage(log = console.log) {
  log('Usage: node tools/priority/project-session-index-v2-promotion-decision.mjs [options]');
  log('');
  log('Project the latest session-index-v2 promotion decision into the standing issue results bundle.');
  log('');
  log('Options:');
  log('  --repo <owner/repo>   Repository to evaluate (default: GITHUB_REPOSITORY / git remotes).');
  log('  --branch <name>       Branch to evaluate (default: develop).');
  log('  -h, --help            Show help.');
}

export function buildProjectionSnapshot({
  repoRoot,
  report,
  reportPath,
  exitCode,
  errorMessage = null,
}) {
  const relativeReportPath = reportPath ? toRepoRelative(repoRoot, reportPath) : toRepoRelative(repoRoot, path.join(repoRoot, DEFAULT_REPORT_PATH));
  const relativeDownloadReportPath = report?.artifact?.downloadReportPath
    ? toRepoRelativeOrAbsolute(repoRoot, report.artifact.downloadReportPath)
    : toRepoRelative(repoRoot, path.join(repoRoot, DEFAULT_DOWNLOAD_REPORT_PATH));
  const relativeArtifactRoot = report?.artifact?.destinationRoot
    ? toRepoRelativeOrAbsolute(repoRoot, report.artifact.destinationRoot)
    : toRepoRelative(repoRoot, path.join(repoRoot, DEFAULT_DESTINATION_ROOT));

  if (!report) {
    return {
      path: relativeReportPath,
      downloadReportPath: relativeDownloadReportPath,
      artifactRoot: relativeArtifactRoot,
      status: 'error',
      state: 'projection-error',
      summary: errorMessage ?? 'Projection failed before a promotion-decision report was produced.',
      selectionMode: null,
      selectionStatus: null,
      selectionFailureClass: null,
      sourceRunId: null,
      exitCode,
    };
  }

  return {
    path: relativeReportPath,
    downloadReportPath: relativeDownloadReportPath,
    artifactRoot: relativeArtifactRoot,
    status: report.status ?? 'warn',
    state: report.decision?.state ?? 'missing-evidence',
    summary: report.decision?.summary ?? 'Promotion decision projection completed without a decision summary.',
    selectionMode: report.selection?.mode ?? null,
    selectionStatus: report.selection?.status ?? null,
    selectionFailureClass: report.selection?.failureClass ?? null,
    sourceRunId: report.sourceRun?.id ?? null,
    exitCode,
  };
}

export function buildProjectionLines(snapshot) {
  return [
    '[session-index-v2-promotion-projection] projected latest promotion decision into the standing issue bundle.',
    `[session-index-v2-promotion-projection] state=${snapshot.state} status=${snapshot.status} run=${snapshot.sourceRunId ?? 'none'}`,
    `[session-index-v2-promotion-projection] report=${snapshot.path}`,
  ];
}

export async function projectSessionIndexV2PromotionDecision({
  argv = process.argv,
  env = process.env,
  repoRoot = process.cwd(),
  now = new Date(),
  logFn = console.log,
  runSessionIndexV2PromotionDecisionFn = runSessionIndexV2PromotionDecision,
} = {}) {
  const options = parseArgs(argv, env);
  if (options.help) {
    printUsage(logFn);
    return {
      exitCode: 0,
      snapshot: null,
      report: null,
      reportPath: null,
    };
  }

  const args = [
    'node',
    'tools/priority/session-index-v2-promotion-decision.mjs',
    '--branch',
    options.branch,
    '--out',
    DEFAULT_REPORT_PATH,
    '--download-report',
    DEFAULT_DOWNLOAD_REPORT_PATH,
    '--destination-root',
    DEFAULT_DESTINATION_ROOT,
  ];
  if (options.repo) {
    args.push('--repo', options.repo);
  }

  try {
    clearProjectionOutputs(repoRoot);
    const result = await runSessionIndexV2PromotionDecisionFn({
      argv: args,
      env,
      now,
      repoRoot,
    });
    const snapshot = buildProjectionSnapshot({
      repoRoot,
      report: result.report,
      reportPath: result.reportPath,
      exitCode: result.exitCode,
    });
    for (const line of buildProjectionLines(snapshot)) {
      logFn(line);
    }
    return {
      ...result,
      exitCode: 0,
      snapshot,
    };
  } catch (error) {
    clearProjectionOutputs(repoRoot);
    const snapshot = buildProjectionSnapshot({
      repoRoot,
      report: null,
      reportPath: path.join(repoRoot, DEFAULT_REPORT_PATH),
      exitCode: 1,
      errorMessage: error instanceof Error ? error.message : String(error),
    });
    for (const line of buildProjectionLines(snapshot)) {
      logFn(line);
    }
    return {
      exitCode: 1,
      snapshot,
      report: null,
      reportPath: path.join(repoRoot, DEFAULT_REPORT_PATH),
    };
  }
}

const isMainModule = (() => {
  if (!process.argv[1]) {
    return false;
  }
  return fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
})();

if (isMainModule) {
  const result = await projectSessionIndexV2PromotionDecision();
  process.exitCode = result.exitCode;
}
