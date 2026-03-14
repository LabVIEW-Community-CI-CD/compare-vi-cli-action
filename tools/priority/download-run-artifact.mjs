#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_DESTINATION_ROOT,
  DEFAULT_REPORT_PATH,
  downloadNamedArtifacts,
} from './lib/run-artifact-download.mjs';

function printUsage() {
  console.log('Usage: node tools/priority/download-run-artifact.mjs [options]');
  console.log('');
  console.log('Download named workflow run artifacts through the checked-in helper path.');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>          Target repository (default: GITHUB_REPOSITORY).');
  console.log('  --run-id <id>               Workflow run id to download from.');
  console.log('  --artifact <name>           Artifact name to download (repeatable).');
  console.log('  --all                       Download every non-expired artifact from the run.');
  console.log(`  --destination-root <path>   Destination root (default: ${DEFAULT_DESTINATION_ROOT}).`);
  console.log(`  --report <path>             Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --step-summary <path>       Override the GitHub step summary output path.');
  console.log('  -h, --help                  Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

export function parseArgs(argv = process.argv, env = process.env) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeText(process.env.GITHUB_REPOSITORY),
    runId: null,
    artifactNames: [],
    downloadAll: false,
    destinationRoot: DEFAULT_DESTINATION_ROOT,
    reportPath: DEFAULT_REPORT_PATH,
    stepSummaryPath: normalizeText(env.GITHUB_STEP_SUMMARY),
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--all') {
      options.downloadAll = true;
      continue;
    }
    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--run-id' ||
      token === '--artifact' ||
      token === '--destination-root' ||
      token === '--report' ||
      token === '--step-summary'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--run-id') options.runId = normalizeText(next);
      if (token === '--artifact') {
        const artifactName = normalizeText(next);
        if (!artifactName) {
          throw new Error('Artifact name is required for --artifact.');
        }
        options.artifactNames.push(artifactName);
      }
      if (token === '--destination-root') options.destinationRoot = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repo) {
      throw new Error('Repository is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
    }
    if (!options.runId) {
      throw new Error('Run id is required. Pass --run-id <id>.');
    }
    if (options.downloadAll && options.artifactNames.length > 0) {
      throw new Error('Use either --all or one or more --artifact values, not both.');
    }
    if (!options.downloadAll && options.artifactNames.length === 0) {
      throw new Error('At least one artifact is required. Pass --artifact <name> or use --all.');
    }
  }

  return options;
}

function firstDownloadFailureClass(report) {
  return (
    report?.downloads?.find((entry) => normalizeText(entry?.failureClass))?.failureClass ??
    null
  );
}

export function buildGitHubOutputPairs({ options, result }) {
  const report = result.report;
  return [
    ['run-artifact-download-status', report.status],
    ['run-artifact-download-report-path', result.reportPath],
    ['run-artifact-download-repository', options.repo],
    ['run-artifact-download-run-id', options.runId],
    ['run-artifact-download-discovery-status', report.discovery.status],
    ['run-artifact-download-discovery-failure-class', report.discovery.failureClass ?? ''],
    ['run-artifact-download-first-failure-class', firstDownloadFailureClass(report) ?? ''],
    ['run-artifact-download-requested-count', String(report.summary.requestedArtifactCount)],
    ['run-artifact-download-available-count', String(report.summary.availableArtifactCount)],
    ['run-artifact-download-downloaded-count', String(report.summary.downloadedCount)],
    ['run-artifact-download-missing-count', String(report.summary.missingCount)],
    ['run-artifact-download-failed-count', String(report.summary.failedCount)],
  ];
}

export function writeGitHubOutputs(outputPath, pairs) {
  const normalizedPath = normalizeText(outputPath);
  if (!normalizedPath) {
    return;
  }
  const resolvedPath = path.resolve(process.cwd(), normalizedPath);
  for (const [name, value] of pairs) {
    fs.appendFileSync(resolvedPath, `${name}=${value ?? ''}\n`, 'utf8');
  }
}

export function buildStepSummaryLines({ options, result }) {
  const report = result.report;
  const lines = [
    '### Run Artifact Download',
    '',
    `- status: \`${report.status}\``,
    `- repository: \`${options.repo}\``,
    `- run id: \`${options.runId}\``,
    `- report: \`${result.reportPath}\``,
    `- requested: \`${report.summary.requestedArtifactCount}\``,
    `- available: \`${report.summary.availableArtifactCount}\``,
    `- downloaded: \`${report.summary.downloadedCount}\``,
    `- missing: \`${report.summary.missingCount}\``,
    `- failed: \`${report.summary.failedCount}\``,
  ];

  if (normalizeText(report.discovery.failureClass)) {
    lines.push(`- discovery failure: \`${report.discovery.failureClass}\``);
  }
  const failedDownloads = report.downloads.filter((entry) => entry.status !== 'downloaded');
  if (failedDownloads.length > 0) {
    lines.push('', 'Failures:');
    for (const entry of failedDownloads) {
      lines.push(
        `- \`${entry.name}\`: status=\`${entry.status}\` failureClass=\`${entry.failureClass ?? 'none'}\``,
      );
    }
  }

  return lines;
}

export function appendStepSummary(stepSummaryPath, lines) {
  const normalizedPath = normalizeText(stepSummaryPath);
  if (!normalizedPath) {
    return;
  }
  const resolvedPath = path.resolve(process.cwd(), normalizedPath);
  fs.appendFileSync(resolvedPath, `${lines.join('\n')}\n`, 'utf8');
}

export async function main(
  argv = process.argv,
  {
    downloadNamedArtifactsFn = downloadNamedArtifacts,
    env = process.env,
    logFn = console.log,
    errorFn = console.error,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv, env);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  const result = downloadNamedArtifactsFn({
    repository: options.repo,
    runId: options.runId,
    artifactNames: options.artifactNames,
    downloadAll: options.downloadAll,
    destinationRoot: options.destinationRoot,
    reportPath: options.reportPath,
  });

  writeGitHubOutputs(env.GITHUB_OUTPUT, buildGitHubOutputPairs({ options, result }));
  appendStepSummary(options.stepSummaryPath, buildStepSummaryLines({ options, result }));

  logFn(`[run-artifact-download] report: ${result.reportPath}`);
  logFn(
    `[run-artifact-download] status=${result.report.status} requested=${result.report.summary.requestedArtifactCount} downloaded=${result.report.summary.downloadedCount} missing=${result.report.summary.missingCount} failed=${result.report.summary.failedCount}`,
  );
  return result.report.status === 'pass' ? 0 : 1;
}

export function isDirectExecution(argv = process.argv, metaUrl = import.meta.url) {
  const modulePath = path.resolve(fileURLToPath(metaUrl));
  const invokedPath = argv[1] ? path.resolve(argv[1]) : null;
  return Boolean(invokedPath && invokedPath === modulePath);
}

if (isDirectExecution(process.argv, import.meta.url)) {
  const exitCode = await main(process.argv);
  process.exitCode = exitCode;
}
