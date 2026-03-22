#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runMaterializeAgentCostRollup } from './materialize-agent-cost-rollup.mjs';

export const REPORT_SCHEMA = 'priority/pr-spend-projection@v1';
export const COST_ROLLUP_SCHEMA = 'priority/agent-cost-rollup@v1';
export const DEFAULT_COST_ROLLUP_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup.json');
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'pr-spend-projection.json');
export const DEFAULT_MARKDOWN_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'cost', 'pr-spend-projection.md');
export const DEFAULT_MATERIALIZATION_REPORT_PATH = path.join('tests', 'results', '_agent', 'cost', 'agent-cost-rollup-materialization.json');
export const COMMENT_MARKER = '<!-- priority:pr-spend-projection -->';

const HELP = [
  'Usage: node tools/priority/pr-spend-projection.mjs [options]',
  '',
  'Reads an agent cost rollup and projects an intermediate PR spend report plus markdown summary.',
  '',
  'Options:',
  `  --cost-rollup <path>      Cost rollup JSON path (default: ${DEFAULT_COST_ROLLUP_PATH}).`,
  `  --output <path>           JSON report path (default: ${DEFAULT_OUTPUT_PATH}).`,
  `  --markdown-output <path>  Markdown summary path (default: ${DEFAULT_MARKDOWN_OUTPUT_PATH}).`,
  '  --repo <owner/repo>       Repository slug override.',
  '  --pr <number>             Pull request number for stakeholder projection.',
  '  --post-comment            Post or refresh a PR comment using the signed-in gh identity.',
  '  -h, --help                Show this message and exit.'
];

function printUsage() {
  for (const line of HELP) {
    console.log(line);
  }
}

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeOptionalText(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function normalizeInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function normalizeIntegerArray(values) {
  if (!Array.isArray(values)) {
    return [];
  }
  const seen = new Set();
  const normalized = [];
  for (const value of values) {
    const integer = normalizeInteger(value);
    if (!integer || seen.has(integer)) {
      continue;
    }
    seen.add(integer);
    normalized.push(integer);
  }
  return normalized;
}

function roundNumber(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return 0;
  }
  return Number(parsed.toFixed(6));
}

function safeRelative(filePath) {
  return path.relative(process.cwd(), path.resolve(filePath)).replace(/\\/g, '/');
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function extractIssueNumbers(text) {
  const normalized = normalizeText(text);
  if (!normalized) {
    return [];
  }
  const matches = [...normalized.matchAll(/#(?<number>\d+)/g)];
  return normalizeIntegerArray(matches.map((entry) => entry.groups?.number));
}

function parseIssueNumberFromBranch(branch) {
  const normalized = normalizeText(branch);
  if (!normalized.toLowerCase().startsWith('issue/')) {
    return null;
  }
  const suffix = normalized.slice('issue/'.length);
  const tokens = suffix.split('-').map((entry) => entry.trim()).filter(Boolean);
  for (const token of tokens) {
    const parsed = Number(token);
    if (Number.isInteger(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return null;
}

function resolveRepoSlug(explicitRepo) {
  if (normalizeText(explicitRepo).includes('/')) {
    return normalizeText(explicitRepo);
  }
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) {
    return normalizeText(process.env.GITHUB_REPOSITORY);
  }
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = spawnSync('git', ['config', '--get', `remote.${remote}.url`], {
        cwd: process.cwd(),
        encoding: 'utf8'
      });
      if ((raw.status ?? 1) !== 0) {
        continue;
      }
      const slug = parseRemoteUrl(raw.stdout?.trim());
      if (slug) {
        return slug;
      }
    } catch {
      // ignore
    }
  }
  return null;
}

function createBlocker(code, message) {
  return { code, message };
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function writeText(filePath, content) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, content, 'utf8');
  return resolved;
}

function formatUsd(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return '$0.000000';
  }
  return `$${numeric.toFixed(6)}`;
}

function summarizeGroup(turns, keyBuilder, extraBuilder = null) {
  const map = new Map();
  for (const turn of Array.isArray(turns) ? turns : []) {
    const identity = keyBuilder(turn);
    if (!identity?.key) {
      continue;
    }
    const existing = map.get(identity.key) ?? {
      ...identity,
      turnCount: 0,
      amountUsd: 0
    };
    existing.turnCount += 1;
    existing.amountUsd = roundNumber(existing.amountUsd + Number(turn.amountUsd ?? 0));
    if (extraBuilder) {
      extraBuilder(existing, turn);
    }
    map.set(identity.key, existing);
  }
  return Array.from(map.values()).sort((left, right) => right.amountUsd - left.amountUsd || right.turnCount - left.turnCount);
}

function inferBillingTruth(metrics) {
  const exactTurns = Number(metrics?.exactTurnCount ?? 0);
  const estimatedTurns = Number(metrics?.estimatedTurnCount ?? 0);
  if (exactTurns > 0 && estimatedTurns === 0) return 'exact-only';
  if (exactTurns > 0 && estimatedTurns > 0) return 'mixed';
  return 'estimated-only';
}

function buildMarkdown(report) {
  const summary = report.summary;
  const metrics = report.metrics;
  const topModels = report.breakdown.models.slice(0, 3);
  const topProviders = report.breakdown.providers.slice(0, 3);
  const topLanes = report.breakdown.lanes.slice(0, 3);
  const invoiceTurn = report.provenance.invoiceTurn;

  const lines = [
    COMMENT_MARKER,
    '## Intermediate PR Spend',
    '',
    `- Status: \`${summary.status}\``,
    `- Billing truth: \`${summary.billingTruth}\``,
    `- Projected total: \`${formatUsd(summary.totalUsd)}\``,
    `- Estimated portion: \`${formatUsd(summary.estimatedUsd)}\``,
    `- Exact portion: \`${formatUsd(summary.exactUsd)}\``,
    `- Observed turns: \`${metrics.totalTurns}\``,
    `- Live turns: \`${metrics.liveTurnCount}\``,
    `- Background turns: \`${metrics.backgroundTurnCount}\``,
    `- Invoice turn: \`${invoiceTurn?.invoiceTurnId ?? 'none'}\``,
    `- Funding purpose: \`${invoiceTurn?.fundingPurpose ?? 'unknown'}\``,
    `- Activation state: \`${invoiceTurn?.activationState ?? 'unknown'}\``,
  `- Recommendation: \`${summary.recommendation}\``,
  `- Selector source: \`${report.pullRequest.selectorSource ?? 'rollup-all-turns'}\``,
  `- Cost rollup source: \`${report.source.costRollupMaterialized ? 'materialized-current-lane' : 'existing-rollup'}\``,
  '',
  '_This is intermediate PR spend evidence. It is not final billing truth and may remain estimated until reconciliation._',
  ''
  ];

  if (report.pullRequest.linkedIssueNumber) {
    lines.splice(
      11,
      0,
      `- Linked issue fallback: \`#${report.pullRequest.linkedIssueNumber}\``
    );
  }

  if (topProviders.length > 0) {
    lines.push('### Provider Breakdown', '');
    for (const provider of topProviders) {
      lines.push(`- \`${provider.providerId}\`: \`${formatUsd(provider.amountUsd)}\` across \`${provider.turnCount}\` turn(s)`);
    }
    lines.push('');
  }

  if (topModels.length > 0) {
    lines.push('### Model Breakdown', '');
    for (const model of topModels) {
      lines.push(`- \`${model.effectiveModel}\` (${model.effectiveReasoningEffort ?? 'unknown'}): \`${formatUsd(model.amountUsd)}\` across \`${model.turnCount}\` turn(s)`);
    }
    lines.push('');
  }

  if (topLanes.length > 0) {
    lines.push('### Lane Breakdown', '');
    for (const lane of topLanes) {
      lines.push(`- \`${lane.laneId}\`: \`${formatUsd(lane.amountUsd)}\` across \`${lane.turnCount}\` turn(s)`);
    }
    lines.push('');
  }

  if (report.blockers.length > 0) {
    lines.push('### Blockers', '');
    for (const blocker of report.blockers) {
      lines.push(`- \`${blocker.code}\`: ${blocker.message}`);
    }
    lines.push('');
  }

  return `${lines.join('\n').trimEnd()}\n`;
}

function findExistingSpendComment(repo, prNumber, marker = COMMENT_MARKER) {
  const result = spawnSync(
    'gh',
    ['api', `repos/${repo}/issues/${prNumber}/comments`, '--paginate'],
    {
      cwd: process.cwd(),
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024
    }
  );

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh api for pull request comments: ${message}`);
  }
  if ((result.status ?? 0) !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    throw new Error(`gh api repos/${repo}/issues/${prNumber}/comments failed with exit code ${result.status}. ${stderr || stdout}`.trim());
  }

  const payload = JSON.parse(result.stdout ?? '[]');
  if (!Array.isArray(payload)) {
    return null;
  }
  const match = [...payload]
    .reverse()
    .find((entry) => normalizeText(entry?.body).includes(marker));
  return match
    ? {
        id: normalizeInteger(match.id),
        url: normalizeOptionalText(match.html_url),
        author: normalizeOptionalText(match?.user?.login)
      }
    : null;
}

function lookupCurrentLogin() {
  const result = spawnSync('gh', ['api', 'user'], {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024
  });
  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh api user: ${message}`);
  }
  if ((result.status ?? 0) !== 0) {
    throw new Error(`gh api user failed with exit code ${result.status}.`);
  }
  const payload = JSON.parse(result.stdout ?? '{}');
  const login = normalizeOptionalText(payload?.login);
  if (!login) {
    throw new Error('Unable to resolve the signed-in gh login.');
  }
  return login;
}

function resolvePullRequestContext(repo, prNumber) {
  if (!repo || !prNumber) {
    return null;
  }
  const result = spawnSync(
    'gh',
    ['pr', 'view', String(prNumber), '--repo', repo, '--json', 'number,url,headRefName,headRefOid,title,body'],
    {
      cwd: process.cwd(),
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024
    }
  );

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to resolve pull request context: ${message}`);
  }
  if ((result.status ?? 0) !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    throw new Error(`gh pr view failed for #${prNumber}. ${stderr || stdout}`.trim());
  }

  const payload = JSON.parse(result.stdout ?? '{}');
  const linkedIssueNumbers = normalizeIntegerArray([
    ...extractIssueNumbers(payload?.title),
    ...extractIssueNumbers(payload?.body)
  ]);
  return {
    number: normalizeInteger(payload?.number) ?? prNumber,
    url: normalizeOptionalText(payload?.url),
    headRefName: normalizeOptionalText(payload?.headRefName),
    headSha: normalizeOptionalText(payload?.headRefOid),
    linkedIssueNumber: linkedIssueNumbers[0] ?? null,
    headRefIssueNumber: parseIssueNumberFromBranch(payload?.headRefName),
    selectorSource: 'github-pr-head-ref'
  };
}

function buildMetricsFromTurns(turns, unitPriceUsd) {
  const selectedTurns = Array.isArray(turns) ? turns : [];
  const exactTurns = selectedTurns.filter((turn) => normalizeText(turn?.exactness) === 'exact');
  const estimatedTurns = selectedTurns.filter((turn) => normalizeText(turn?.exactness) !== 'exact');
  const exactUsd = roundNumber(exactTurns.reduce((sum, turn) => sum + Number(turn.amountUsd ?? 0), 0));
  const estimatedUsd = roundNumber(estimatedTurns.reduce((sum, turn) => sum + Number(turn.amountUsd ?? 0), 0));
  const totalUsd = roundNumber(exactUsd + estimatedUsd);
  const totalTokens = selectedTurns.reduce((sum, turn) => sum + Number(turn.totalTokens ?? 0), 0);
  const liveTurnCount = selectedTurns.filter((turn) => normalizeText(turn?.agentRole) === 'live').length;
  const backgroundTurnCount = selectedTurns.length - liveTurnCount;
  const creditsFromUsd =
    Number.isFinite(Number(unitPriceUsd)) && Number(unitPriceUsd) > 0
      ? roundNumber(totalUsd / Number(unitPriceUsd))
      : null;
  const exactCredits =
    Number.isFinite(Number(unitPriceUsd)) && Number(unitPriceUsd) > 0
      ? roundNumber(exactUsd / Number(unitPriceUsd))
      : null;

  return {
    totalTurns: selectedTurns.length,
    liveTurnCount,
    backgroundTurnCount,
    exactTurnCount: exactTurns.length,
    estimatedTurnCount: estimatedTurns.length,
    totalUsd,
    exactUsd,
    estimatedUsd,
    totalTokens,
    estimatedCreditsConsumed: creditsFromUsd,
    actualCreditsConsumed: exactCredits,
    actualUsdConsumed: exactTurns.length > 0 ? exactUsd : null
  };
}

function upsertPullRequestComment(repo, prNumber, body) {
  const existing = findExistingSpendComment(repo, prNumber, COMMENT_MARKER);
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pr-spend-projection-'));
  const markdownPath = path.join(tempDir, 'comment.md');
  fs.writeFileSync(markdownPath, `${body}\n`, 'utf8');

  try {
    let result;
    if (existing?.id) {
      const requestPath = path.join(tempDir, 'patch.json');
      fs.writeFileSync(requestPath, `${JSON.stringify({ body })}\n`, 'utf8');
      result = spawnSync(
        'gh',
        ['api', `repos/${repo}/issues/comments/${existing.id}`, '--method', 'PATCH', '--input', requestPath],
        {
          cwd: process.cwd(),
          encoding: 'utf8',
          maxBuffer: 16 * 1024 * 1024
        }
      );
    } else {
      result = spawnSync(
        'gh',
        ['pr', 'comment', String(prNumber), '--repo', repo, '--body-file', markdownPath],
        {
          cwd: process.cwd(),
          encoding: 'utf8',
          maxBuffer: 16 * 1024 * 1024
        }
      );
    }

    if (result.error) {
      const message = result.error instanceof Error ? result.error.message : String(result.error);
      throw new Error(`Failed to post PR spend comment: ${message}`);
    }
    if ((result.status ?? 0) !== 0) {
      const stderr = normalizeText(result.stderr);
      const stdout = normalizeText(result.stdout);
      throw new Error(`Failed to post PR spend comment. ${stderr || stdout}`.trim());
    }

    return {
      posted: true,
      mode: existing?.id ? 'update-existing-marker-comment' : 'create-new-comment'
    };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    costRollupPath: DEFAULT_COST_ROLLUP_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    markdownOutputPath: DEFAULT_MARKDOWN_OUTPUT_PATH,
    repo: null,
    prNumber: null,
    postComment: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--post-comment') {
      options.postComment = true;
      continue;
    }
    if (['--cost-rollup', '--output', '--markdown-output', '--repo', '--pr'].includes(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--cost-rollup') options.costRollupPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--markdown-output') options.markdownOutputPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && options.postComment && !options.prNumber) {
    throw new Error('Missing required option: --pr <number> when --post-comment is used.');
  }

  return options;
}

export function evaluatePrSpendProjection({ costRollup, repo, prContext = null }) {
  const blockers = [];
  if (!costRollup || typeof costRollup !== 'object') {
    blockers.push(createBlocker('cost-rollup-missing', 'Cost rollup report is required.'));
  } else if (normalizeText(costRollup.schema) !== COST_ROLLUP_SCHEMA) {
    blockers.push(
      createBlocker(
        'cost-rollup-schema-mismatch',
        `Cost rollup schema must remain ${COST_ROLLUP_SCHEMA}.`
      )
    );
  }

  const rollupTurns = Array.isArray(costRollup?.turns) ? costRollup.turns : [];
  const rollupBlockers = Array.isArray(costRollup?.summary?.blockers) ? costRollup.summary.blockers : [];
  for (const blocker of rollupBlockers) {
    blockers.push(
      createBlocker(
        `rollup-${normalizeText(blocker?.code) || 'blocker'}`,
        normalizeText(blocker?.message) || 'Cost rollup reported a blocker.'
      )
    );
  }

  let selectedTurns =
    prContext?.headRefName
      ? rollupTurns.filter(
          (turn) =>
            normalizeText(turn?.laneId) === prContext.headRefName ||
            normalizeText(turn?.laneBranch) === prContext.headRefName
        )
      : rollupTurns;
  let selectorSource = prContext?.selectorSource ?? (prContext ? 'manual' : 'rollup-all-turns');

  if (
    prContext?.headRefName &&
    selectedTurns.length === 0 &&
    normalizeInteger(prContext?.headRefIssueNumber)
  ) {
    selectedTurns = rollupTurns.filter(
      (turn) => normalizeInteger(turn?.issueNumber) === normalizeInteger(prContext.headRefIssueNumber)
    );
    if (selectedTurns.length > 0) {
      selectorSource = 'github-pr-head-ref-issue-fallback';
    }
  }

  if (
    prContext?.headRefName &&
    selectedTurns.length === 0 &&
    normalizeInteger(prContext?.linkedIssueNumber)
  ) {
    selectedTurns = rollupTurns.filter(
      (turn) => normalizeInteger(turn?.issueNumber) === normalizeInteger(prContext.linkedIssueNumber)
    );
    if (selectedTurns.length > 0) {
      selectorSource = 'github-pr-linked-issue-fallback';
    }
  }

  if (prContext?.headRefName && selectedTurns.length === 0) {
    blockers.push(
      createBlocker(
        'pr-head-ref-no-matching-turns',
        `No cost turns matched PR head ref '${prContext.headRefName}' or linked issue fallback.`
      )
    );
  }

  const invoiceTurn = costRollup?.summary?.provenance?.invoiceTurn ?? null;
  const metrics = buildMetricsFromTurns(selectedTurns, invoiceTurn?.unitPriceUsd);

  const agentRoles = summarizeGroup(selectedTurns, (turn) => ({
    key: normalizeText(turn?.agentRole) || 'unknown',
    agentRole: normalizeText(turn?.agentRole) || 'unknown'
  }));

  const providers = summarizeGroup(selectedTurns, (turn) => ({
    key: `${normalizeText(turn?.providerId) || 'unknown'}::${normalizeText(turn?.providerKind) || 'unknown'}`,
    providerId: normalizeText(turn?.providerId) || 'unknown',
    providerKind: normalizeText(turn?.providerKind) || 'unknown'
  }));

  const models = summarizeGroup(selectedTurns, (turn) => ({
    key: `${normalizeText(turn?.effectiveModel) || 'unknown'}::${normalizeText(turn?.effectiveReasoningEffort) || 'unknown'}`,
    effectiveModel: normalizeText(turn?.effectiveModel) || 'unknown',
    effectiveReasoningEffort: normalizeOptionalText(turn?.effectiveReasoningEffort)
  }));

  const issues = summarizeGroup(selectedTurns, (turn) => ({
    key: String(turn?.issueNumber ?? 'unknown'),
    issueNumber: Number.isInteger(Number(turn?.issueNumber)) ? Number(turn.issueNumber) : null
  }));

  const lanes = summarizeGroup(selectedTurns, (turn) => ({
    key: normalizeText(turn?.laneId) || 'unknown',
    laneId: normalizeText(turn?.laneId) || 'unknown'
  }));

  const billingTruth = inferBillingTruth(metrics);

  const recommendation =
    blockers.length > 0
      ? 'repair-cost-rollup-before-stamping'
      : billingTruth === 'exact-only'
        ? 'publish-intermediate-pr-spend'
        : 'publish-estimated-intermediate-pr-spend';

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repository: repo,
    pullRequest: {
      number: prContext?.number ?? null,
      url: prContext?.url ?? null,
      headRefName: prContext?.headRefName ?? null,
      headSha: prContext?.headSha ?? null,
      linkedIssueNumber: normalizeInteger(prContext?.linkedIssueNumber),
      selectorSource
    },
    summary: {
      status: blockers.length > 0 ? 'blocked' : 'pass',
      blockerCount: blockers.length,
      recommendation,
      billingTruth,
      totalUsd: roundNumber(metrics.totalUsd),
      exactUsd: roundNumber(metrics.exactUsd),
      estimatedUsd: roundNumber(metrics.estimatedUsd)
    },
    metrics: {
      totalTurns: Number(metrics.totalTurns ?? 0),
      liveTurnCount: Number(metrics.liveTurnCount ?? 0),
      backgroundTurnCount: Number(metrics.backgroundTurnCount ?? 0),
      exactTurnCount: Number(metrics.exactTurnCount ?? 0),
      estimatedTurnCount: Number(metrics.estimatedTurnCount ?? 0),
      totalTokens: Number(metrics.totalTokens ?? 0),
      estimatedCreditsConsumed: metrics.estimatedCreditsConsumed ?? null,
      actualCreditsConsumed: metrics.actualCreditsConsumed ?? null,
      actualUsdConsumed: metrics.actualUsdConsumed ?? null
    },
    provenance: {
      costRollupGeneratedAt: normalizeOptionalText(costRollup?.generatedAt),
      costRollupStatus: normalizeOptionalText(costRollup?.summary?.status),
      costRollupRecommendation: normalizeOptionalText(costRollup?.summary?.recommendation),
      invoiceTurn: costRollup?.summary?.provenance?.invoiceTurn ?? null,
      invoiceTurnSelection: costRollup?.summary?.provenance?.invoiceTurnSelection ?? null,
      rateCards: Array.isArray(costRollup?.summary?.provenance?.rateCards)
        ? costRollup.summary.provenance.rateCards
        : []
    },
    breakdown: {
      agentRoles,
      providers,
      models,
      issues,
      lanes
    },
    commentPost: {
      requested: false,
      posted: false,
      mode: null,
      actorLogin: null,
      postedAt: null
    },
    source: {
      costRollupPath: null,
      markdownPath: null,
      costRollupMaterialized: false,
      costRollupMaterializationReportPath: null
    },
    blockers
  };

  return report;
}

export function runPrSpendProjection(
  options,
  {
    resolveRepoSlugFn = resolveRepoSlug,
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    writeTextFn = writeText,
    upsertCommentFn = upsertPullRequestComment,
    lookupCurrentLoginFn = lookupCurrentLogin,
    resolvePullRequestContextFn = resolvePullRequestContext,
    materializeAgentCostRollupFn = runMaterializeAgentCostRollup
  } = {}
) {
  const repo = resolveRepoSlugFn(options.repo);
  if (!repo) {
    throw new Error('Unable to determine repository slug.');
  }

  const prContext = options.prNumber ? resolvePullRequestContextFn(repo, options.prNumber) : null;
  const requestedCostRollupPath = options.costRollupPath || DEFAULT_COST_ROLLUP_PATH;
  let resolvedCostRollupPath = path.resolve(requestedCostRollupPath);
  let materializationReportPath = null;
  let costRollupMaterialized = false;
  const materializeCostRollup = () => {
    const materializationResult = materializeAgentCostRollupFn({
      repoRoot: process.cwd(),
      repo,
      issueNumber: prContext?.headRefIssueNumber ?? prContext?.linkedIssueNumber ?? null,
      laneId: prContext?.headRefName ?? null,
      laneBranch: prContext?.headRefName ?? null,
      costRollupPath: requestedCostRollupPath,
      outputPath: DEFAULT_MATERIALIZATION_REPORT_PATH
    });
    materializationReportPath = materializationResult?.outputPath ?? null;
    resolvedCostRollupPath = path.resolve(materializationResult?.costRollupPath ?? requestedCostRollupPath);
    costRollupMaterialized = true;
  };

  if (!fs.existsSync(resolvedCostRollupPath)) {
    materializeCostRollup();
  }

  let costRollup = readJsonFn(resolvedCostRollupPath);
  let report = evaluatePrSpendProjection({
    costRollup,
    repo,
    prContext
  });

  if (
    !costRollupMaterialized &&
    report.blockers.some((entry) => normalizeText(entry?.code) === 'pr-head-ref-no-matching-turns') &&
    prContext?.headRefName
  ) {
    materializeCostRollup();
    costRollup = readJsonFn(resolvedCostRollupPath);
    report = evaluatePrSpendProjection({
      costRollup,
      repo,
      prContext
    });
  }

  report.source.costRollupPath = safeRelative(resolvedCostRollupPath);
  report.source.costRollupMaterialized = costRollupMaterialized;
  report.source.costRollupMaterializationReportPath = materializationReportPath ? safeRelative(materializationReportPath) : null;
  const markdown = buildMarkdown(report);
  const markdownPath = writeTextFn(options.markdownOutputPath || DEFAULT_MARKDOWN_OUTPUT_PATH, markdown);
  report.source.markdownPath = safeRelative(markdownPath);

  if (options.postComment) {
    if (!options.prNumber) {
      throw new Error('Pull request number is required to post a comment.');
    }
    const result = upsertCommentFn(repo, options.prNumber, markdown);
    report.commentPost = {
      requested: true,
      posted: result?.posted === true,
      mode: normalizeOptionalText(result?.mode),
      actorLogin: lookupCurrentLoginFn(),
      postedAt: new Date().toISOString()
    };
  }

  const outputPath = writeJsonFn(options.outputPath || DEFAULT_OUTPUT_PATH, report);
  return { report, outputPath, markdownPath };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printUsage();
      process.exit(0);
    }
    const result = runPrSpendProjection(options);
    console.log(`[pr-spend-projection] wrote ${result.outputPath}`);
    console.log(`[pr-spend-projection] markdown ${result.markdownPath}`);
    if (result.report.summary.status !== 'pass') {
      process.exit(1);
    }
  } catch (error) {
    console.error(`[pr-spend-projection] ${error.message}`);
    process.exit(1);
  }
}
