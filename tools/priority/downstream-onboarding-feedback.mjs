#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { main as runDownstreamOnboarding } from './downstream-onboarding.mjs';
import { main as runDownstreamOnboardingSuccess } from './downstream-onboarding-success.mjs';

export const DEFAULT_FEEDBACK_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding-feedback.json'
);

export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding.json'
);

export const DEFAULT_SUCCESS_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'onboarding',
  'downstream-onboarding-success.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/downstream-onboarding-feedback.mjs --repo <owner/repo> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>             Downstream repository to evaluate (required).');
  console.log('  --started-at <ISO-8601>         Optional onboarding start timestamp.');
  console.log('  --parent-issue <n>              Parent issue number for traceability.');
  console.log(`  --report <path>                 Onboarding report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(
    `  --success-output <path>         Success report path (default: ${DEFAULT_SUCCESS_OUTPUT_PATH}).`
  );
  console.log(
    `  --feedback-output <path>        Feedback status report path (default: ${DEFAULT_FEEDBACK_OUTPUT_PATH}).`
  );
  console.log('  --create-hardening-issues       Allow issue creation in onboarding/success helpers.');
  console.log('  --fail-on-gap                   Propagate onboarding required-gap failures.');
  console.log('  -h, --help                      Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    downstreamRepo: null,
    startedAt: null,
    parentIssue: null,
    reportPath: DEFAULT_REPORT_PATH,
    successOutputPath: DEFAULT_SUCCESS_OUTPUT_PATH,
    feedbackOutputPath: DEFAULT_FEEDBACK_OUTPUT_PATH,
    createHardeningIssues: false,
    failOnGap: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--create-hardening-issues') {
      options.createHardeningIssues = true;
      continue;
    }
    if (token === '--fail-on-gap') {
      options.failOnGap = true;
      continue;
    }
    if (
      token === '--repo' ||
      token === '--started-at' ||
      token === '--report' ||
      token === '--success-output' ||
      token === '--feedback-output'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.downstreamRepo = next;
      if (token === '--started-at') options.startedAt = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--success-output') options.successOutputPath = next;
      if (token === '--feedback-output') options.feedbackOutputPath = next;
      continue;
    }
    if (token === '--parent-issue') {
      if (!next || next.startsWith('-')) {
        throw new Error('Missing value for --parent-issue.');
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 1) {
        throw new Error(`Invalid --parent-issue value: ${next}`);
      }
      options.parentIssue = parsed;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !options.downstreamRepo) {
    throw new Error('Missing required option: --repo <owner/repo>.');
  }

  return options;
}

function ensureParentDirectory(filePath) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  return resolvedPath;
}

function fileExists(filePath) {
  return fs.existsSync(path.resolve(filePath));
}

function writeJson(filePath, payload) {
  const resolvedPath = ensureParentDirectory(filePath);
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export function buildFeedbackReport({
  options,
  evaluateExitCode,
  successExitCode,
  reportExists,
  successReportExists,
  generatedAt
}) {
  return {
    schema: 'priority/downstream-onboarding-feedback@v1',
    generatedAt,
    inputs: {
      downstreamRepository: options.downstreamRepo,
      startedAt: options.startedAt ?? null,
      parentIssue: options.parentIssue ?? null,
      createHardeningIssues: options.createHardeningIssues,
      failOnGap: options.failOnGap
    },
    outputs: {
      onboardingReportPath: path.resolve(options.reportPath),
      successReportPath: path.resolve(options.successOutputPath),
      onboardingReportExists: reportExists,
      successReportExists: successReportExists
    },
    execution: {
      evaluateExitCode,
      successExitCode,
      status: evaluateExitCode === 0 && successExitCode === 0 ? 'pass' : 'fail'
    }
  };
}

function buildOnboardingArgv(options) {
  const argv = [
    'node',
    'downstream-onboarding.mjs',
    '--repo',
    options.downstreamRepo,
    '--output',
    options.reportPath
  ];
  if (options.startedAt) {
    argv.push('--started-at', options.startedAt);
  }
  if (options.parentIssue) {
    argv.push('--parent-issue', String(options.parentIssue));
  }
  if (options.createHardeningIssues) {
    argv.push('--create-hardening-issues');
  }
  if (options.failOnGap) {
    argv.push('--fail-on-gap');
  }
  return argv;
}

function buildSuccessArgv(options) {
  const argv = [
    'node',
    'downstream-onboarding-success.mjs',
    '--report',
    options.reportPath,
    '--output',
    options.successOutputPath
  ];
  if (options.parentIssue) {
    argv.push('--parent-issue', String(options.parentIssue));
  }
  if (options.createHardeningIssues) {
    argv.push('--create-hardening-issues');
  }
  return argv;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const evaluateExitCode = await runDownstreamOnboarding(buildOnboardingArgv(options));
  const reportExists = fileExists(options.reportPath);
  const successExitCode = reportExists ? await runDownstreamOnboardingSuccess(buildSuccessArgv(options)) : 1;
  const successReportExists = fileExists(options.successOutputPath);
  const feedbackReport = buildFeedbackReport({
    options,
    evaluateExitCode,
    successExitCode,
    reportExists,
    successReportExists,
    generatedAt: new Date().toISOString()
  });
  const feedbackOutputPath = writeJson(options.feedbackOutputPath, feedbackReport);
  console.log(
    `[downstream-onboarding-feedback] wrote ${feedbackOutputPath} (status=${feedbackReport.execution.status}, report=${reportExists}, success=${successReportExists})`
  );
  return feedbackReport.execution.status === 'pass' ? 0 : 1;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) process.exitCode = code;
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}
