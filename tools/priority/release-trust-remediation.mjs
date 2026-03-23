#!/usr/bin/env node

import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_TRUST_REPORT_PATH = path.join('tests', 'results', '_agent', 'supply-chain', 'release-trust-gate.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'release', 'release-trust-remediation.md');
const REPAIR_FAILURE_CODES = new Set(['tag-not-annotated', 'tag-signature-unverified']);

function normalizeOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

function normalizeVersionFromTag(tagRef) {
  const normalized = normalizeOptional(tagRef);
  if (!normalized) {
    return null;
  }
  return normalized.startsWith('v') ? normalized.slice(1) : normalized;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    trustReportPath: DEFAULT_TRUST_REPORT_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    summaryPath: null,
    tagRef: null
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--trust-report' || token === '--output' || token === '--summary' || token === '--tag-ref') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--trust-report') options.trustReportPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--summary') options.summaryPath = next;
      if (token === '--tag-ref') options.tagRef = next;
      continue;
    }
    if (token === '--help' || token === '-h') {
      return { ...options, help: true };
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

async function readJson(filePath) {
  return JSON.parse(await readFile(path.resolve(filePath), 'utf8'));
}

async function writeText(filePath, contents) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, contents, 'utf8');
  return resolved;
}

async function appendText(filePath, contents) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await appendFile(resolved, contents, 'utf8');
  return resolved;
}

export function buildReleaseTrustRemediationMarkdown({ trustReport, tagRef }) {
  const failures = Array.isArray(trustReport?.failures)
    ? trustReport.failures
    : Array.isArray(trustReport?.summary?.failures)
      ? trustReport.summary.failures
      : [];
  const relevantFailures = failures.filter((failure) => REPAIR_FAILURE_CODES.has(String(failure?.code ?? '').trim()));
  const normalizedTag = normalizeOptional(tagRef) ?? normalizeOptional(trustReport?.tagSignature?.refName);
  const normalizedVersion = normalizeVersionFromTag(normalizedTag);

  const lines = ['## Release Trust Remediation', ''];
  if (relevantFailures.length === 0) {
    lines.push('- No repair-mode remediation is required for the current trust-gate result.');
    lines.push('');
    return lines.join('\n');
  }

  lines.push(`- Release trust gate reported repair-eligible tag failures for \`${normalizedTag ?? 'unknown-tag'}\`.`);
  lines.push(`- Failure codes: ${relevantFailures.map((failure) => `\`${failure.code}\``).join(', ')}`);
  lines.push('- Preserve tag identity and asset names. Do not rename the release tag to bypass trust verification.');
  lines.push('- Rerun `.github/workflows/release-conductor.yml` with:');
  lines.push(`  - \`version = ${normalizedVersion ?? 'X.Y.Z'}\``);
  lines.push('  - `apply = true`');
  lines.push('  - `repair_existing_tag = true`');
  lines.push('- Continue release publication only after `tests/results/_agent/release/release-conductor-report.json` shows:');
  lines.push('  - `release.repair.status = repaired`');
  lines.push('  - `release.tagPushed = true`');
  lines.push('');
  return lines.join('\n');
}

export async function runReleaseTrustRemediation(options = {}) {
  const args = options.args ?? parseArgs();
  if (args.help) {
    return { markdown: '', outputPath: null, summaryPath: null, wroteSummary: false };
  }

  const trustReport = await readJson(args.trustReportPath);
  const markdown = buildReleaseTrustRemediationMarkdown({
    trustReport,
    tagRef: args.tagRef
  });
  const outputPath = await writeText(args.outputPath, `${markdown}\n`);

  let summaryPath = null;
  let wroteSummary = false;
  if (args.summaryPath) {
    summaryPath = await appendText(args.summaryPath, `\n${markdown}\n`);
    wroteSummary = true;
  }

  return {
    markdown,
    outputPath,
    summaryPath,
    wroteSummary
  };
}

async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log('Usage: node tools/priority/release-trust-remediation.mjs [options]');
    console.log('');
    console.log(`  --trust-report <path>  Trust-gate report path (default: ${DEFAULT_TRUST_REPORT_PATH}).`);
    console.log(`  --output <path>        Markdown output path (default: ${DEFAULT_OUTPUT_PATH}).`);
    console.log('  --summary <path>       Optional workflow step summary path to overwrite.');
    console.log('  --tag-ref <value>      Optional release tag name override.');
    return 0;
  }

  const result = await runReleaseTrustRemediation({ args });
  console.log(`[release-trust-remediation] wrote ${result.outputPath}`);
  if (result.wroteSummary) {
    console.log(`[release-trust-remediation] summary ${result.summaryPath}`);
  }
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main(process.argv)
    .then((exitCode) => {
      if (exitCode !== 0) {
        process.exitCode = exitCode;
      }
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
