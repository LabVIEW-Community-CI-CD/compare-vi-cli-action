#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { normalizeCatalog, DEFAULT_CATALOG_PATH } from './canary-catalog.mjs';
import {
  DEFAULT_BRANCH_POLICY_PATH,
  DEFAULT_POLICY_PATH,
  POLICY_DECISION_REPORT_SCHEMA,
  evaluateRoutingPolicy,
  normalizePolicy
} from './policy-engine.mjs';
import { runIssueRouter } from './issue-router.mjs';
import { computeIncidentFingerprint } from './event-ingest.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';

export const REPORT_SCHEMA = 'priority/canary-replay-conformance-report@v1';
export const DEFAULT_REQUIRED_CHECKS_PATH = path.join('tools', 'policy', 'branch-required-checks.json');
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'canary', 'canary-replay-conformance-report.json');
export const DEFAULT_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';

function printUsage() {
  console.log('Usage: node tools/priority/canary-replay-conformance.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --catalog <path>            Canary signal catalog path (default: ${DEFAULT_CATALOG_PATH}).`);
  console.log(`  --policy <path>             Issue routing policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --branch-policy <path>      Branch policy path (default: ${DEFAULT_BRANCH_POLICY_PATH}).`);
  console.log(`  --required-checks <path>    Required-check mapping path (default: ${DEFAULT_REQUIRED_CHECKS_PATH}).`);
  console.log(`  --report <path>             Output report path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --repo <owner/repo>         Repository slug for routing simulation (default: ${DEFAULT_REPOSITORY}).`);
  console.log('  --strict                    Fail when determinism checks fail (default: true).');
  console.log('  --no-strict                 Emit warning status without non-zero exit.');
  console.log('  -h, --help                  Show help and exit.');
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

function normalizeLabels(values) {
  const labels = [];
  for (const value of Array.isArray(values) ? values : []) {
    const label = normalizeLower(value);
    if (!label) continue;
    labels.push(label);
  }
  return [...new Set(labels)].sort((left, right) => left.localeCompare(right));
}

function stableSortValue(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => stableSortValue(entry));
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

function digestText(value) {
  const hash = createHash('sha256');
  hash.update(String(value));
  return hash.digest('hex');
}

function parseIssueNumberFromPath(pathname) {
  const match = pathname.match(/\/issues\/(?<number>\d+)(?:\/comments)?$/i);
  if (!match?.groups?.number) {
    return null;
  }
  const value = Number(match.groups.number);
  return Number.isInteger(value) && value > 0 ? value : null;
}

function cloneIssue(issue) {
  return {
    number: issue.number,
    state: issue.state,
    title: issue.title,
    body: issue.body,
    labels: issue.labels.map((label) => ({ name: label.name })),
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    html_url: issue.html_url
  };
}

function buildMockIssueApi({ now, repository }) {
  let nextIssueNumber = 9000;
  const issues = new Map();

  function listIssueNumbersByMarker(marker) {
    const matches = [];
    for (const issue of issues.values()) {
      if (!issue.body.includes(marker)) continue;
      matches.push(issue.number);
    }
    matches.sort((left, right) => left - right);
    return matches;
  }

  function assertRepo(pathname) {
    const prefix = `/repos/${repository}/`;
    if (!pathname.startsWith(prefix)) {
      throw new Error(`unexpected-repo-path:${pathname}`);
    }
  }

  async function request(url, options = {}) {
    const parsed = new URL(url);
    const pathname = parsed.pathname;
    const method = (options.method || 'GET').toUpperCase();

    if (pathname === '/search/issues' && method === 'GET') {
      const query = parsed.searchParams.get('q') || '';
      const markerMatch = query.match(/"([^"]+)"/);
      const marker = markerMatch?.[1] || '';
      const numbers = marker ? listIssueNumbersByMarker(marker) : [];
      return {
        items: numbers.map((number) => ({ number }))
      };
    }

    assertRepo(pathname);

    if (pathname === `/repos/${repository}/issues` && method === 'POST') {
      const number = nextIssueNumber;
      nextIssueNumber += 1;
      const issue = {
        number,
        state: 'open',
        title: String(options.body?.title || ''),
        body: String(options.body?.body || ''),
        labels: normalizeLabels(options.body?.labels).map((name) => ({ name })),
        created_at: now.toISOString(),
        updated_at: now.toISOString(),
        html_url: `https://example.test/${repository}/issues/${number}`
      };
      issues.set(number, issue);
      return cloneIssue(issue);
    }

    const issueNumber = parseIssueNumberFromPath(pathname);
    if (!issueNumber || !issues.has(issueNumber)) {
      throw new Error(`unexpected-issue-path:${method}:${pathname}`);
    }

    const issue = issues.get(issueNumber);

    if (pathname.endsWith('/comments') && method === 'POST') {
      issue.updated_at = now.toISOString();
      return {
        id: Number(`1${issueNumber}`),
        html_url: `${issue.html_url}#issuecomment-${issueNumber}`,
        body: String(options.body?.body || '')
      };
    }

    if (method === 'GET') {
      return cloneIssue(issue);
    }

    if (method === 'PATCH') {
      if (Object.prototype.hasOwnProperty.call(options.body || {}, 'state')) {
        issue.state = normalizeLower(options.body.state) || issue.state;
      }
      if (Object.prototype.hasOwnProperty.call(options.body || {}, 'title')) {
        issue.title = String(options.body.title || '');
      }
      if (Object.prototype.hasOwnProperty.call(options.body || {}, 'body')) {
        issue.body = String(options.body.body || '');
      }
      if (Object.prototype.hasOwnProperty.call(options.body || {}, 'labels')) {
        issue.labels = normalizeLabels(options.body.labels).map((name) => ({ name }));
      }
      issue.updated_at = now.toISOString();
      return cloneIssue(issue);
    }

    throw new Error(`unsupported-route:${method}:${pathname}`);
  }

  return {
    request,
    state: {
      get issues() {
        return Array.from(issues.values()).map((issue) => cloneIssue(issue));
      }
    }
  };
}

function readJsonFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`File not found: ${resolved}`);
  }
  try {
    return JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (error) {
    throw new Error(`Invalid JSON in ${resolved}: ${error.message}`);
  }
}

function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function normalizeRepoSlug(value) {
  const slug = normalizeText(value) || DEFAULT_REPOSITORY;
  if (!slug.includes('/')) {
    throw new Error(`Invalid repository slug '${slug}'. Expected owner/repo.`);
  }
  return slug;
}

function buildBranchRequiredChecksMap(payload = {}) {
  const map = new Map();
  const branches = payload?.branches;
  if (!branches || typeof branches !== 'object') {
    return map;
  }
  for (const [branch, checks] of Object.entries(branches)) {
    const normalizedBranch = normalizeLower(branch);
    if (!normalizedBranch || normalizedBranch.includes('*')) continue;
    const normalizedChecks = [];
    for (const check of Array.isArray(checks) ? checks : []) {
      const text = normalizeText(check);
      if (!text) continue;
      normalizedChecks.push(text);
    }
    const deduped = [...new Set(normalizedChecks)];
    map.set(normalizedBranch, deduped);
  }
  return map;
}

function buildReplayScenarios(signals) {
  const single = signals.map((signal, index) => ({ signal, ordinal: index + 1 }));
  const repeated = [...signals, ...signals].map((signal, index) => ({ signal, ordinal: index + 1 }));
  const reordered = [...signals].reverse().map((signal, index) => ({ signal, ordinal: index + 1 }));
  return [
    {
      id: 'single',
      description: 'Single pass through canonical signal catalog.',
      entries: single
    },
    {
      id: 'repeated',
      description: 'Replay identical signal set twice to validate dedupe/upsert.',
      entries: repeated
    },
    {
      id: 'reordered',
      description: 'Replay same signal set in reverse order to validate deterministic ordering.',
      entries: reordered
    }
  ];
}

function buildDeterministicEvent(signal, requiredChecksByBranch, repository) {
  const branch = signal.branch === '*' ? 'develop' : signal.branch;
  const sha = createHash('sha1').update(signal.key).digest('hex');
  const signature = signal.signaturePattern;
  const fingerprint = computeIncidentFingerprint({
    sourceType: signal.sourceType,
    incidentClass: signal.incidentClass,
    branch,
    sha,
    signature
  }).sha256;
  const metadata = {
    signalId: signal.id
  };
  if (signal.sourceType === 'required-check-drift') {
    const checks = requiredChecksByBranch.get(branch) ?? requiredChecksByBranch.get('develop') ?? ['lint'];
    metadata.expectedChecks = [...checks];
    metadata.observedChecks = [...checks];
  }
  return {
    schema: 'incident-event@v1',
    sourceType: signal.sourceType,
    incidentClass: signal.incidentClass,
    severity: signal.severity,
    repository,
    branch,
    sha,
    signature,
    fingerprint,
    summary: `${signal.id} replay`,
    suggestedLabels: [...signal.labels],
    metadata
  };
}

function deterministicEntryComparator(left, right) {
  if (left.event.fingerprint !== right.event.fingerprint) {
    return left.event.fingerprint.localeCompare(right.event.fingerprint);
  }
  if (left.signal.id !== right.signal.id) {
    return left.signal.id.localeCompare(right.signal.id);
  }
  return left.ordinal - right.ordinal;
}

export function stripGeneratedTimestamps(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => stripGeneratedTimestamps(entry));
  }
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const output = {};
    for (const [key, entry] of Object.entries(value)) {
      if (key === 'generatedAt') continue;
      output[key] = stripGeneratedTimestamps(entry);
    }
    return output;
  }
  return value;
}

function buildMultisetKey(entries) {
  const counts = new Map();
  for (const entry of entries) {
    counts.set(entry.event.fingerprint, (counts.get(entry.event.fingerprint) ?? 0) + 1);
  }
  const compact = Array.from(counts.entries())
    .sort((left, right) => left[0].localeCompare(right[0]))
    .map(([fingerprint, count]) => ({ fingerprint, count }));
  return digestValue(compact);
}

function buildPolicyDecisionReport({
  now,
  event,
  policy,
  queueManagedBranches,
  evaluation,
  reportPath
}) {
  return {
    schema: POLICY_DECISION_REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'pass',
    dryRun: true,
    inputs: {
      eventPath: `replay:${event.metadata?.signalId ?? 'unknown'}`,
      policyPath: 'replay:policy',
      branchPolicyPath: 'replay:branch-policy',
      reportPath
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
      suggestedLabels: [...event.suggestedLabels]
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
}

function ensureExpectedRoute(signal, decision) {
  const expectedLabels = normalizeLabels(signal.expectedRoute.labels);
  const actualLabels = normalizeLabels(decision.labels);
  return {
    actionMatches: signal.expectedRoute.actionType === decision.type,
    priorityMatches: signal.expectedRoute.priority === decision.priority,
    labelsMatch:
      expectedLabels.length === actualLabels.length &&
      expectedLabels.every((label, index) => label === actualLabels[index]),
    expected: {
      actionType: signal.expectedRoute.actionType,
      priority: signal.expectedRoute.priority,
      labels: expectedLabels
    },
    actual: {
      actionType: decision.type,
      priority: decision.priority,
      labels: actualLabels
    }
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    catalogPath: DEFAULT_CATALOG_PATH,
    policyPath: DEFAULT_POLICY_PATH,
    branchPolicyPath: DEFAULT_BRANCH_POLICY_PATH,
    requiredChecksPath: DEFAULT_REQUIRED_CHECKS_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    repository: DEFAULT_REPOSITORY,
    strict: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--strict') {
      options.strict = true;
      continue;
    }
    if (token === '--no-strict') {
      options.strict = false;
      continue;
    }
    if (
      token === '--catalog' ||
      token === '--policy' ||
      token === '--branch-policy' ||
      token === '--required-checks' ||
      token === '--report' ||
      token === '--repo'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--catalog') options.catalogPath = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--branch-policy') options.branchPolicyPath = next;
      if (token === '--required-checks') options.requiredChecksPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--repo') options.repository = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  options.repository = normalizeRepoSlug(options.repository);
  return options;
}

export async function runCanaryReplayConformance({
  argv = process.argv,
  now = new Date(),
  repoRoot = getRepoRoot(),
  readJsonFileFn = readJsonFile,
  writeJsonFn = writeJsonFile,
  runIssueRouterFn = runIssueRouter
} = {}) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const resolvedCatalogPath = path.resolve(repoRoot, options.catalogPath);
  const resolvedPolicyPath = path.resolve(repoRoot, options.policyPath);
  const resolvedBranchPolicyPath = path.resolve(repoRoot, options.branchPolicyPath);
  const resolvedRequiredChecksPath = path.resolve(repoRoot, options.requiredChecksPath);
  const queueManagedOrderingDigests = new Map();
  const baselineDecisionDigests = new Map();
  const decisionDrifts = [];
  const orderingDrifts = [];
  const routeMismatches = [];
  const scenarios = [];
  let errorMessages = [];

  try {
    const catalogPayload = await readJsonFileFn(resolvedCatalogPath);
    const policyPayload = await readJsonFileFn(resolvedPolicyPath);
    await readJsonFileFn(resolvedBranchPolicyPath);
    const requiredChecksPayload = await readJsonFileFn(resolvedRequiredChecksPath);
    const catalog = normalizeCatalog(catalogPayload);
    const policy = normalizePolicy(policyPayload, { policyPath: resolvedPolicyPath });
    const queueManagedBranches = new Set(policy.queueManagedBranches);
    const requiredChecksByBranch = buildBranchRequiredChecksMap(requiredChecksPayload);

    const replayScenarios = buildReplayScenarios(catalog.signals);
    for (const scenario of replayScenarios) {
      const mockApi = buildMockIssueApi({
        now,
        repository: options.repository
      });
      const preparedEntries = scenario.entries.map(({ signal, ordinal }) => ({
        signal,
        ordinal,
        event: buildDeterministicEvent(signal, requiredChecksByBranch, options.repository)
      }));
      const orderedEntries = [...preparedEntries].sort(deterministicEntryComparator);
      const createCountByFingerprint = new Map();
      const scenarioRouteMismatches = [];
      const scenarioDecisionDrifts = [];
      const operations = [];
      const decisionSnapshots = [];

      for (const entry of orderedEntries) {
        const evaluation = evaluateRoutingPolicy({
          policy,
          event: entry.event,
          queueManagedBranches,
          now
        });

        const decisionReport = buildPolicyDecisionReport({
          now,
          event: entry.event,
          policy,
          queueManagedBranches,
          evaluation,
          reportPath: options.reportPath
        });
        const sanitized = stripGeneratedTimestamps(decisionReport);
        const sanitizedDigest = digestValue(sanitized);
        const baseline = baselineDecisionDigests.get(entry.event.fingerprint);
        if (!baseline) {
          baselineDecisionDigests.set(entry.event.fingerprint, sanitizedDigest);
        } else if (baseline !== sanitizedDigest) {
          const drift = {
            scenario: scenario.id,
            signalId: entry.signal.id,
            fingerprint: entry.event.fingerprint,
            expectedDigest: baseline,
            actualDigest: sanitizedDigest
          };
          decisionDrifts.push(drift);
          scenarioDecisionDrifts.push(drift);
        }

        const routeExpectation = ensureExpectedRoute(entry.signal, decisionReport.decision);
        if (!routeExpectation.actionMatches || !routeExpectation.priorityMatches || !routeExpectation.labelsMatch) {
          const mismatch = {
            scenario: scenario.id,
            signalId: entry.signal.id,
            fingerprint: entry.event.fingerprint,
            expected: routeExpectation.expected,
            actual: routeExpectation.actual
          };
          routeMismatches.push(mismatch);
          scenarioRouteMismatches.push(mismatch);
        }

        const routerResult = await runIssueRouterFn(
          {
            decisionPath: `replay:${scenario.id}:${entry.signal.id}:decision`,
            reportPath: `replay:${scenario.id}:issue-routing-report`,
            repo: options.repository,
            dryRun: false
          },
          {
            now,
            readJsonFileFn: async () => decisionReport,
            writeJsonFn: (filePath, payload) => ({ filePath, payload }),
            resolveRepositorySlugFn: () => options.repository,
            resolveTokenFn: () => 'replay-token',
            requestGitHubJsonFn: mockApi.request
          }
        );

        const action = routerResult.report?.route?.operation?.action || 'none';
        if (action.split('-').includes('create')) {
          createCountByFingerprint.set(
            entry.event.fingerprint,
            (createCountByFingerprint.get(entry.event.fingerprint) ?? 0) + 1
          );
        }

        operations.push({
          signalId: entry.signal.id,
          fingerprint: entry.event.fingerprint,
          action,
          issueNumber: routerResult.report?.route?.operation?.issueNumber ?? null,
          candidateCount: routerResult.report?.route?.dedupe?.candidateCount ?? 0
        });
        decisionSnapshots.push({
          signalId: entry.signal.id,
          fingerprint: entry.event.fingerprint,
          digest: digestValue(decisionReport),
          digestWithoutGeneratedAt: sanitizedDigest,
          policyDecision: decisionReport
        });
      }

      const duplicateCreateFingerprints = Array.from(createCountByFingerprint.entries())
        .filter(([, count]) => count > 1)
        .map(([fingerprint]) => fingerprint)
        .sort((left, right) => left.localeCompare(right));
      const orderingDigest = digestText(
        orderedEntries.map((entry) => `${entry.event.fingerprint}:${entry.signal.id}`).join('\n')
      );
      const multisetKey = buildMultisetKey(preparedEntries);
      const existingOrderingDigest = queueManagedOrderingDigests.get(multisetKey);
      if (!existingOrderingDigest) {
        queueManagedOrderingDigests.set(multisetKey, orderingDigest);
      } else if (existingOrderingDigest !== orderingDigest) {
        const drift = {
          scenario: scenario.id,
          multisetKey,
          expectedOrderingDigest: existingOrderingDigest,
          actualOrderingDigest: orderingDigest
        };
        orderingDrifts.push(drift);
      }

      scenarios.push({
        id: scenario.id,
        description: scenario.description,
        inputSignalOrder: preparedEntries.map((entry) => entry.signal.id),
        replaySignalOrder: orderedEntries.map((entry) => entry.signal.id),
        eventCount: orderedEntries.length,
        uniqueFingerprints: [...new Set(orderedEntries.map((entry) => entry.event.fingerprint))].length,
        multisetKey,
        orderingDigest,
        duplicateCreateFingerprints,
        checks: {
          noDuplicateIssueIntents: duplicateCreateFingerprints.length === 0,
          byteStableDecisions: scenarioDecisionDrifts.length === 0,
          deterministicOrdering: !orderingDrifts.some((drift) => drift.scenario === scenario.id),
          routeExpectationMatch: scenarioRouteMismatches.length === 0
        },
        decisionDrifts: scenarioDecisionDrifts,
        routeMismatches: scenarioRouteMismatches,
        operations,
        decisionSnapshots
      });
    }
  } catch (error) {
    errorMessages = [error.message || String(error)];
  }

  const checks = {
    noDuplicateIssueIntents: scenarios.every((scenario) => scenario.checks.noDuplicateIssueIntents),
    byteStableDecisions: decisionDrifts.length === 0,
    deterministicOrdering: orderingDrifts.length === 0,
    routeExpectationMatch: routeMismatches.length === 0
  };
  const pass =
    errorMessages.length === 0 &&
    checks.noDuplicateIssueIntents &&
    checks.byteStableDecisions &&
    checks.deterministicOrdering;
  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: pass ? 'pass' : options.strict ? 'fail' : 'warn',
    strict: options.strict,
    inputs: {
      catalogPath: resolvedCatalogPath,
      policyPath: resolvedPolicyPath,
      branchPolicyPath: resolvedBranchPolicyPath,
      requiredChecksPath: resolvedRequiredChecksPath,
      reportPath: path.resolve(options.reportPath),
      repository: options.repository
    },
    checks,
    summary: {
      scenarioCount: scenarios.length,
      decisionDriftCount: decisionDrifts.length,
      orderingDriftCount: orderingDrifts.length,
      routeMismatchCount: routeMismatches.length
    },
    scenarios,
    drifts: {
      decision: decisionDrifts,
      ordering: orderingDrifts
    },
    mismatches: {
      route: routeMismatches
    },
    errors: errorMessages
  };

  const reportPath = writeJsonFn(options.reportPath, report);
  const exitCode = pass || !options.strict ? 0 : 1;
  return { exitCode, report, reportPath };
}

export async function main(argv = process.argv) {
  try {
    const result = await runCanaryReplayConformance({ argv });
    if (result.report) {
      console.log(`[canary-replay] report: ${result.reportPath}`);
      console.log(
        `[canary-replay] status=${result.report.status} scenarios=${result.report.summary.scenarioCount} drifts=${result.report.summary.decisionDriftCount + result.report.summary.orderingDriftCount}`
      );
      if (result.report.errors.length > 0) {
        console.error(`[canary-replay] ${result.report.errors.join('; ')}`);
      }
    }
    return result.exitCode;
  } catch (error) {
    console.error(error.message || error);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main().then((exitCode) => {
    process.exit(exitCode);
  });
}
