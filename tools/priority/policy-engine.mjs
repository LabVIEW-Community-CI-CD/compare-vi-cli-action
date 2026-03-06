#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { getRepoRoot } from './lib/branch-utils.mjs';

export const ISSUE_ROUTING_POLICY_SCHEMA = 'issue-routing-policy@v1';
export const POLICY_DECISION_REPORT_SCHEMA = 'priority/policy-decision-report@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'priority', 'issue-routing-policy.json');
export const DEFAULT_BRANCH_POLICY_PATH = path.join('tools', 'priority', 'policy.json');
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'ops', 'policy-decision-report.json');

const VALID_ACTION_TYPES = new Set(['open-issue', 'update-issue', 'comment', 'pause-queue', 'noop']);
const VALID_PRIORITIES = new Set(['P0', 'P1', 'P2']);
const VALID_SEVERITIES = new Set(['critical', 'high', 'medium', 'low', 'info']);

function printUsage() {
  console.log('Usage: node tools/priority/policy-engine.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --event <path>               Incident event JSON path (required).');
  console.log(`  --policy <path>              Routing policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --branch-policy <path>       Branch/ruleset policy path (default: ${DEFAULT_BRANCH_POLICY_PATH}).`);
  console.log(`  --report <path>              Decision report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --branch <name>              Optional branch override for event evaluation.');
  console.log('  --dry-run                    Evaluate policy only; no side effects (default).');
  console.log('  -h, --help                   Show help and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function normalizeLower(value) {
  const text = normalizeText(value);
  return text ? text.toLowerCase() : null;
}

function normalizeSeverity(value) {
  const severity = normalizeLower(value) ?? 'medium';
  return VALID_SEVERITIES.has(severity) ? severity : 'medium';
}

function normalizePriority(value) {
  const priority = normalizeText(value)?.toUpperCase() ?? 'P2';
  return VALID_PRIORITIES.has(priority) ? priority : 'P2';
}

function normalizeLabels(values) {
  const labels = [];
  for (const value of Array.isArray(values) ? values : []) {
    const normalized = normalizeLower(value);
    if (!normalized) continue;
    labels.push(normalized);
  }
  return [...new Set(labels)].sort((left, right) => left.localeCompare(right));
}

function normalizeStringArray(values) {
  const normalized = [];
  for (const value of Array.isArray(values) ? values : []) {
    const item = normalizeLower(value);
    if (!item) continue;
    normalized.push(item);
  }
  return [...new Set(normalized)].sort((left, right) => left.localeCompare(right));
}

function stableSortValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => stableSortValue(item));
  }
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const sorted = {};
    for (const key of Object.keys(value).sort((left, right) => left.localeCompare(right))) {
      sorted[key] = stableSortValue(value[key]);
    }
    return sorted;
  }
  return value;
}

function digestValue(value) {
  const hash = createHash('sha256');
  hash.update(JSON.stringify(stableSortValue(value)));
  return hash.digest('hex');
}

function parseBoolean(value) {
  return value === true;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    eventPath: null,
    policyPath: DEFAULT_POLICY_PATH,
    branchPolicyPath: DEFAULT_BRANCH_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    branchOverride: null,
    dryRun: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (token === '--event' || token === '--policy' || token === '--branch-policy' || token === '--report' || token === '--branch') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--event') options.eventPath = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--branch-policy') options.branchPolicyPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--branch') options.branchOverride = normalizeLower(next);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (options.help) {
    return options;
  }
  if (!options.eventPath) {
    throw new Error('Missing required --event <path> option.');
  }
  return options;
}

async function readJsonFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`File not found: ${resolved}`);
  }
  const content = await readFile(resolved, 'utf8');
  try {
    return JSON.parse(content);
  } catch (error) {
    throw new Error(`Invalid JSON in ${resolved}: ${error.message}`);
  }
}

function normalizeAction(action = {}) {
  const type = normalizeLower(action.type) ?? 'comment';
  if (!VALID_ACTION_TYPES.has(type)) {
    throw new Error(`Invalid action type '${action.type}'.`);
  }
  return {
    type,
    priority: normalizePriority(action.priority),
    labels: normalizeLabels(action.labels),
    owner: normalizeText(action.owner),
    titlePrefix: normalizeText(action.titlePrefix),
    reason: normalizeText(action.reason)
  };
}

function normalizeRule(rule = {}, index = 0) {
  const id = normalizeText(rule.id);
  if (!id) {
    throw new Error(`Rule at index ${index} is missing id.`);
  }
  const rawOrder = Number(rule.order);
  const order = Number.isInteger(rawOrder) && rawOrder >= 0 ? rawOrder : 1000;
  const enabled = rule.enabled !== false;
  const match = rule.match ?? {};
  return {
    id,
    order,
    enabled,
    match: {
      sourceTypes: normalizeStringArray(match.sourceTypes),
      incidentClasses: normalizeStringArray(match.incidentClasses),
      severities: normalizeStringArray(match.severities),
      branches: normalizeStringArray(match.branches),
      requiresQueueManagedBranch: parseBoolean(match.requiresQueueManagedBranch),
      requiresExactCheckNames: parseBoolean(match.requiresExactCheckNames)
    },
    action: normalizeAction(rule.action ?? {})
  };
}

export function normalizePolicy(policy = {}, { policyPath = DEFAULT_POLICY_PATH } = {}) {
  if (policy?.schema !== ISSUE_ROUTING_POLICY_SCHEMA) {
    throw new Error(`Invalid policy schema '${policy?.schema}'. Expected '${ISSUE_ROUTING_POLICY_SCHEMA}'.`);
  }
  const rulesRaw = Array.isArray(policy.rules) ? policy.rules : [];
  const rules = rulesRaw
    .map((rule, index) => normalizeRule(rule, index))
    .sort((left, right) => {
      if (left.order !== right.order) return left.order - right.order;
      return left.id.localeCompare(right.id);
    });
  return {
    schema: ISSUE_ROUTING_POLICY_SCHEMA,
    schemaVersion: normalizeText(policy.schemaVersion) ?? '1.0.0',
    description: normalizeText(policy.description),
    queueManagedBranches: normalizeStringArray(policy.queueManagedBranches),
    defaultAction: normalizeAction(policy.defaultAction ?? {}),
    rules,
    policyPath: normalizeText(policyPath) ?? DEFAULT_POLICY_PATH
  };
}

function extractQueueManagedBranchesFromBranchPolicy(branchPolicy = {}) {
  const branches = new Set();
  const rulesets = branchPolicy?.rulesets;
  if (!rulesets || typeof rulesets !== 'object') {
    return branches;
  }
  for (const ruleset of Object.values(rulesets)) {
    if (!ruleset?.merge_queue) {
      continue;
    }
    const includes = Array.isArray(ruleset.includes) ? ruleset.includes : [];
    for (const include of includes) {
      const match = String(include).match(/^refs\/heads\/(?<branch>.+)$/i);
      if (!match?.groups?.branch) continue;
      if (match.groups.branch.includes('*')) continue;
      branches.add(match.groups.branch.toLowerCase());
    }
  }
  return branches;
}

function toEventPayload(payload = {}) {
  if (payload?.schema === 'priority/event-ingest-report@v1' && payload?.event) {
    return payload.event;
  }
  return payload;
}

function normalizeIncidentEvent(payload = {}, branchOverride = null) {
  const event = toEventPayload(payload);
  const sourceType = normalizeLower(event.sourceType) ?? 'incident-event';
  const incidentClass = normalizeLower(event.incidentClass ?? event.class ?? event.type) ?? 'incident-unknown';
  const severity = normalizeSeverity(event.severity);
  const branch = branchOverride ?? normalizeLower(event.branch);
  const sha = normalizeLower(event.sha);
  const signature = normalizeText(event.signature) ?? incidentClass;
  const labels = normalizeLabels(event.suggestedLabels ?? event.labels);
  const metadata = event.metadata && typeof event.metadata === 'object' ? stableSortValue(event.metadata) : {};
  return {
    schema: normalizeText(event.schema),
    sourceType,
    incidentClass,
    severity,
    repository: normalizeText(event.repository),
    branch,
    sha,
    signature,
    fingerprint: normalizeText(event.fingerprint) ?? digestValue({ sourceType, incidentClass, branch, sha, signature }),
    summary: normalizeText(event.summary),
    suggestedLabels: labels,
    metadata
  };
}

export function evaluateExactCheckNameGate(metadata = {}) {
  const expected = normalizeStringArray(metadata.expectedChecks);
  const observed = normalizeStringArray(metadata.observedChecks);
  if (expected.length === 0 && observed.length === 0) {
    return {
      required: false,
      exactMatch: true,
      expected,
      observed,
      missing: [],
      extra: []
    };
  }

  const expectedSet = new Set(expected);
  const observedSet = new Set(observed);
  const missing = expected.filter((check) => !observedSet.has(check));
  const extra = observed.filter((check) => !expectedSet.has(check));
  return {
    required: true,
    exactMatch: missing.length === 0 && extra.length === 0,
    expected,
    observed,
    missing,
    extra
  };
}

function evaluateRuleMatch(rule, context) {
  const reasons = [];
  if (!rule.enabled) reasons.push('rule-disabled');
  if (rule.match.sourceTypes.length > 0 && !rule.match.sourceTypes.includes(context.event.sourceType)) {
    reasons.push('source-type-mismatch');
  }
  if (rule.match.incidentClasses.length > 0 && !rule.match.incidentClasses.includes(context.event.incidentClass)) {
    reasons.push('incident-class-mismatch');
  }
  if (rule.match.severities.length > 0 && !rule.match.severities.includes(context.event.severity)) {
    reasons.push('severity-mismatch');
  }
  if (rule.match.branches.length > 0 && !rule.match.branches.includes(context.event.branch ?? '')) {
    reasons.push('branch-mismatch');
  }
  if (rule.match.requiresQueueManagedBranch && !context.queueManagedBranch) {
    reasons.push('queue-managed-branch-required');
  }
  if (rule.match.requiresExactCheckNames && !context.checkNameGate.exactMatch) {
    reasons.push('exact-check-name-mismatch');
  }
  return {
    matched: reasons.length === 0,
    reasons
  };
}

export function evaluateRoutingPolicy({
  policy,
  event,
  queueManagedBranches = new Set(),
  now = new Date()
}) {
  const queueManagedBranch = Boolean(event.branch && queueManagedBranches.has(event.branch));
  const checkNameGate = evaluateExactCheckNameGate(event.metadata ?? {});
  const context = { event, queueManagedBranch, checkNameGate };
  const ruleEvaluations = [];
  let selectedRule = null;
  let selectedAction = null;

  for (const rule of policy.rules) {
    const evaluation = evaluateRuleMatch(rule, context);
    ruleEvaluations.push({
      id: rule.id,
      order: rule.order,
      matched: evaluation.matched,
      reasons: evaluation.reasons
    });
    if (evaluation.matched && !selectedRule) {
      selectedRule = rule;
      selectedAction = rule.action;
    }
  }

  if (!selectedAction) {
    selectedAction = policy.defaultAction;
  }

  const labels = normalizeLabels([...(selectedAction.labels ?? []), ...(event.suggestedLabels ?? [])]);
  return {
    generatedAt: now.toISOString(),
    queueManagedBranch,
    checkNameGate,
    selectedRuleId: selectedRule?.id ?? null,
    selectedAction: {
      type: selectedAction.type,
      priority: selectedAction.priority,
      labels,
      owner: selectedAction.owner,
      titlePrefix: selectedAction.titlePrefix,
      reason: selectedAction.reason ?? (selectedRule ? `matched:${selectedRule.id}` : 'default-fallback')
    },
    ruleEvaluations
  };
}

async function writeReport(reportPath, payload) {
  const resolved = path.resolve(reportPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runPolicyEngine({
  argv = process.argv,
  now = new Date(),
  repoRoot = getRepoRoot(process.cwd()),
  readJsonFileFn = readJsonFile,
  writeReportFn = writeReport
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const resolvedPolicyPath = path.resolve(repoRoot, options.policyPath);
  const resolvedBranchPolicyPath = path.resolve(repoRoot, options.branchPolicyPath);
  const resolvedEventPath = path.resolve(repoRoot, options.eventPath);
  let report = null;
  let exitCode = 0;

  try {
    const [policyPayload, eventPayload, branchPolicy] = await Promise.all([
      readJsonFileFn(resolvedPolicyPath),
      readJsonFileFn(resolvedEventPath),
      readJsonFileFn(resolvedBranchPolicyPath)
    ]);
    const policy = normalizePolicy(policyPayload, { policyPath: path.relative(repoRoot, resolvedPolicyPath) });
    const event = normalizeIncidentEvent(eventPayload, options.branchOverride);
    const queueManagedBranches = new Set(
      policy.queueManagedBranches.length > 0
        ? policy.queueManagedBranches
        : Array.from(extractQueueManagedBranchesFromBranchPolicy(branchPolicy)).sort()
    );
    const evaluation = evaluateRoutingPolicy({
      policy,
      event,
      queueManagedBranches,
      now
    });

    report = {
      schema: POLICY_DECISION_REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: 'pass',
      dryRun: true,
      inputs: {
        eventPath: resolvedEventPath,
        policyPath: resolvedPolicyPath,
        branchPolicyPath: resolvedBranchPolicyPath
      },
      policy: {
        schema: policy.schema,
        schemaVersion: policy.schemaVersion,
        digest: digestValue(policy),
        ruleCount: policy.rules.length
      },
      event: {
        fingerprint: event.fingerprint,
        sourceType: event.sourceType,
        incidentClass: event.incidentClass,
        severity: event.severity,
        branch: event.branch,
        sha: event.sha,
        signature: event.signature,
        suggestedLabels: event.suggestedLabels
      },
      branchContext: {
        queueManagedBranches: Array.from(queueManagedBranches).sort(),
        branch: event.branch,
        queueManagedBranch: evaluation.queueManagedBranch
      },
      checkNameGate: evaluation.checkNameGate,
      evaluation: {
        selectedRuleId: evaluation.selectedRuleId,
        ruleEvaluations: evaluation.ruleEvaluations
      },
      decision: evaluation.selectedAction,
      errors: []
    };
  } catch (error) {
    exitCode = 1;
    report = {
      schema: POLICY_DECISION_REPORT_SCHEMA,
      schemaVersion: '1.0.0',
      generatedAt: now.toISOString(),
      status: 'fail',
      dryRun: true,
      inputs: {
        eventPath: resolvedEventPath,
        policyPath: resolvedPolicyPath,
        branchPolicyPath: resolvedBranchPolicyPath
      },
      policy: {
        schema: ISSUE_ROUTING_POLICY_SCHEMA,
        schemaVersion: null,
        digest: null,
        ruleCount: 0
      },
      event: null,
      branchContext: {
        queueManagedBranches: [],
        branch: options.branchOverride,
        queueManagedBranch: false
      },
      checkNameGate: {
        required: false,
        exactMatch: true,
        expected: [],
        observed: [],
        missing: [],
        extra: []
      },
      evaluation: {
        selectedRuleId: null,
        ruleEvaluations: []
      },
      decision: {
        type: 'noop',
        priority: 'P2',
        labels: [],
        owner: null,
        titlePrefix: null,
        reason: null
      },
      errors: [error.message || String(error)]
    };
  }

  const resolvedReportPath = await writeReportFn(options.reportPath, report);
  console.log(`[policy-engine] report: ${resolvedReportPath}`);
  if (exitCode !== 0) {
    console.error(`[policy-engine] ${report.errors.join('; ')}`);
  } else {
    console.log(
      `[policy-engine] selectedRule=${report.evaluation.selectedRuleId ?? 'default'} action=${report.decision.type} priority=${report.decision.priority}`
    );
  }
  return { exitCode, report, reportPath: resolvedReportPath };
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectExecution) {
  runPolicyEngine().then(({ exitCode }) => {
    process.exit(exitCode);
  }).catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}
