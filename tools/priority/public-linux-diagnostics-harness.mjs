#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFile = promisify(execFileCallback);

export const REPORT_SCHEMA = 'public-linux-diagnostics-harness-local@v1';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'diagnostics',
  'public-linux-diagnostics-harness-local.json'
);
export const DEFAULT_CONTRACT_PATH = path.join(
  'docs',
  'schemas',
  'public-linux-diagnostics-harness-contract-v1.schema.json'
);
export const DEFAULT_CONTRACT_DOC_PATH = path.join('docs', 'PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md');
export const DEFAULT_REVIEW_LOOP_RECEIPT_PATH = path.join(
  'tests',
  'results',
  'docker-tools-parity',
  'review-loop-receipt.json'
);
export const DEFAULT_OPERATOR_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'verification',
  'docker-review-loop-summary.json'
);
export const DEFAULT_HISTORY_SUMMARY_PATH = path.join(
  'tests',
  'results',
  'docker-tools-parity',
  'ni-linux-review-suite',
  'vi-history-report',
  'results',
  'history-summary.json'
);
export const DEFAULT_HISTORY_REPORT_HTML_PATH = path.join(
  'tests',
  'results',
  'docker-tools-parity',
  'ni-linux-review-suite',
  'vi-history-report',
  'results',
  'history-report.html'
);
export const DEFAULT_HUMAN_DECISION_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'human-go-no-go-decision.json'
);
export const DEFAULT_HUMAN_WORKFLOW_PATH = '.github/workflows/human-go-no-go-feedback.yml';

function printUsage() {
  console.log(
    'Usage: node tools/priority/public-linux-diagnostics-harness.mjs --repository <owner/repo> --reference <ref> --develop-relationship <equal|ahead> [options]'
  );
  console.log('');
  console.log('Plans the local public-repo Linux diagnostics harness entry point and writes a deterministic receipt.');
  console.log('');
  console.log('Options:');
  console.log('  --repository <owner/repo>           Required public repository slug.');
  console.log('  --reference <ref>                   Required target branch/ref derived from develop.');
  console.log('  --develop-relationship <value>      Required: equal | ahead.');
  console.log(`  --report <path>                     Receipt path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --contract-schema <path>            Override shared contract schema path.');
  console.log('  --contract-doc <path>               Override shared contract doc path.');
  console.log('  --json                              Print the receipt JSON to stdout after writing it.');
  console.log('  -h, --help                          Show help.');
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

function normalizeRepository(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parts = normalized.split('/').map((part) => part.trim());
  if (parts.length !== 2 || parts.some((part) => part.length === 0)) {
    throw new Error(`--repository must use the form <owner>/<repo>; received '${value}'.`);
  }
  return `${parts[0]}/${parts[1]}`;
}

function normalizeDevelopRelationship(value) {
  const normalized = normalizeText(value)?.toLowerCase();
  if (normalized !== 'equal' && normalized !== 'ahead') {
    throw new Error('--develop-relationship must be one of: equal, ahead.');
  }
  return normalized;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repository: null,
    reference: null,
    developRelationship: null,
    reportPath: DEFAULT_REPORT_PATH,
    contractSchemaPath: DEFAULT_CONTRACT_PATH,
    contractDocPath: DEFAULT_CONTRACT_DOC_PATH,
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
      token === '--repository' ||
      token === '--reference' ||
      token === '--develop-relationship' ||
      token === '--report' ||
      token === '--contract-schema' ||
      token === '--contract-doc'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repository') options.repository = normalizeRepository(next);
      if (token === '--reference') options.reference = normalizeText(next);
      if (token === '--develop-relationship') options.developRelationship = normalizeDevelopRelationship(next);
      if (token === '--report') options.reportPath = next;
      if (token === '--contract-schema') options.contractSchemaPath = next;
      if (token === '--contract-doc') options.contractDocPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.repository) {
      throw new Error('--repository is required.');
    }
    if (!options.reference) {
      throw new Error('--reference is required.');
    }
    if (!options.developRelationship) {
      throw new Error('--develop-relationship is required.');
    }
  }

  return options;
}

async function inspectRepository(repository, execFileFn = execFile) {
  const { stdout } = await execFileFn(
    'gh',
    ['api', `repos/${repository}`],
    { encoding: 'utf8', windowsHide: true }
  );
  const payload = JSON.parse(stdout);
  return {
    visibility: normalizeText(payload.visibility) ?? 'unknown',
    defaultBranch: normalizeText(payload.default_branch) ?? null,
    htmlUrl: normalizeText(payload.html_url) ?? null
  };
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export function buildPublicLinuxDiagnosticsHarnessReceipt({
  options,
  repositoryInfo,
  generatedAt,
  repoRoot = process.cwd()
}) {
  const contractSchemaPath = toRepoPath(options.contractSchemaPath);
  const contractDocPath = toRepoPath(options.contractDocPath);
  const reportPath = toRepoPath(options.reportPath);

  return {
    schema: REPORT_SCHEMA,
    generatedAt,
    target: {
      repositorySlug: options.repository,
      repositoryVisibility: repositoryInfo.visibility,
      repositoryUrl: repositoryInfo.htmlUrl,
      reference: options.reference,
      defaultBranch: repositoryInfo.defaultBranch,
      developRelationship: options.developRelationship
    },
    contract: {
      schemaPath: contractSchemaPath,
      docPath: contractDocPath
    },
    execution: {
      mode: 'plan-only',
      entryCommand: 'pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite',
      entryArgs: [
        '-UseToolsImage',
        '-NILinuxReviewSuite',
        '-DockerParityReviewReceiptPath',
        toRepoPath(DEFAULT_REVIEW_LOOP_RECEIPT_PATH)
      ],
      repoRoot: repoRoot
    },
    artifacts: {
      receiptPath: reportPath,
      reviewLoopReceiptPath: toRepoPath(DEFAULT_REVIEW_LOOP_RECEIPT_PATH),
      historySummaryPath: toRepoPath(DEFAULT_HISTORY_SUMMARY_PATH),
      historyReportHtmlPath: toRepoPath(DEFAULT_HISTORY_REPORT_HTML_PATH),
      operatorSummaryPath: toRepoPath(DEFAULT_OPERATOR_SUMMARY_PATH)
    },
    humanGoNoGo: {
      required: true,
      workflowPath: toRepoPath(DEFAULT_HUMAN_WORKFLOW_PATH),
      decisionPath: toRepoPath(DEFAULT_HUMAN_DECISION_PATH)
    },
    status: 'planned'
  };
}

export async function runPublicLinuxDiagnosticsHarness({
  argv = process.argv,
  execFileFn = execFile,
  now = new Date(),
  repoRoot = process.cwd(),
  writeJsonFn = writeJson
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return {
      exitCode: 0,
      reportPath: null,
      payload: null
    };
  }

  const repositoryInfo = await inspectRepository(options.repository, execFileFn);
  if (repositoryInfo.visibility !== 'public') {
    throw new Error(
      `Repository ${options.repository} is not public (visibility=${repositoryInfo.visibility ?? 'unknown'}).`
    );
  }

  const payload = buildPublicLinuxDiagnosticsHarnessReceipt({
    options,
    repositoryInfo,
    generatedAt: now.toISOString(),
    repoRoot
  });
  const reportPath = writeJsonFn(options.reportPath, payload);
  return {
    exitCode: 0,
    reportPath,
    payload
  };
}

export async function main(argv = process.argv) {
  try {
    const result = await runPublicLinuxDiagnosticsHarness({ argv });
    if (result.payload) {
      console.log(`[public-linux-diagnostics-harness] report: ${result.reportPath}`);
      console.log(
        `[public-linux-diagnostics-harness] repository=${result.payload.target.repositorySlug} reference=${result.payload.target.reference} relationship=${result.payload.target.developRelationship}`
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
