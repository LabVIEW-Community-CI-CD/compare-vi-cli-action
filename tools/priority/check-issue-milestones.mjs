#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'issue-milestone-hygiene.json');
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'issue', 'milestone-hygiene-report.json');
export const DEFAULT_REQUIRED_LABELS = ['standing-priority', 'program'];
export const DEFAULT_TITLE_PRIORITY_PATTERN = String.raw`\[(P0|P1)\]`;
export const DEFAULT_REQUIRE_OPEN_MILESTONE = true;
export const REPORT_SCHEMA = 'priority/issue-milestone-hygiene-report@v1';
const DEFAULT_TITLE_PRIORITY_TOKENS = ['P0', 'P1'];
const TITLE_PRIORITY_TOKENS_ESCAPED = /^\\\[\((P\d+(?:\|P\d+)*)\)\\\]$/i;
const TITLE_PRIORITY_TOKENS_LITERAL = /^\[\((P\d+(?:\|P\d+)*)\)\]$/i;

function normalizeText(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeLabel(name) {
  const normalized = normalizeText(name);
  return normalized ? normalized.toLowerCase() : null;
}

function parseList(value) {
  return String(value ?? '')
    .split(',')
    .map((entry) => normalizeLabel(entry))
    .filter(Boolean);
}

function resolveRepository(argvRepo, env = process.env) {
  const fromCli = normalizeText(argvRepo);
  if (fromCli) return fromCli;
  const fromEnv = normalizeText(env.GITHUB_REPOSITORY);
  if (fromEnv) return fromEnv;
  throw new Error('Repository slug is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
}

function parseBooleanLike(value) {
  if (typeof value === 'boolean') return value;
  const normalized = normalizeText(value);
  if (!normalized) return false;
  const lowered = normalized.toLowerCase();
  return lowered === '1' || lowered === 'true' || lowered === 'yes' || lowered === 'on';
}

function normalizeMilestoneState(value) {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  const lowered = normalized.toLowerCase();
  if (lowered === 'open' || lowered === 'closed') return lowered;
  return lowered;
}

function parsePriorityTokens(patternText) {
  const normalized = normalizeText(patternText);
  if (!normalized) {
    throw new Error('Priority pattern is required.');
  }
  if (normalized === DEFAULT_TITLE_PRIORITY_PATTERN) {
    return [...DEFAULT_TITLE_PRIORITY_TOKENS];
  }
  const escaped = normalized.match(TITLE_PRIORITY_TOKENS_ESCAPED);
  const literal = normalized.match(TITLE_PRIORITY_TOKENS_LITERAL);
  const tokenGroup = escaped?.[1] ?? literal?.[1] ?? null;
  if (!tokenGroup) {
    throw new Error(
      `Unsupported title priority pattern '${normalized}'. Expected escaped form '\\[(P0|P1)\\]' or literal form '[(P0|P1)]'.`
    );
  }
  return tokenGroup
    .split('|')
    .map((token) => token.toUpperCase())
    .filter(Boolean);
}

function titleHasPriorityMarker(title, priorityTokens) {
  const normalizedTitle = normalizeText(title)?.toUpperCase() ?? '';
  for (const token of priorityTokens) {
    if (normalizedTitle.includes(`[${token}]`)) {
      return true;
    }
  }
  return false;
}

function isValidDateTime(value) {
  const normalized = normalizeText(value);
  if (!normalized) return true;
  return !Number.isNaN(Date.parse(normalized));
}

export function parseArgs(argv = process.argv.slice(2), env = process.env) {
  const args = Array.from(argv ?? []);
  const options = {
    repo: null,
    state: 'open',
    limit: 200,
    policyPath: DEFAULT_POLICY_PATH,
    requiredLabels: null,
    titlePriorityPattern: null,
    requireOpenMilestone: null,
    reportPath: DEFAULT_REPORT_PATH,
    defaultMilestone: null,
    defaultMilestoneDueOn: null,
    applyDefaultMilestone: false,
    createDefaultMilestone: false,
    warnOnly: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--apply-default-milestone') {
      options.applyDefaultMilestone = true;
      continue;
    }
    if (token === '--create-default-milestone') {
      options.createDefaultMilestone = true;
      continue;
    }
    if (token === '--allow-closed-milestone') {
      options.requireOpenMilestone = false;
      continue;
    }
    if (token === '--warn-only') {
      options.warnOnly = true;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--state' ||
      token === '--limit' ||
      token === '--policy' ||
      token === '--required-labels' ||
      token === '--title-priority-pattern' ||
      token === '--default-milestone' ||
      token === '--default-milestone-due-on' ||
      token === '--report'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--state') options.state = String(next).trim().toLowerCase();
      if (token === '--limit') {
        const parsed = Number(next);
        if (!Number.isInteger(parsed) || parsed <= 0) {
          throw new Error(`Invalid --limit value: ${next}`);
        }
        options.limit = parsed;
      }
      if (token === '--policy') options.policyPath = next;
      if (token === '--required-labels') options.requiredLabels = parseList(next);
      if (token === '--title-priority-pattern') options.titlePriorityPattern = String(next);
      if (token === '--default-milestone') options.defaultMilestone = normalizeText(next);
      if (token === '--default-milestone-due-on') options.defaultMilestoneDueOn = normalizeText(next);
      if (token === '--report') options.reportPath = next;
      continue;
    }

    throw new Error(`Unknown argument: ${token}`);
  }

  if (options.help) {
    return options;
  }

  options.repo = resolveRepository(options.repo, env);
  if (options.state !== 'open' && options.state !== 'all') {
    throw new Error(`Invalid --state '${options.state}'. Supported values: open|all`);
  }
  if (!isValidDateTime(options.defaultMilestoneDueOn)) {
    throw new Error(`Invalid --default-milestone-due-on value '${options.defaultMilestoneDueOn}'. Use ISO-8601 date/time.`);
  }
  return options;
}

export function normalizePolicy(rawPolicy) {
  const raw = rawPolicy && typeof rawPolicy === 'object' ? rawPolicy : {};
  const required = raw.required && typeof raw.required === 'object' ? raw.required : {};

  const labels = Array.isArray(required.labels)
    ? required.labels.map((entry) => normalizeLabel(entry)).filter(Boolean)
    : [...DEFAULT_REQUIRED_LABELS];
  const requiredLabels = labels.length > 0 ? [...new Set(labels)] : [...DEFAULT_REQUIRED_LABELS];

  const titlePriorityPattern = normalizeText(required.titlePriorityPattern) ?? DEFAULT_TITLE_PRIORITY_PATTERN;
  try {
    parsePriorityTokens(titlePriorityPattern);
  } catch (error) {
    throw new Error(`Invalid policy required.titlePriorityPattern: ${error.message}`);
  }

  const requireOpenMilestone = required.requireOpenMilestone == null
    ? DEFAULT_REQUIRE_OPEN_MILESTONE
    : parseBooleanLike(required.requireOpenMilestone);

  const defaultMilestoneDueOn = normalizeText(raw.defaultMilestoneDueOn);
  if (!isValidDateTime(defaultMilestoneDueOn)) {
    throw new Error(`Invalid policy defaultMilestoneDueOn '${defaultMilestoneDueOn}'. Use ISO-8601 date/time.`);
  }

  return {
    schema: normalizeText(raw.schema) ?? 'issue-milestone-hygiene-policy@v1',
    required: {
      labels: requiredLabels,
      titlePriorityPattern,
      requireOpenMilestone
    },
    defaultMilestone: normalizeText(raw.defaultMilestone),
    defaultMilestoneDueOn,
    warnOnly: parseBooleanLike(raw.warnOnly),
    createDefaultMilestone: parseBooleanLike(raw.createDefaultMilestone)
  };
}

export async function loadPolicy(policyPath, { readFileFn = readFile } = {}) {
  const resolved = path.resolve(policyPath);
  const raw = await readFileFn(resolved, 'utf8');
  return {
    path: resolved,
    ...normalizePolicy(JSON.parse(raw))
  };
}

function runGh(args, { cwd = process.cwd(), spawnSyncFn = spawnSync } = {}) {
  const result = spawnSyncFn('gh', args, { cwd, encoding: 'utf8', shell: false });
  if (result?.error?.code === 'ENOENT') {
    throw new Error('GitHub CLI (gh) is required but was not found in PATH.');
  }
  return result;
}

function runGhJson(args, context = {}) {
  const result = runGh(args, context);
  if (result.status !== 0) {
    const details = normalizeText(result.stderr) ?? normalizeText(result.stdout) ?? 'unknown error';
    throw new Error(`gh ${args.join(' ')} failed: ${details}`);
  }
  const raw = normalizeText(result.stdout);
  if (!raw) return [];
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function issueLabelNames(issue) {
  if (!Array.isArray(issue?.labels)) return [];
  return issue.labels
    .map((entry) => (typeof entry === 'string' ? entry : entry?.name))
    .map((entry) => normalizeLabel(entry))
    .filter(Boolean);
}

function milestoneCatalogFromApi(items = []) {
  return items
    .map((milestone) => ({
      number: Number.isInteger(milestone?.number) ? milestone.number : null,
      title: normalizeText(milestone?.title),
      state: normalizeMilestoneState(milestone?.state),
      dueOn: normalizeText(milestone?.due_on ?? milestone?.dueOn)
    }))
    .filter((milestone) => milestone.number != null && milestone.title);
}

function buildMilestoneMaps(milestones = []) {
  const byNumber = new Map();
  const byTitle = new Map();
  for (const milestone of milestones) {
    byNumber.set(milestone.number, milestone);
    byTitle.set(milestone.title.toLowerCase(), milestone);
  }
  return { byNumber, byTitle };
}

function listMilestonesForState(repo, state, runGhJsonFn) {
  return runGhJsonFn(
    ['api', `repos/${repo}/milestones`, '--method', 'GET', '-f', `state=${state}`, '-f', 'per_page=100'],
    { cwd: process.cwd() }
  );
}

function listMilestones(repo, runGhJsonFn) {
  const openRows = listMilestonesForState(repo, 'open', runGhJsonFn);
  const closedRows = listMilestonesForState(repo, 'closed', runGhJsonFn);
  const combined = [...openRows, ...closedRows];
  const seen = new Set();
  const unique = [];
  for (const row of combined) {
    const number = Number.isInteger(row?.number) ? row.number : null;
    if (number == null || seen.has(number)) continue;
    seen.add(number);
    unique.push(row);
  }
  return unique;
}

function summarizeMilestones(milestones = []) {
  let openCount = 0;
  let closedCount = 0;
  for (const milestone of milestones) {
    if (milestone.state === 'open') openCount += 1;
    if (milestone.state === 'closed') closedCount += 1;
  }
  return {
    totalCount: milestones.length,
    openCount,
    closedCount
  };
}

function buildTriggerCounts(entries) {
  const counts = {};
  for (const entry of entries) {
    for (const trigger of entry.triggers) {
      counts[trigger] = (counts[trigger] ?? 0) + 1;
    }
  }
  return counts;
}

async function writeJsonReport(reportPath, payload) {
  const resolved = path.resolve(reportPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function findOptionValue(argv, optionName) {
  const args = Array.isArray(argv) ? argv : [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] !== optionName) {
      continue;
    }
    const next = args[index + 1];
    if (!next || String(next).startsWith('-')) {
      return null;
    }
    return String(next);
  }
  return null;
}

function buildExecutionState(status, errors = []) {
  return {
    status,
    errors: Array.isArray(errors) ? errors.filter(Boolean).map((entry) => String(entry)) : []
  };
}

function buildFallbackFailureReport({
  now = new Date(),
  options = {},
  policy = null,
  error
} = {}) {
  const normalizedError = normalizeText(error?.message ?? error) ?? 'unknown error';
  const requiredLabels = options.requiredLabels ?? policy?.required?.labels ?? [...DEFAULT_REQUIRED_LABELS];
  const titlePriorityPattern =
    options.titlePriorityPattern ?? policy?.required?.titlePriorityPattern ?? DEFAULT_TITLE_PRIORITY_PATTERN;
  const requireOpenMilestone =
    options.requireOpenMilestone == null
      ? (policy?.required?.requireOpenMilestone ?? DEFAULT_REQUIRE_OPEN_MILESTONE)
      : Boolean(options.requireOpenMilestone);
  const warnOnly = options.warnOnly == null ? Boolean(policy?.warnOnly) : Boolean(options.warnOnly);
  const defaultMilestoneTitle = options.defaultMilestone ?? policy?.defaultMilestone ?? null;
  const defaultMilestoneDueOn = options.defaultMilestoneDueOn ?? policy?.defaultMilestoneDueOn ?? null;
  const createDefaultMilestone = Boolean(options.createDefaultMilestone || policy?.createDefaultMilestone);

  return {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    repository: options.repo,
    state: options.state ?? 'open',
    execution: buildExecutionState('error', [normalizedError]),
    flags: {
      applyDefaultMilestone: Boolean(options.applyDefaultMilestone),
      warnOnly,
      requireOpenMilestone,
      createDefaultMilestone
    },
    policy: {
      path: policy?.path ?? path.resolve(options.policyPath ?? DEFAULT_POLICY_PATH),
      requiredLabels,
      titlePriorityPattern,
      defaultMilestone: defaultMilestoneTitle,
      defaultMilestoneDueOn
    },
    milestones: {
      totalCount: 0,
      openCount: 0,
      closedCount: 0,
      defaultMilestone: null,
      createdDefaultMilestone: false
    },
    summary: {
      issueCount: 0,
      requiredIssueCount: 0,
      triggerCounts: {},
      initialViolationCount: 0,
      remainingViolationCount: 0,
      remainingReasonCounts: {},
      assignedDefaultMilestoneCount: 0,
      failedAssignmentsCount: 0
    },
    violations: [],
    reconciliations: []
  };
}

export function evaluateIssue(issue, {
  requiredLabels,
  titlePriorityTokens,
  requireOpenMilestone,
  milestonesByNumber = new Map()
}) {
  const labels = issueLabelNames(issue);
  const title = normalizeText(issue?.title) ?? '';
  const milestoneTitle = normalizeText(issue?.milestone?.title);
  const milestoneNumber = Number.isInteger(issue?.milestone?.number) ? issue.milestone.number : null;
  const mappedMilestone = milestoneNumber != null ? milestonesByNumber.get(milestoneNumber) : null;
  const milestoneState = normalizeMilestoneState(mappedMilestone?.state ?? issue?.milestone?.state);
  const triggers = [];

  for (const label of requiredLabels) {
    if (labels.includes(label)) {
      triggers.push(`label:${label}`);
    }
  }

  if (titleHasPriorityMarker(title, titlePriorityTokens)) {
    triggers.push('title-priority');
  }

  const requiresMilestone = triggers.length > 0;
  const hasMilestone = Boolean(milestoneTitle);
  let reason = null;
  if (requiresMilestone && !hasMilestone) {
    reason = 'missing-milestone';
  } else if (requiresMilestone && requireOpenMilestone && milestoneState === 'closed') {
    reason = 'closed-milestone';
  }
  const isViolation = reason !== null;

  return {
    number: Number(issue?.number),
    title,
    url: normalizeText(issue?.url),
    labels,
    milestone: milestoneTitle,
    milestoneNumber,
    milestoneState,
    triggers,
    requiresMilestone,
    isViolation,
    reason
  };
}

async function resolveDefaultMilestone({
  repo,
  defaultMilestoneTitle,
  defaultMilestoneDueOn,
  requireOpenMilestone,
  createDefaultMilestone,
  milestones,
  runGhJsonFn
}) {
  const wanted = normalizeText(defaultMilestoneTitle);
  if (!wanted) {
    throw new Error('Default milestone is required when --apply-default-milestone is set.');
  }

  const { byTitle } = buildMilestoneMaps(milestones);
  const existing = byTitle.get(wanted.toLowerCase()) ?? null;
  if (existing) {
    if (requireOpenMilestone && existing.state === 'closed') {
      throw new Error(`Default milestone '${wanted}' is closed; reopen it or use --allow-closed-milestone.`);
    }
    return { milestone: existing, created: false };
  }

  if (!createDefaultMilestone) {
    throw new Error(`Default milestone '${wanted}' was not found. Set --create-default-milestone to create it.`);
  }

  const createArgs = ['api', `repos/${repo}/milestones`, '--method', 'POST', '-f', `title=${wanted}`];
  if (defaultMilestoneDueOn) {
    createArgs.push('-f', `due_on=${defaultMilestoneDueOn}`);
  }

  const createdRows = runGhJsonFn(createArgs, { cwd: process.cwd() });
  const created = milestoneCatalogFromApi(createdRows)[0] ?? null;
  if (!created) {
    throw new Error(`Failed to create default milestone '${wanted}'.`);
  }
  if (requireOpenMilestone && created.state === 'closed') {
    throw new Error(`Created default milestone '${wanted}' is closed; cannot use for reconciliation.`);
  }

  return { milestone: created, created: true };
}

export async function runMilestoneHygiene({
  argv = process.argv.slice(2),
  env = process.env,
  now = new Date(),
  runGhJsonFn = runGhJson,
  runGhFn = runGh,
  loadPolicyFn = loadPolicy,
  writeJsonReportFn = writeJsonReport
} = {}) {
  const options = parseArgs(argv, env);
  if (options.help) {
    return { exitCode: 0, report: null, reportPath: null, help: true };
  }

  const policy = await loadPolicyFn(options.policyPath);
  const requiredLabels = options.requiredLabels ?? policy.required.labels;
  const titlePriorityPattern = options.titlePriorityPattern ?? policy.required.titlePriorityPattern;
  const titlePriorityTokens = parsePriorityTokens(titlePriorityPattern);
  const requireOpenMilestone = options.requireOpenMilestone == null
    ? policy.required.requireOpenMilestone
    : Boolean(options.requireOpenMilestone);
  const warnOnly = options.warnOnly === null ? policy.warnOnly : Boolean(options.warnOnly);
  const defaultMilestoneTitle = options.defaultMilestone ?? policy.defaultMilestone;
  const defaultMilestoneDueOn = options.defaultMilestoneDueOn ?? policy.defaultMilestoneDueOn;
  const createDefaultMilestone = options.createDefaultMilestone || policy.createDefaultMilestone;

  if (!isValidDateTime(defaultMilestoneDueOn)) {
    throw new Error(`Invalid default milestone due date '${defaultMilestoneDueOn}'. Use ISO-8601 date/time.`);
  }
  if (options.applyDefaultMilestone && !defaultMilestoneTitle) {
    throw new Error('Default milestone is required when --apply-default-milestone is set.');
  }

  const issues = runGhJsonFn(
    [
      'issue',
      'list',
      '--repo',
      options.repo,
      '--state',
      options.state,
      '--limit',
      String(options.limit),
      '--json',
      'number,title,milestone,labels,url'
    ],
    { cwd: process.cwd() }
  );

  const milestoneRows = listMilestones(options.repo, runGhJsonFn);
  const milestones = milestoneCatalogFromApi(milestoneRows);
  const milestoneMaps = buildMilestoneMaps(milestones);

  let defaultMilestone = null;
  let createdDefaultMilestone = null;
  if (options.applyDefaultMilestone) {
    const resolved = await resolveDefaultMilestone({
      repo: options.repo,
      defaultMilestoneTitle,
      defaultMilestoneDueOn,
      requireOpenMilestone,
      createDefaultMilestone,
      milestones,
      runGhJsonFn
    });
    defaultMilestone = resolved.milestone;
    if (resolved.created) {
      createdDefaultMilestone = resolved.milestone;
      milestones.push(resolved.milestone);
      milestoneMaps.byNumber.set(resolved.milestone.number, resolved.milestone);
      milestoneMaps.byTitle.set(resolved.milestone.title.toLowerCase(), resolved.milestone);
    }
  }

  const evaluations = issues.map((issue) => evaluateIssue(issue, {
    requiredLabels,
    titlePriorityTokens,
    requireOpenMilestone,
    milestonesByNumber: milestoneMaps.byNumber
  }));
  const requiredIssues = evaluations.filter((entry) => entry.requiresMilestone);
  const violations = evaluations.filter((entry) => entry.isViolation);
  const triggerCounts = buildTriggerCounts(requiredIssues);

  const reconciliations = [];
  const remainingViolations = [];
  for (const violation of violations) {
    if (!options.applyDefaultMilestone) {
      remainingViolations.push(violation);
      continue;
    }

    const editResult = runGhFn(
      [
        'issue',
        'edit',
        String(violation.number),
        '--repo',
        options.repo,
        '--milestone',
        defaultMilestone.title
      ],
      { cwd: process.cwd() }
    );

    if (editResult.status === 0) {
      reconciliations.push({
        number: violation.number,
        status: 'assigned',
        reason: violation.reason,
        previousMilestone: violation.milestone,
        milestone: defaultMilestone.title,
        milestoneNumber: defaultMilestone.number,
        triggers: violation.triggers
      });
      continue;
    }

    const errorMessage = normalizeText(editResult.stderr) ?? normalizeText(editResult.stdout) ?? 'unknown error';
    reconciliations.push({
      number: violation.number,
      status: 'failed',
      reason: violation.reason,
      previousMilestone: violation.milestone,
      milestone: defaultMilestone.title,
      milestoneNumber: defaultMilestone.number,
      triggers: violation.triggers,
      error: errorMessage
    });
    remainingViolations.push(violation);
  }

  const reasonCounts = remainingViolations.reduce((acc, entry) => {
    const key = entry.reason ?? 'unknown';
    acc[key] = (acc[key] ?? 0) + 1;
    return acc;
  }, {});
  const status = remainingViolations.length === 0 ? 'pass' : (warnOnly ? 'warn' : 'fail');

  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    repository: options.repo,
    state: options.state,
    execution: buildExecutionState(status),
    flags: {
      applyDefaultMilestone: options.applyDefaultMilestone,
      warnOnly,
      requireOpenMilestone,
      createDefaultMilestone
    },
    policy: {
      path: policy.path,
      requiredLabels,
      titlePriorityPattern,
      defaultMilestone: defaultMilestoneTitle,
      defaultMilestoneDueOn
    },
    milestones: {
      ...summarizeMilestones(milestones),
      defaultMilestone: defaultMilestone
        ? {
            number: defaultMilestone.number,
            title: defaultMilestone.title,
            state: defaultMilestone.state,
            dueOn: defaultMilestone.dueOn ?? defaultMilestoneDueOn ?? null
          }
        : null,
      createdDefaultMilestone: createdDefaultMilestone != null
    },
    summary: {
      issueCount: evaluations.length,
      requiredIssueCount: requiredIssues.length,
      triggerCounts,
      initialViolationCount: violations.length,
      remainingViolationCount: remainingViolations.length,
      remainingReasonCounts: reasonCounts,
      assignedDefaultMilestoneCount: reconciliations.filter((entry) => entry.status === 'assigned').length,
      failedAssignmentsCount: reconciliations.filter((entry) => entry.status === 'failed').length
    },
    violations: remainingViolations,
    reconciliations
  };

  const reportPath = await writeJsonReportFn(options.reportPath, report);
  console.log(`[milestone-hygiene] report: ${reportPath}`);
  console.log(
    `[milestone-hygiene] status=${status} issues=${report.summary.issueCount} required=${report.summary.requiredIssueCount} remaining=${report.summary.remainingViolationCount}`
  );
  for (const entry of remainingViolations) {
    const triggers = entry.triggers.join(',') || 'unknown';
    console.log(`[milestone-hygiene] issue=#${entry.number} reason=${entry.reason} triggers=${triggers}`);
  }
  if (createdDefaultMilestone) {
    console.log(
      `[milestone-hygiene] created default milestone title=${createdDefaultMilestone.title} number=${createdDefaultMilestone.number}`
    );
  }
  for (const entry of reconciliations) {
    if (entry.status === 'assigned') {
      console.log(`[milestone-hygiene] assigned default milestone issue=#${entry.number} milestone=${entry.milestone}`);
    } else {
      console.log(`[milestone-hygiene] failed to assign milestone issue=#${entry.number}: ${entry.error}`);
    }
  }

  const exitCode = remainingViolations.length === 0 || warnOnly ? 0 : 1;
  return { exitCode, report, reportPath, help: false };
}

export async function runMilestoneHygieneWithFailureReport({
  argv = process.argv.slice(2),
  env = process.env,
  now = new Date(),
  runGhJsonFn = runGhJson,
  runGhFn = runGh,
  loadPolicyFn = loadPolicy,
  writeJsonReportFn = writeJsonReport
} = {}) {
  try {
    return await runMilestoneHygiene({
      argv,
      env,
      now,
      runGhJsonFn,
      runGhFn,
      loadPolicyFn,
      writeJsonReportFn
    });
  } catch (error) {
    const rawArgs = Array.isArray(argv) ? argv : [];
    const repo = normalizeText(findOptionValue(rawArgs, '--repo')) ?? normalizeText(env.GITHUB_REPOSITORY);
    const reportPath = findOptionValue(rawArgs, '--report') ?? DEFAULT_REPORT_PATH;
    const state = normalizeText(findOptionValue(rawArgs, '--state')) ?? 'open';
    const policyPath = findOptionValue(rawArgs, '--policy') ?? DEFAULT_POLICY_PATH;

    if (!repo) {
      throw error;
    }

    let policy = null;
    try {
      policy = await loadPolicyFn(policyPath);
    } catch {
      policy = null;
    }

    const fallbackRequiredLabels = parseList(findOptionValue(rawArgs, '--required-labels'));
    const fallbackOptions = {
      repo,
      state,
      policyPath,
      reportPath,
      requiredLabels: fallbackRequiredLabels.length > 0 ? fallbackRequiredLabels : null,
      titlePriorityPattern: normalizeText(findOptionValue(rawArgs, '--title-priority-pattern')),
      defaultMilestone: normalizeText(findOptionValue(rawArgs, '--default-milestone')),
      defaultMilestoneDueOn: normalizeText(findOptionValue(rawArgs, '--default-milestone-due-on')),
      applyDefaultMilestone: rawArgs.includes('--apply-default-milestone'),
      createDefaultMilestone: rawArgs.includes('--create-default-milestone'),
      warnOnly: rawArgs.includes('--warn-only') ? true : null,
      requireOpenMilestone: rawArgs.includes('--allow-closed-milestone') ? false : null
    };

    const report = buildFallbackFailureReport({
      now,
      options: fallbackOptions,
      policy,
      error
    });
    const writtenReportPath = await writeJsonReportFn(reportPath, report);

    console.log(`[milestone-hygiene] report: ${writtenReportPath}`);
    console.error(
      `[milestone-hygiene] status=error issues=${report.summary.issueCount} required=${report.summary.requiredIssueCount} remaining=${report.summary.remainingViolationCount}`
    );
    console.error(`[milestone-hygiene] ${report.execution.errors.join('; ')}`);
    return { exitCode: 1, report, reportPath: writtenReportPath, help: false };
  }
}

function printHelp() {
  console.log(`Usage:
  node tools/priority/check-issue-milestones.mjs [options]

Options:
  --repo <owner/repo>              Repository slug (defaults to GITHUB_REPOSITORY)
  --state <open|all>               Issue state filter (default: open)
  --limit <n>                      Max issues to evaluate (default: 200)
  --policy <path>                  Policy file (default: ${DEFAULT_POLICY_PATH})
  --required-labels <a,b,c>        Override policy labels requiring milestones
  --title-priority-pattern <regex> Override policy title regex requiring milestones
  --allow-closed-milestone         Permit closed milestones for required issues
  --default-milestone <title>      Default milestone title for reconciliation mode
  --default-milestone-due-on <iso> Due date used when creating a missing default milestone
  --apply-default-milestone        Assign default milestone to violating issues
  --create-default-milestone       Create missing default milestone in apply mode
  --report <path>                  Report path (default: ${DEFAULT_REPORT_PATH})
  --warn-only                      Emit warnings but do not fail
  -h, --help                       Show this help`);
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  runMilestoneHygieneWithFailureReport()
    .then(({ exitCode, help }) => {
      if (help) {
        printHelp();
      }
      process.exit(exitCode);
    })
    .catch((error) => {
      console.error(`[milestone-hygiene] ${error.message || error}`);
      process.exit(1);
    });
}
