#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFile = promisify(execFileCallback);

export const REPORT_SCHEMA = 'public-linux-diagnostics-harness-workflow-dispatch@v1';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'diagnostics',
  'public-linux-diagnostics-workflow-dispatch.json'
);
export const DEFAULT_CONTRACT_SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'public-linux-diagnostics-harness-contract-v1.schema.json'
);
export const DEFAULT_CONTRACT_DOC_PATH = path.join('docs', 'PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md');
export const DEFAULT_WORKFLOW_PATH = '.github/workflows/public-linux-diagnostics-harness.yml';
export const DEFAULT_DECISION_WORKFLOW_PATH = '.github/workflows/human-go-no-go-feedback.yml';
export const DEFAULT_REVIEW_LOOP_RECEIPT_PATH = path.join(
  'tests',
  'results',
  'docker-tools-parity',
  'review-loop-receipt.json'
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
export const DEFAULT_OPERATOR_SUMMARY_PATH = path.join(
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

function printUsage() {
  console.log(
    'Usage: node tools/priority/public-linux-diagnostics-workflow-dispatch.mjs --repository <owner/repo> --reference <ref> --develop-relationship <equal|ahead> [options]'
  );
  console.log('');
  console.log('Writes a deterministic plan-only receipt for the hosted public Linux diagnostics harness workflow.');
  console.log('');
  console.log('Options:');
  console.log('  --repository <owner/repo>           Required public repository slug.');
  console.log('  --reference <ref>                   Required target branch/ref derived from develop.');
  console.log('  --develop-relationship <value>      Required: equal | ahead.');
  console.log(`  --report <path>                     Receipt path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --workflow-path <path>              Workflow path (default: ${DEFAULT_WORKFLOW_PATH}).`);
  console.log(`  --decision-workflow-path <path>     Human decision workflow path (default: ${DEFAULT_DECISION_WORKFLOW_PATH}).`);
  console.log(`  --contract-schema <path>            Shared contract schema path (default: ${DEFAULT_CONTRACT_SCHEMA_PATH}).`);
  console.log(`  --contract-doc <path>               Shared contract doc path (default: ${DEFAULT_CONTRACT_DOC_PATH}).`);
  console.log('  --step-summary <path>               Optional GitHub step summary path.');
  console.log('  --json                              Print the receipt JSON after writing it.');
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

export function parseArgs(argv = process.argv, environment = process.env) {
  const args = argv.slice(2);
  const options = {
    help: false,
    repository: null,
    reference: null,
    developRelationship: null,
    reportPath: DEFAULT_REPORT_PATH,
    workflowPath: DEFAULT_WORKFLOW_PATH,
    decisionWorkflowPath: DEFAULT_DECISION_WORKFLOW_PATH,
    contractSchemaPath: DEFAULT_CONTRACT_SCHEMA_PATH,
    contractDocPath: DEFAULT_CONTRACT_DOC_PATH,
    stepSummaryPath: normalizeText(environment.GITHUB_STEP_SUMMARY),
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
      token === '--workflow-path' ||
      token === '--decision-workflow-path' ||
      token === '--contract-schema' ||
      token === '--contract-doc' ||
      token === '--step-summary'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repository') options.repository = normalizeRepository(next);
      if (token === '--reference') options.reference = normalizeText(next);
      if (token === '--develop-relationship') options.developRelationship = normalizeDevelopRelationship(next);
      if (token === '--report') options.reportPath = next;
      if (token === '--workflow-path') options.workflowPath = next;
      if (token === '--decision-workflow-path') options.decisionWorkflowPath = next;
      if (token === '--contract-schema') options.contractSchemaPath = next;
      if (token === '--contract-doc') options.contractDocPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
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

function appendStepSummary(stepSummaryPath, payload) {
  if (!stepSummaryPath) {
    return;
  }
  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  const lines = [
    '### Public Linux Diagnostics Harness Dispatch',
    '',
    `- repository: \`${payload.target.repositorySlug}\``,
    `- reference: \`${payload.target.reference}\``,
    `- develop relationship: \`${payload.target.developRelationship}\``,
    `- workflow: \`${payload.execution.hostedWorkflowPath}\``,
    `- status: \`${payload.status}\``,
    '',
    `Record the final manual disposition through \`${payload.humanGoNoGo.workflowPath}\` once the diagnostics bundle has been reviewed.`
  ];
  fs.writeFileSync(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' });
}

export function buildPublicLinuxDiagnosticsWorkflowDispatchReceipt({
  options,
  repositoryInfo,
  generatedAt,
  environment = process.env
}) {
  const runId = normalizeText(environment.GITHUB_RUN_ID);
  const serverUrl = normalizeText(environment.GITHUB_SERVER_URL) ?? 'https://github.com';
  const repositorySlug = normalizeText(environment.GITHUB_REPOSITORY);

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
      schemaPath: toRepoPath(options.contractSchemaPath),
      docPath: toRepoPath(options.contractDocPath)
    },
    execution: {
      mode: 'plan-only',
      hostedWorkflowPath: toRepoPath(options.workflowPath),
      workflowRunId: runId,
      workflowRunUrl: runId && repositorySlug ? `${serverUrl}/${repositorySlug}/actions/runs/${runId}` : null,
      localDelegateCommand: 'pwsh -NoLogo -NoProfile -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite'
    },
    artifacts: {
      reviewLoopReceiptPath: toRepoPath(DEFAULT_REVIEW_LOOP_RECEIPT_PATH),
      historySummaryPath: toRepoPath(DEFAULT_HISTORY_SUMMARY_PATH),
      historyReportHtmlPath: toRepoPath(DEFAULT_HISTORY_REPORT_HTML_PATH),
      operatorSummaryPath: toRepoPath(DEFAULT_OPERATOR_SUMMARY_PATH),
      dispatchReceiptPath: toRepoPath(options.reportPath)
    },
    humanGoNoGo: {
      required: true,
      workflowPath: toRepoPath(options.decisionWorkflowPath),
      decisionPath: toRepoPath(DEFAULT_DECISION_PATH)
    },
    status: 'planned'
  };
}

export async function runPublicLinuxDiagnosticsWorkflowDispatch({
  argv = process.argv,
  environment = process.env,
  execFileFn = execFile,
  now = new Date(),
  writeJsonFn = writeJson,
  appendStepSummaryFn = appendStepSummary
} = {}) {
  const options = parseArgs(argv, environment);
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

  const payload = buildPublicLinuxDiagnosticsWorkflowDispatchReceipt({
    options,
    repositoryInfo,
    generatedAt: now.toISOString(),
    environment
  });
  const reportPath = writeJsonFn(options.reportPath, payload);
  appendStepSummaryFn(options.stepSummaryPath, payload);

  return {
    exitCode: 0,
    reportPath,
    payload
  };
}

export async function main(argv = process.argv) {
  try {
    const result = await runPublicLinuxDiagnosticsWorkflowDispatch({ argv });
    if (result.payload) {
      console.log(`[public-linux-diagnostics-workflow-dispatch] report: ${result.reportPath}`);
      console.log(
        `[public-linux-diagnostics-workflow-dispatch] repository=${result.payload.target.repositorySlug} reference=${result.payload.target.reference} relationship=${result.payload.target.developRelationship}`
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
