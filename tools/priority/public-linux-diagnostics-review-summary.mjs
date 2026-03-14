#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'public-linux-diagnostics-review-summary@v1';
export const DEFAULT_DISPATCH_RECEIPT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'diagnostics',
  'public-linux-diagnostics-workflow-dispatch.json'
);
export const DEFAULT_REVIEW_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'verification',
  'docker-review-loop-summary.json'
);
export const DEFAULT_DECISION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-decision.json'
);
export const DEFAULT_OUTPUT_JSON_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'diagnostics',
  'public-linux-diagnostics-review-summary.json'
);
export const DEFAULT_OUTPUT_MARKDOWN_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'diagnostics',
  'public-linux-diagnostics-review-summary.md'
);

function printUsage() {
  console.log('Usage: node tools/priority/public-linux-diagnostics-review-summary.mjs [options]');
  console.log('');
  console.log('Render a deterministic operator-facing summary for the public Linux diagnostics harness.');
  console.log('');
  console.log(`  --dispatch <path>         Hosted/local dispatch receipt (default: ${DEFAULT_DISPATCH_RECEIPT_PATH})`);
  console.log(`  --review-summary <path>   Docker parity agent summary (default: ${DEFAULT_REVIEW_SUMMARY_PATH})`);
  console.log(`  --decision <path>         Human go/no-go decision path (default: ${DEFAULT_DECISION_PATH})`);
  console.log(`  --out-json <path>         Summary JSON path (default: ${DEFAULT_OUTPUT_JSON_PATH})`);
  console.log(`  --out-md <path>           Summary Markdown path (default: ${DEFAULT_OUTPUT_MARKDOWN_PATH})`);
  console.log('  --json                    Print the JSON summary to stdout after writing it.');
  console.log('  -h, --help                Show help.');
}

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function toRepoPath(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.replace(/\\/g, '/') : null;
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function writeText(filePath, content) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, content, 'utf8');
  return resolved;
}

function loadJsonRequired(filePath, label) {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
  try {
    return JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${filePath}`);
  }
}

function loadJsonOptional(filePath, label) {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!fs.existsSync(resolved)) {
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${filePath}`);
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    dispatchPath: DEFAULT_DISPATCH_RECEIPT_PATH,
    reviewSummaryPath: DEFAULT_REVIEW_SUMMARY_PATH,
    decisionPath: DEFAULT_DECISION_PATH,
    outputJsonPath: DEFAULT_OUTPUT_JSON_PATH,
    outputMarkdownPath: DEFAULT_OUTPUT_MARKDOWN_PATH,
    json: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--json') {
      options.json = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--dispatch' ||
      token === '--review-summary' ||
      token === '--decision' ||
      token === '--out-json' ||
      token === '--out-md'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--dispatch') options.dispatchPath = next;
      if (token === '--review-summary') options.reviewSummaryPath = next;
      if (token === '--decision') options.decisionPath = next;
      if (token === '--out-json') options.outputJsonPath = next;
      if (token === '--out-md') options.outputMarkdownPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function buildMarkdownSummary(summary) {
  const lines = [
    '# Public Linux Diagnostics Review Summary',
    '',
    `- repository: \`${summary.target.repositorySlug}\``,
    `- reference: \`${summary.target.reference}\``,
    `- develop relationship: \`${summary.target.developRelationship}\``,
    `- diagnostics status: \`${summary.diagnostics.overallStatus}\``,
    `- ready for human decision: \`${summary.review.readyForHumanDecision}\``,
    `- human decision recorded: \`${summary.review.humanDecisionRecorded}\``,
    `- session complete: \`${summary.review.sessionComplete}\``,
    '',
    '## Review Order',
    ''
  ];

  for (const entry of summary.diagnostics.recommendedReviewOrder) {
    lines.push(`- \`${entry}\``);
  }

  lines.push('', '## Human Decision', '');
  if (summary.decision.state === 'pending') {
    lines.push(`- pending at \`${summary.decision.decisionPath}\``);
    lines.push(`- record disposition through \`${summary.decision.workflowPath}\``);
  } else {
    lines.push(`- decision: \`${summary.decision.value}\``);
    lines.push(`- recommended action: \`${summary.decision.recommendedAction}\``);
    lines.push(`- recorded by: \`${summary.decision.recordedBy}\``);
    lines.push(`- feedback: ${summary.decision.feedback}`);
  }

  return `${lines.join('\n')}\n`;
}

export function buildPublicLinuxDiagnosticsReviewSummary({
  dispatchReceipt,
  reviewSummary,
  decision,
  dispatchPath,
  reviewSummaryPath,
  decisionPath,
  outputJsonPath,
  outputMarkdownPath,
  generatedAt
}) {
  const diagnosticsPassed = normalizeText(reviewSummary?.overall?.status) === 'passed';
  const decisionValue = normalizeText(decision?.decision?.value);
  const decisionRecorded = Boolean(decision && decisionValue);

  return {
    schema: REPORT_SCHEMA,
    generatedAt,
    target: {
      repositorySlug: dispatchReceipt?.target?.repositorySlug ?? null,
      reference: dispatchReceipt?.target?.reference ?? null,
      developRelationship: dispatchReceipt?.target?.developRelationship ?? null
    },
    dispatch: {
      receiptPath: toRepoPath(dispatchPath),
      workflowPath: dispatchReceipt?.execution?.hostedWorkflowPath ?? null,
      workflowRunId: dispatchReceipt?.execution?.workflowRunId ?? null,
      workflowRunUrl: dispatchReceipt?.execution?.workflowRunUrl ?? null,
      status: dispatchReceipt?.status ?? null
    },
    diagnostics: {
      reviewSummaryPath: toRepoPath(reviewSummaryPath),
      reviewLoopReceiptPath: reviewSummary?.reviewLoopReceiptPath ?? reviewSummary?.artifacts?.reviewLoopReceiptPath ?? null,
      historySummaryPath: dispatchReceipt?.artifacts?.historySummaryPath ?? null,
      historyReportHtmlPath: dispatchReceipt?.artifacts?.historyReportHtmlPath ?? null,
      operatorSummaryPath: dispatchReceipt?.artifacts?.operatorSummaryPath ?? toRepoPath(reviewSummaryPath),
      overallStatus: reviewSummary?.overall?.status ?? null,
      failedCheck: reviewSummary?.overall?.failedCheck ?? '',
      message: reviewSummary?.overall?.message ?? '',
      recommendedReviewOrder: Array.isArray(reviewSummary?.recommendedReviewOrder)
        ? [...reviewSummary.recommendedReviewOrder]
        : []
    },
    decision: decisionRecorded
      ? {
          state: 'recorded',
          value: decisionValue,
          recommendedAction: decision?.nextIteration?.recommendedAction ?? null,
          feedback: decision?.decision?.feedback ?? null,
          recordedBy: decision?.decision?.recordedBy ?? null,
          workflowPath: decision?.workflow?.path ?? dispatchReceipt?.humanGoNoGo?.workflowPath ?? null,
          decisionPath: decision?.artifacts?.decisionPath ?? toRepoPath(decisionPath)
        }
      : {
          state: 'pending',
          value: null,
          recommendedAction: null,
          feedback: null,
          recordedBy: null,
          workflowPath: dispatchReceipt?.humanGoNoGo?.workflowPath ?? null,
          decisionPath: toRepoPath(decisionPath)
        },
    review: {
      readyForHumanDecision: diagnosticsPassed,
      humanDecisionRecorded: decisionRecorded,
      blocking: !diagnosticsPassed || decisionValue === 'nogo',
      sessionComplete: decisionRecorded,
      outputJsonPath: toRepoPath(outputJsonPath),
      outputMarkdownPath: toRepoPath(outputMarkdownPath)
    }
  };
}

export async function runPublicLinuxDiagnosticsReviewSummary({
  argv = process.argv,
  now = new Date(),
  loadJsonRequiredFn = loadJsonRequired,
  loadJsonOptionalFn = loadJsonOptional,
  writeJsonFn = writeJson,
  writeTextFn = writeText
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, payload: null, markdown: null, outputJsonPath: null, outputMarkdownPath: null };
  }

  const dispatchReceipt = loadJsonRequiredFn(options.dispatchPath, 'Dispatch receipt');
  const reviewSummary = loadJsonRequiredFn(options.reviewSummaryPath, 'Review summary');
  const decision = loadJsonOptionalFn(options.decisionPath, 'Human decision');
  const payload = buildPublicLinuxDiagnosticsReviewSummary({
    dispatchReceipt,
    reviewSummary,
    decision,
    dispatchPath: options.dispatchPath,
    reviewSummaryPath: options.reviewSummaryPath,
    decisionPath: options.decisionPath,
    outputJsonPath: options.outputJsonPath,
    outputMarkdownPath: options.outputMarkdownPath,
    generatedAt: now.toISOString()
  });
  const markdown = buildMarkdownSummary(payload);
  const outputJsonPath = writeJsonFn(options.outputJsonPath, payload);
  const outputMarkdownPath = writeTextFn(options.outputMarkdownPath, markdown);

  return {
    exitCode: 0,
    payload,
    markdown,
    outputJsonPath,
    outputMarkdownPath
  };
}

export async function main(argv = process.argv) {
  try {
    const result = await runPublicLinuxDiagnosticsReviewSummary({ argv });
    if (result.payload) {
      console.log(`[public-linux-diagnostics-review-summary] json: ${result.outputJsonPath}`);
      console.log(`[public-linux-diagnostics-review-summary] markdown: ${result.outputMarkdownPath}`);
      console.log(
        `[public-linux-diagnostics-review-summary] diagnostics=${result.payload.diagnostics.overallStatus} decision=${result.payload.decision.state}`
      );
      if (parseArgs(argv).json) {
        console.log(JSON.stringify(result.payload, null, 2));
      }
    }
    return result.exitCode;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then((exitCode) => {
    process.exit(exitCode);
  });
}
