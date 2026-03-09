#!/usr/bin/env node

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
  console.log(`  --destination-root <path>   Destination root (default: ${DEFAULT_DESTINATION_ROOT}).`);
  console.log(`  --report <path>             Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  -h, --help                  Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repo: normalizeText(process.env.GITHUB_REPOSITORY),
    runId: null,
    artifactNames: [],
    destinationRoot: DEFAULT_DESTINATION_ROOT,
    reportPath: DEFAULT_REPORT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--run-id' ||
      token === '--artifact' ||
      token === '--destination-root' ||
      token === '--report'
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
    if (options.artifactNames.length === 0) {
      throw new Error('At least one artifact is required. Pass --artifact <name>.');
    }
  }

  return options;
}

export async function main(argv = process.argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  const result = downloadNamedArtifacts({
    repository: options.repo,
    runId: options.runId,
    artifactNames: options.artifactNames,
    destinationRoot: options.destinationRoot,
    reportPath: options.reportPath,
  });

  console.log(`[run-artifact-download] report: ${result.reportPath}`);
  console.log(
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
