#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH,
  MISSION_CONTROL_PROMPT_RENDER_SCHEMA,
  renderMissionControlPromptReport,
} from './render-mission-control-prompt.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = path.dirname(SCRIPT_PATH);
export const DEFAULT_REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');
export const MISSION_CONTROL_PROMPT_VALIDATION_SCHEMA = 'priority/mission-control-prompt-validation@v1';
export const DEFAULT_MISSION_CONTROL_PROMPT_VALIDATION_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'mission-control',
  'mission-control-prompt-validation.json',
);

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function resolvePathFromBase(filePath, baseDir) {
  return path.resolve(baseDir, filePath);
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function readTextFile(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function writeJsonFile(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

function readCanonicalPromptText(repoRoot = DEFAULT_REPO_ROOT) {
  const promptPath = resolvePathFromBase('PROMPT_AUTONOMY.md', repoRoot);
  const markdown = readTextFile(promptPath);
  const match = markdown.match(/```text\r?\n([\s\S]*?)\r?\n```/);
  if (!match) {
    throw new Error('PROMPT_AUTONOMY.md must contain a canonical text block.');
  }
  return `${match[1].replace(/\r\n/g, '\n').trimEnd()}\n`;
}

function normalizePromptArtifactText(value) {
  return String(value).replace(/\r\n/g, '\n');
}

function normalizePromptScalar(value, fieldName) {
  if (typeof value === 'string') {
    const raw = String(value);
    if (/[\r\n]/.test(raw)) {
      throw new Error(`Mission-control prompt validation field '${fieldName}' must not contain newlines.`);
    }
    const normalized = normalizeText(raw);
    if (!normalized) {
      throw new Error(`Mission-control prompt validation field '${fieldName}' must be non-empty single-line text.`);
    }
    return normalized;
  }
  if (typeof value === 'boolean' || typeof value === 'number') {
    return String(value);
  }
  throw new Error(`Mission-control prompt validation field '${fieldName}' must be a scalar value.`);
}

function compareOverrideEntries(left, right) {
  return (
    left.key.localeCompare(right.key)
    || String(left.value).localeCompare(String(right.value))
    || String(left.reason).localeCompare(String(right.reason))
  );
}

function canonicalizeOverrides(overrides) {
  return [...overrides]
    .map((override) => ({
      key: normalizePromptScalar(override.key, 'operator.overrides[].key'),
      value: normalizePromptScalar(override.value, 'operator.overrides[].value'),
      reason: normalizeText(override.reason) ?? '',
    }))
    .sort(compareOverrideEntries);
}

function renderExpectedDirective(operator) {
  const overrides = canonicalizeOverrides(Array.isArray(operator.overrides) ? operator.overrides : []);
  const overrideLines = overrides.length > 0
    ? overrides.map((override) => `- override: \`${override.key}=${override.value}\``)
    : ['- overrides: `none`'];

  return [
    'Operator directive:',
    `- intent: \`${normalizePromptScalar(operator.intent, 'operator.intent')}\``,
    `- focus: \`${normalizePromptScalar(operator.focus, 'operator.focus')}\``,
    ...overrideLines,
  ].join('\n');
}

function renderExpectedPromptFromReport(report, repoRoot = DEFAULT_REPO_ROOT) {
  return `${renderExpectedDirective(report.operator)}\n\n${readCanonicalPromptText(repoRoot)}`;
}

function sha256Text(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function normalizePromptRenderReport(report) {
  if (!report || typeof report !== 'object' || Array.isArray(report)) {
    throw new Error('Mission-control prompt render report must be an object.');
  }
  if (report.schema !== MISSION_CONTROL_PROMPT_RENDER_SCHEMA) {
    throw new Error(`Mission-control prompt render report schema must be '${MISSION_CONTROL_PROMPT_RENDER_SCHEMA}'.`);
  }
  if (!path.isAbsolute(report.envelopePath) || !path.isAbsolute(report.promptPath)) {
    throw new Error('Mission-control prompt render report paths must be absolute.');
  }
  if (!normalizeText(report.envelopeSha256) || !normalizeText(report.promptSha256)) {
    throw new Error('Mission-control prompt render report must include envelopeSha256 and promptSha256.');
  }
  if (!normalizeText(report.promptText)) {
    throw new Error('Mission-control prompt render report must include promptText.');
  }
  if (!report.operator || typeof report.operator !== 'object' || Array.isArray(report.operator)) {
    throw new Error('Mission-control prompt render report must include operator metadata.');
  }
  return {
    ...report,
    operator: {
      intent: normalizePromptScalar(report.operator.intent, 'operator.intent'),
      focus: normalizePromptScalar(report.operator.focus, 'operator.focus'),
      overrides: canonicalizeOverrides(Array.isArray(report.operator.overrides) ? report.operator.overrides : []),
    },
    promptText: normalizePromptArtifactText(report.promptText),
  };
}

export function assessMissionControlPromptReport(
  report,
  {
    repoRoot = DEFAULT_REPO_ROOT,
  } = {},
) {
  const normalizedReport = normalizePromptRenderReport(report);
  const expectedPromptSha256 = sha256Text(normalizedReport.promptText);
  const canonicalPromptSha256 = sha256Text(readCanonicalPromptText(repoRoot));
  const envelopeFileExists = fs.existsSync(normalizedReport.envelopePath);
  let renderedEnvelopeReport = null;
  let renderedEnvelopeError = null;
  if (envelopeFileExists) {
    try {
      renderedEnvelopeReport = renderMissionControlPromptReport(
        {
          envelopePath: normalizedReport.envelopePath,
          promptPath: normalizedReport.promptPath,
        },
        {
          repoRoot,
          envelopePathSource: 'explicit',
          promptPathSource: 'explicit',
        },
      );
    } catch (error) {
      renderedEnvelopeError = error instanceof Error ? error.message : String(error);
    }
  }
  const promptFileExists = fs.existsSync(normalizedReport.promptPath);
  const promptFileText = promptFileExists ? normalizePromptArtifactText(readTextFile(normalizedReport.promptPath)) : null;
  const promptFileSha256 = promptFileText ? sha256Text(promptFileText) : null;
  const issues = [];

  const checks = {
    promptSha256MatchesText: normalizedReport.promptSha256 === expectedPromptSha256 ? 'passed' : 'failed',
    envelopeFileExists: envelopeFileExists ? 'passed' : 'failed',
    envelopeSha256MatchesReport: !envelopeFileExists || !renderedEnvelopeReport
      ? 'skipped'
      : normalizedReport.envelopeSha256 === renderedEnvelopeReport.envelopeSha256
        ? 'passed'
        : 'failed',
    operatorMatchesEnvelope: !envelopeFileExists || !renderedEnvelopeReport
      ? 'skipped'
      : JSON.stringify(normalizedReport.operator) === JSON.stringify(renderedEnvelopeReport.operator)
        ? 'passed'
        : 'failed',
    promptTextMatchesCanonicalContract: !envelopeFileExists || !renderedEnvelopeReport
      ? 'skipped'
      : normalizedReport.promptText === renderedEnvelopeReport.promptText
        ? 'passed'
        : 'failed',
    promptFileExists: promptFileExists ? 'passed' : 'failed',
    promptFileMatchesReport: !promptFileExists
      ? 'skipped'
      : promptFileText === normalizedReport.promptText
        ? 'passed'
        : 'failed',
    promptFileSha256MatchesReport: !promptFileExists
      ? 'skipped'
      : promptFileSha256 === normalizedReport.promptSha256
        ? 'passed'
        : 'failed',
  };

  if (checks.promptSha256MatchesText !== 'passed') {
    issues.push('prompt-sha256-mismatch');
  }
  if (checks.envelopeFileExists !== 'passed') {
    issues.push('envelope-file-missing');
  }
  if (renderedEnvelopeError) {
    issues.push('envelope-render-failed');
  }
  if (checks.envelopeSha256MatchesReport === 'failed') {
    issues.push('envelope-sha256-mismatch');
  }
  if (checks.operatorMatchesEnvelope === 'failed') {
    issues.push('operator-envelope-mismatch');
  }
  if (checks.promptTextMatchesCanonicalContract === 'failed') {
    issues.push('prompt-canonical-contract-drift');
  }
  if (checks.promptFileExists !== 'passed') {
    issues.push('prompt-file-missing');
  }
  if (checks.promptFileMatchesReport === 'failed') {
    issues.push('prompt-file-content-mismatch');
  }
  if (checks.promptFileSha256MatchesReport === 'failed') {
    issues.push('prompt-file-sha256-mismatch');
  }

  return {
    schema: MISSION_CONTROL_PROMPT_VALIDATION_SCHEMA,
    promptReportPath: null,
    envelopePath: normalizedReport.envelopePath,
    envelopeSha256: normalizedReport.envelopeSha256,
    promptPath: normalizedReport.promptPath,
    promptSha256: normalizedReport.promptSha256,
    canonicalPromptSha256,
    operator: normalizedReport.operator,
    checks,
    envelopeError: renderedEnvelopeError,
    issueCount: issues.length,
    issues,
    status: issues.length > 0 ? 'failed' : 'passed',
  };
}

export function validateMissionControlPromptReportFile(
  reportPath,
  {
    repoRoot = DEFAULT_REPO_ROOT,
    cwd = process.cwd(),
    source = 'explicit',
  } = {},
) {
  const resolvedReportPath = resolvePathFromBase(reportPath, source === 'default' ? repoRoot : cwd);
  const report = readJsonFile(resolvedReportPath);
  const validation = assessMissionControlPromptReport(report, { repoRoot });
  return {
    ...validation,
    promptReportPath: resolvedReportPath,
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    reportPath: DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH,
    reportPathSource: 'default',
    outputPath: DEFAULT_MISSION_CONTROL_PROMPT_VALIDATION_REPORT_PATH,
    outputPathSource: 'default',
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    const next = args[index + 1];
    if (token === '--report' || token === '--output') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--report') {
        options.reportPath = next;
        options.reportPathSource = 'explicit';
      }
      if (token === '--output') {
        options.outputPath = next;
        options.outputPathSource = 'explicit';
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printUsage(logFn = console.log) {
  logFn('Usage: node tools/priority/validate-mission-control-prompt.mjs [options]');
  logFn('');
  logFn('Validate a rendered mission-control prompt report against the canonical prompt contract.');
  logFn('');
  logFn(`  --report <path>   Prompt render report path (default: ${DEFAULT_MISSION_CONTROL_PROMPT_REPORT_PATH}).`);
  logFn(`  --output <path>   Validation output path (default: ${DEFAULT_MISSION_CONTROL_PROMPT_VALIDATION_REPORT_PATH}).`);
  logFn('  -h, --help        Show help.');
}

export function main(
  argv = process.argv,
  {
    repoRoot = DEFAULT_REPO_ROOT,
    cwd = process.cwd(),
    logFn = console.log,
    errorFn = console.error,
  } = {},
) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    printUsage(errorFn);
    return 1;
  }

  if (options.help) {
    printUsage(logFn);
    return 0;
  }

  try {
    const validation = validateMissionControlPromptReportFile(
      options.reportPath,
      {
        repoRoot,
        cwd,
        source: options.reportPathSource,
      },
    );
    const outputPath = resolvePathFromBase(options.outputPath, options.outputPathSource === 'default' ? repoRoot : cwd);
    writeJsonFile(outputPath, validation);
    logFn(`[mission-control:validate] report: ${outputPath}`);
    logFn(
      `[mission-control:validate] status=${validation.status} issues=${validation.issueCount} promptSha256=${validation.promptSha256}`,
    );
    return validation.status === 'passed' ? 0 : 1;
  } catch (error) {
    errorFn(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

export function isDirectExecution(argv = process.argv, metaUrl = import.meta.url) {
  const modulePath = path.resolve(fileURLToPath(metaUrl));
  const invokedPath = argv[1] ? path.resolve(argv[1]) : null;
  return Boolean(invokedPath && invokedPath === modulePath);
}

if (isDirectExecution(process.argv, import.meta.url)) {
  process.exitCode = main(process.argv);
}
