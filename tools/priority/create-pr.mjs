#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  run,
  getRepoRoot
} from './lib/branch-utils.mjs';
import {
  ensureGhCli,
  resolveUpstream,
  ensureForkRemote,
  resolveActiveForkRemoteName,
  pushBranch,
  runGhPrCreate,
  parseRepositorySlug
} from './lib/remote-utils.mjs';

const ROUTER_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'router.json');
const CACHE_RELATIVE_PATH = '.agent_priority_cache.json';
const NO_STANDING_REPORT_RELATIVE_PATH = path.join('tests', 'results', '_agent', 'issue', 'no-standing-priority.json');
const DEFAULT_PR_TEMPLATE_RELATIVE_PATH = path.join('.github', 'pull_request_template.md');
const DEFAULT_REPORT_DIR = path.join('tests', 'results', '_agent', 'issue');
const STANDING_PRIORITY_LABELS = new Set(['standing-priority', 'fork-standing-priority']);
const USAGE_LINES = [
  'Usage: node tools/npm/run-script.mjs priority:pr -- [options]',
  '',
  'Opens a pull request for the current branch (or an explicit branch), using the fork-aware helper contract.',
  '',
  'Options:',
  '  --repo <owner/repo>     Upstream repository override.',
  '  --issue <number>        Explicit issue number override.',
  '  --branch <name>         Branch to open instead of the current checkout.',
  '  --base <name>           Base branch (default: develop).',
  '  --title <text>          Explicit pull request title.',
  '  --body <text>           Explicit pull request body.',
  '  --body-file <path>      Read the pull request body from a file.',
  `  --report-dir <path>     Directory for the machine-readable report (default: ${DEFAULT_REPORT_DIR}).`,
  '  --head-remote <name>    Fork remote to push/open from (default: AGENT_PRIORITY_ACTIVE_FORK_REMOTE or origin).',
  '  -h, --help              Show this message and exit.'
];

export function printUsage(lines = USAGE_LINES) {
  for (const line of lines) {
    console.log(line);
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repository: null,
    issue: null,
    branch: null,
    base: null,
    title: null,
    body: null,
    bodyFile: null,
    reportDir: DEFAULT_REPORT_DIR,
    headRemote: null,
    help: false
  };

  const tokensRequiringValue = new Set([
    '--repo',
    '--issue',
    '--branch',
    '--base',
    '--title',
    '--body',
    '--body-file',
    '--report-dir',
    '--head-remote'
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (tokensRequiringValue.has(token)) {
      if (next === undefined) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (token !== '--body' && next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repository = next;
      if (token === '--issue') {
        options.issue = toPositiveInteger(next);
        if (!options.issue) {
          throw new Error(`Invalid issue number for ${token}: ${next}`);
        }
      }
      if (token === '--branch') options.branch = next;
      if (token === '--base') options.base = next;
      if (token === '--title') options.title = next;
      if (token === '--body') options.body = next;
      if (token === '--body-file') options.bodyFile = next;
      if (token === '--report-dir') options.reportDir = next;
      if (token === '--head-remote') options.headRemote = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.body && options.bodyFile) {
    throw new Error('Use either --body or --body-file, not both.');
  }

  return options;
}

export function ensurePrSourceBranch(branch) {
  if (!branch || branch === 'HEAD') {
    throw new Error('Detached HEAD state detected; checkout a branch first.');
  }
  if (['develop', 'main'].includes(branch)) {
    throw new Error(`Refusing to open a PR directly from ${branch}. Create a feature branch first.`);
  }
  return branch;
}

export function detectCurrentBranch(repoRoot, runFn = run) {
  return runFn('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot });
}

export function readJsonFile(filePath, readFileSyncFn = readFileSync) {
  try {
    return JSON.parse(readFileSyncFn(filePath, 'utf8'));
  } catch {
    return null;
  }
}

export function readBodyFromFile(filePath, readFileSyncFn = readFileSync) {
  const body = readFileSyncFn(filePath, 'utf8');
  if (!String(body || '').trim()) {
    throw new Error(`Pull request body file '${filePath}' is empty.`);
  }
  return body;
}

function toPositiveInteger(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }
  return number;
}

export function parseRouterIssueNumber(router) {
  if (!router || typeof router !== 'object') {
    return null;
  }
  if (!Object.prototype.hasOwnProperty.call(router, 'issue')) {
    return null;
  }
  return toPositiveInteger(router.issue);
}

export function parseCacheIssueNumber(cache) {
  if (!cache || typeof cache !== 'object') {
    return null;
  }

  const number = toPositiveInteger(cache.number ?? cache.issue?.number);
  if (!number) {
    return null;
  }

  const state = String(cache.state ?? cache.issue?.state ?? '').trim().toUpperCase();
  if (state && state !== 'OPEN') {
    return null;
  }

  const labels = Array.isArray(cache.labels)
    ? cache.labels
    : Array.isArray(cache.issue?.labels)
      ? cache.issue.labels
      : [];
  if (labels.length > 0) {
    const normalized = labels
      .map((label) => {
        if (typeof label === 'string') {
          return label.toLowerCase();
        }
        if (label && typeof label === 'object' && typeof label.name === 'string') {
          return label.name.toLowerCase();
        }
        return null;
      })
      .filter(Boolean);
    const hasStandingLabel = normalized.some((label) => STANDING_PRIORITY_LABELS.has(label));
    if (!hasStandingLabel) {
      return null;
    }
  }

  return number;
}

export function parseCacheNoStandingReason(cache) {
  if (!cache || typeof cache !== 'object') {
    return null;
  }

  const state = String(cache.state ?? cache.issue?.state ?? '').trim().toUpperCase();
  if (state !== 'NONE') {
    return null;
  }

  const reason = String(cache.noStandingReason ?? cache.issue?.noStandingReason ?? '').trim().toLowerCase();
  return reason || null;
}

function extractIssueTitle(cache) {
  const value = cache?.title ?? cache?.issue?.title;
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function extractIssueUrl(cache, mirrorOf = null) {
  if (typeof mirrorOf?.url === 'string' && mirrorOf.url.trim()) {
    return mirrorOf.url.trim();
  }
  const value = cache?.url ?? cache?.issue?.url;
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

export function parseNoStandingReasonFromReport(report) {
  if (!report || typeof report !== 'object') {
    return null;
  }

  const schema = String(report.schema ?? '').trim().toLowerCase();
  if (schema && schema !== 'standing-priority/no-standing@v1') {
    return null;
  }

  const reason = String(report.reason ?? '').trim().toLowerCase();
  return reason || null;
}

export function resolveStandingIssueNumberForPr(repoRoot, { readJsonFn = readJsonFile } = {}) {
  const router = readJsonFn(path.join(repoRoot, ROUTER_RELATIVE_PATH));
  const cache = readJsonFn(path.join(repoRoot, CACHE_RELATIVE_PATH));
  const noStandingReport = readJsonFn(path.join(repoRoot, NO_STANDING_REPORT_RELATIVE_PATH));
  const noStandingReason = parseCacheNoStandingReason(cache) || parseNoStandingReasonFromReport(noStandingReport);
  const mirrorOf =
    cache?.mirrorOf &&
    Number.isInteger(Number(cache.mirrorOf.number)) &&
    Number(cache.mirrorOf.number) > 0
      ? {
          number: Number(cache.mirrorOf.number),
          repository: typeof cache.mirrorOf.repository === 'string' ? cache.mirrorOf.repository : null,
          url: typeof cache.mirrorOf.url === 'string' ? cache.mirrorOf.url : null
        }
      : null;
  const localIssueNumber =
    router && Object.prototype.hasOwnProperty.call(router, 'issue')
      ? parseRouterIssueNumber(router)
      : parseCacheIssueNumber(cache);
  const cacheIssueNumber = parseCacheIssueNumber(cache);
  const shouldUseCachedMetadata =
    Boolean(cacheIssueNumber) &&
    ((localIssueNumber && cacheIssueNumber === localIssueNumber) ||
      (mirrorOf?.number && cacheIssueNumber === mirrorOf.number));
  const issueTitle = shouldUseCachedMetadata ? extractIssueTitle(cache) : null;
  const issueUrl = shouldUseCachedMetadata ? extractIssueUrl(cache, mirrorOf) : null;
  if (router && Object.prototype.hasOwnProperty.call(router, 'issue')) {
    if (!localIssueNumber) {
      return {
        issueNumber: null,
        localIssueNumber: null,
        issueTitle: null,
        issueUrl: null,
        source: 'router',
        noStandingReason,
        mirrorOf: null
      };
    }

    return {
      issueNumber: mirrorOf?.number ?? localIssueNumber,
      localIssueNumber,
      issueTitle,
      issueUrl,
      source: 'router',
      noStandingReason,
      mirrorOf
    };
  }

  return {
    issueNumber: mirrorOf?.number ?? localIssueNumber,
    localIssueNumber,
    issueTitle,
    issueUrl,
    source: 'cache',
    noStandingReason,
    mirrorOf
  };
}

export function parseIssueNumberFromBranch(branch) {
  const match = String(branch || '').match(/^issue\/(?:(?<fork>[a-z0-9._-]+)-)?(?<issue>\d+)(?:-|$)/i);
  if (!match?.groups?.issue) {
    return null;
  }
  return toPositiveInteger(match.groups.issue);
}

export function assertBranchMatchesIssue(branch, issueNumber) {
  const branchIssueNumber = parseIssueNumberFromBranch(branch);
  if (!branchIssueNumber || !issueNumber) {
    return;
  }
  if (branchIssueNumber !== issueNumber) {
    throw new Error(
      `Current branch '${branch}' maps to #${branchIssueNumber}, but standing priority resolves to #${issueNumber}. ` +
        'Run bootstrap, then rename/switch to the standing-priority issue branch before creating a PR.'
    );
  }
}

export function buildTitle(branch, issueNumber, env = process.env) {
  if (env.PR_TITLE) {
    return env.PR_TITLE;
  }
  if (issueNumber) {
    return `Update for standing priority #${issueNumber}`;
  }
  return `Update ${branch}`;
}

function normalizePrBodyContext(issueOrContext) {
  if (issueOrContext && typeof issueOrContext === 'object' && !Array.isArray(issueOrContext)) {
    return {
      issueNumber: toPositiveInteger(issueOrContext.issueNumber ?? issueOrContext.issue ?? null),
      issueTitle: typeof issueOrContext.issueTitle === 'string' ? issueOrContext.issueTitle.trim() : '',
      issueUrl: typeof issueOrContext.issueUrl === 'string' ? issueOrContext.issueUrl.trim() : '',
      branch: typeof issueOrContext.branch === 'string' ? issueOrContext.branch.trim() : '',
      base: typeof issueOrContext.base === 'string' ? issueOrContext.base.trim() : ''
    };
  }

  return {
    issueNumber: toPositiveInteger(issueOrContext),
    issueTitle: '',
    issueUrl: '',
    branch: '',
    base: ''
  };
}

function formatIssueReference(issueNumber, issueTitle = '') {
  if (!issueNumber) {
    return 'Not linked yet';
  }
  const titleSuffix = issueTitle ? ` - ${issueTitle}` : '';
  return `#${issueNumber}${titleSuffix}`;
}

function buildSummaryLine(context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  if (context.issueNumber) {
    return `Delivers issue ${issueReference} into \`${base}\` using the standard automation PR helper.`;
  }
  return `Delivers branch \`${context.branch || '(not supplied)'}\` into \`${base}\` using the standard automation PR helper.`;
}

function renderFallbackAutomationBody(context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  const lines = [
    '# Summary',
    '',
    buildSummaryLine(context, base),
    '',
    '## Agent Metadata (required for automation-authored PRs)',
    '',
    '- Agent-ID: `agent/copilot-codex-a`',
    '- Operator: `@svelderrainruiz`',
    '- Reviewer-Required: `@svelderrainruiz`',
    '- Emergency-Bypass-Label: `AllowCIBypass`',
    '',
    '## Change Surface',
    '',
    `- Primary issue or standing-priority context: ${issueReference}`,
    `- Issue URL: ${context.issueUrl || '(not supplied)'}`,
    `- Files, tools, workflows, or policies touched: Helper-driven PR creation path for \`${context.branch || '(not supplied)'}\`.`,
    `- Required checks, merge-queue behavior, or approval flows affected: Standard \`${base}\` branch protections and required checks apply.`
  ];
  return lines.join('\n').trimEnd();
}

function renderDefaultAutomationTemplate(templateText, context, base) {
  const issueReference = formatIssueReference(context.issueNumber, context.issueTitle);
  const issueUrl = context.issueUrl || '(not supplied)';
  const branch = context.branch || '(not supplied)';
  const lines = String(templateText || '').replace(/\r\n/g, '\n').split('\n');
  const rendered = [];
  let inSummarySection = false;
  let summaryInserted = false;

  for (const line of lines) {
    if (line === '# Summary') {
      rendered.push(line, '', buildSummaryLine(context, base));
      inSummarySection = true;
      summaryInserted = true;
      continue;
    }

    if (inSummarySection) {
      if (line.startsWith('## ')) {
        inSummarySection = false;
        rendered.push('', line);
        continue;
      }
      continue;
    }

    if (line.startsWith('- Primary issue or standing-priority context:')) {
      rendered.push(`- Primary issue or standing-priority context: ${issueReference}`);
      rendered.push(`- Issue URL: ${issueUrl}`);
      continue;
    }
    if (line.startsWith('- Files, tools, workflows, or policies touched:')) {
      rendered.push(`- Files, tools, workflows, or policies touched: Helper-driven PR creation path for \`${branch}\`.`);
      continue;
    }
    if (line.startsWith('- Cross-repo or external-consumer impact:')) {
      rendered.push('- Cross-repo or external-consumer impact: None expected at PR creation time.');
      continue;
    }
    if (line.startsWith('- Required checks, merge-queue behavior, or approval flows affected:')) {
      rendered.push(`- Required checks, merge-queue behavior, or approval flows affected: Standard \`${base}\` branch protections and required checks apply.`);
      continue;
    }
    if (line.trim() === '- `node tools/npm/run-script.mjs <script>`') {
      rendered.push('  - None yet; this body was generated during PR creation.');
      continue;
    }
    if (line.trim() === '- `tests/results/...`') {
      rendered.push('  - None yet.');
      continue;
    }
    if (line.trim() === '- None or explain why') {
      rendered.push('  - Validation is deferred until implementation commits land on the branch.');
      continue;
    }
    if (line.startsWith('- Residual risks:')) {
      rendered.push('- Residual risks: This body should be refreshed if the branch scope changes materially before merge.');
      continue;
    }
    if (line.startsWith('- Follow-up issues or deferred work:')) {
      rendered.push('- Follow-up issues or deferred work: None at PR creation time.');
      continue;
    }
    if (line.startsWith('- Deployment, approval, or rollback notes:')) {
      rendered.push('- Deployment, approval, or rollback notes: Standard PR review and required-check flow.');
      continue;
    }
    if (line.startsWith('- Please verify:')) {
      rendered.push('- Please verify: issue linkage, branch/base selection, and metadata routing are correct.');
      continue;
    }
    if (line.startsWith('- Areas where the reasoning is subtle:')) {
      rendered.push('- Areas where the reasoning is subtle: None at PR creation time.');
      continue;
    }
    if (line.startsWith('- Manual spot checks requested:')) {
      rendered.push('- Manual spot checks requested: None.');
      continue;
    }

    rendered.push(line);
  }

  if (!summaryInserted) {
    rendered.unshift('# Summary', '', buildSummaryLine(context, base), '');
  }

  return rendered.join('\n').trimEnd();
}

export function buildBody(issueOrContext, env = process.env, { repoRoot = process.cwd(), readFileSyncFn = readFileSync } = {}) {
  if (env.PR_BODY) {
    return env.PR_BODY;
  }
  const context = normalizePrBodyContext(issueOrContext);
  const base = context.base || env.PR_BASE || 'develop';
  const closesLine = context.issueNumber ? `\n\nCloses #${context.issueNumber}` : '';

  try {
    const templateText = readFileSyncFn(path.join(repoRoot, DEFAULT_PR_TEMPLATE_RELATIVE_PATH), 'utf8');
    return `${renderDefaultAutomationTemplate(templateText, context, base)}${closesLine}`.trimEnd();
  } catch {
    return `${renderFallbackAutomationBody(context, base)}${closesLine}`.trimEnd();
  }
}

export function resolveBody({ options, issueNumber, env = process.env, readFileSyncFn = readFileSync }) {
  if (options.bodyFile) {
    return readBodyFromFile(options.bodyFile, readFileSyncFn);
  }
  if (env.PR_BODY_FILE) {
    return readBodyFromFile(env.PR_BODY_FILE, readFileSyncFn);
  }
  if (options.body) {
    return options.body;
  }
  return buildBody(
    {
      issueNumber,
      issueTitle: options.issueTitle ?? '',
      issueUrl: options.issueUrl ?? '',
      branch: options.branch ?? env.PR_BRANCH ?? '',
      base: options.base ?? env.PR_BASE ?? ''
    },
    env,
    {
      repoRoot: options.repoRoot ?? process.cwd(),
      readFileSyncFn
    }
  );
}

export function createPriorityPr({
  env = process.env,
  options = {},
  readFileSyncFn = readFileSync,
  getRepoRootFn = getRepoRoot,
  getCurrentBranchFn = detectCurrentBranch,
  ensureGhCliFn = ensureGhCli,
  resolveUpstreamFn = resolveUpstream,
  ensureForkRemoteFn = ensureForkRemote,
  pushBranchFn = pushBranch,
  runGhPrCreateFn = runGhPrCreate,
  resolveStandingIssueNumberFn = resolveStandingIssueNumberForPr
} = {}) {
  const repoRoot = getRepoRootFn();
  const branch = ensurePrSourceBranch(options.branch || getCurrentBranchFn(repoRoot));

  ensureGhCliFn();

  const resolvedIssue =
    options.issue && toPositiveInteger(options.issue)
      ? {
          issueNumber: toPositiveInteger(options.issue),
          localIssueNumber: toPositiveInteger(options.issue),
          source: 'cli',
          noStandingReason: null,
          mirrorOf: null
        }
      : resolveStandingIssueNumberFn(repoRoot);
  const issueNumber = resolvedIssue?.issueNumber ?? null;
  const localIssueNumber = resolvedIssue?.localIssueNumber ?? issueNumber;
  if (!issueNumber && resolvedIssue?.noStandingReason === 'queue-empty') {
    throw new Error('Standing-priority queue is empty; create or label the next issue before opening a priority PR.');
  }
  assertBranchMatchesIssue(branch, localIssueNumber);
  const upstream = options.repository ? parseRepositorySlug(options.repository) : resolveUpstreamFn(repoRoot);
  const headRemote = options.headRemote || env.PR_HEAD_REMOTE || resolveActiveForkRemoteName(env);
  const headRepository = ensureForkRemoteFn(repoRoot, upstream, headRemote);

  const pushResult = pushBranchFn(repoRoot, branch, headRemote);
  const base = options.base || env.PR_BASE || 'develop';
  const title = options.title || buildTitle(branch, issueNumber, env);
  const body = resolveBody({
    options: {
      ...options,
      branch,
      base,
      issueTitle: resolvedIssue?.issueTitle ?? '',
      issueUrl: resolvedIssue?.issueUrl ?? '',
      repoRoot
    },
    issueNumber,
    env,
    readFileSyncFn
  });

  const prResult = runGhPrCreateFn({
    repoRoot,
    upstream,
    headRepository,
    branch,
    base,
    title,
    body
  });

  return {
    repoRoot,
    branch,
    base,
    issueNumber,
    localIssueNumber,
    issueSource: resolvedIssue?.source ?? null,
    mirrorOf: resolvedIssue?.mirrorOf ?? null,
    title,
    body,
    pushStatus: pushResult?.status ?? null,
    upstream,
    headRemote,
    headRepository,
    strategy: prResult?.strategy ?? null,
    pullRequest: prResult?.pullRequest ?? null,
    reusedExistingPullRequest: prResult?.reusedExisting === true
  };
}

export function buildPriorityPrReport(result, generatedAt = new Date().toISOString()) {
  return {
    schema: 'priority/pr-create@v1',
    generatedAt,
    issue: {
      upstreamNumber: result.issueNumber ?? null,
      localNumber: result.localIssueNumber ?? null,
      source: result.issueSource ?? null,
      mirrorOf: result.mirrorOf ?? null
    },
    upstream: {
      repository:
        result.upstream?.owner && result.upstream?.repo ? `${result.upstream.owner}/${result.upstream.repo}` : null
    },
    head: {
      remote: result.headRemote ?? null,
      repository:
        result.headRepository?.owner && result.headRepository?.repo
          ? `${result.headRepository.owner}/${result.headRepository.repo}`
          : null,
      branch: result.branch ?? null
    },
    base: result.base ?? null,
    pushStatus: result.pushStatus ?? null,
    strategy: result.strategy ?? null,
    reusedExistingPullRequest: result.reusedExistingPullRequest === true,
    pullRequest: result.pullRequest
      ? {
          number: result.pullRequest.number ?? null,
          url: result.pullRequest.url ?? null,
          isDraft: result.pullRequest.isDraft ?? null
        }
      : null
  };
}

export function writePriorityPrReport(
  result,
  {
    reportDir = DEFAULT_REPORT_DIR,
    mkdirSyncFn = mkdirSync,
    writeFileSyncFn = writeFileSync,
    getNow = () => new Date().toISOString()
  } = {}
) {
  const repoRoot = result?.repoRoot || process.cwd();
  const resolvedReportDir = path.isAbsolute(reportDir) ? reportDir : path.join(repoRoot, reportDir);
  const fileIssueNumber = result?.localIssueNumber ?? result?.issueNumber ?? 'branch';
  const fileRemote = String(result?.headRemote || 'origin').replace(/[^a-z0-9._-]/gi, '-');
  const reportPath = path.join(resolvedReportDir, `priority-pr-create-${fileRemote}-${fileIssueNumber}.json`);
  const report = buildPriorityPrReport(result, getNow());
  mkdirSyncFn(resolvedReportDir, { recursive: true });
  writeFileSyncFn(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return { report, reportPath };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const result = createPriorityPr({ options });
  const reportResult = writePriorityPrReport(result, { reportDir: options.reportDir });
  if (result?.strategy) {
    console.log(`[priority:create-pr] strategy=${result.strategy}`);
  }
  console.log(`[priority:create-pr] report=${reportResult.reportPath}`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const code = main(process.argv);
    if (code !== 0) {
      process.exitCode = code;
    }
  } catch (error) {
    console.error(`[priority:create-pr] ${error.message}`);
    process.exitCode = 1;
  }
}
