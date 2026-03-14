#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { resolveRepoGitState } from './copilot-cli-review.mjs';

export const SIMULATION_REVIEW_SCHEMA = 'priority/simulation-review@v1';
export const DEFAULT_SIMULATION_REVIEW_POLICY = {
  enabled: false,
  scenario: 'clean-pass',
  receiptPath: path.join('tests', 'results', 'docker-tools-parity', 'simulation-review', 'receipt.json'),
  summary: '',
  findings: []
};

const SUPPORTED_SCENARIOS = new Set([
  'clean-pass',
  'actionable-findings',
  'provider-failure',
  'stale-head',
  'dirty-tracked'
]);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function toIso(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function normalizeSeverity(value) {
  const normalized = normalizeText(value).toLowerCase();
  return ['error', 'warning', 'note'].includes(normalized) ? normalized : 'warning';
}

function normalizeFinding(value) {
  const finding = value && typeof value === 'object' ? value : {};
  const line = Number(finding.line);
  return {
    severity: normalizeSeverity(finding.severity),
    path: normalizeText(finding.path) || null,
    line: Number.isInteger(line) && line > 0 ? line : null,
    title: normalizeText(finding.title) || 'Simulation finding',
    body: normalizeText(finding.body) || '',
    actionable: finding.actionable !== false
  };
}

function normalizeFindings(value) {
  return Array.isArray(value) ? value.map(normalizeFinding) : [];
}

function resolveRepoPath(repoRoot, candidatePath) {
  const normalized = normalizeText(candidatePath);
  if (!normalized) {
    throw new Error('Simulation review receipt path must be a non-empty repo-relative path.');
  }
  if (path.isAbsolute(normalized)) {
    throw new Error(`Simulation review receipt path must stay under the repository root: ${normalized}`);
  }
  const resolved = path.resolve(repoRoot, normalized);
  const relativeToRepo = path.relative(repoRoot, resolved);
  if (!relativeToRepo || relativeToRepo.startsWith('..') || path.isAbsolute(relativeToRepo)) {
    throw new Error(`Simulation review receipt path escapes the repository root: ${normalized}`);
  }
  return {
    normalized,
    resolved
  };
}

function buildDefaultScenarioFindings(scenario) {
  if (scenario !== 'actionable-findings') {
    return [];
  }
  return [
    {
      severity: 'warning',
      path: 'tools/priority/delivery-agent.mjs',
      line: 1,
      title: 'Simulated seam finding',
      body: 'The Simulation provider intentionally emitted an actionable finding for seam coverage.',
      actionable: true
    }
  ];
}

export function normalizeSimulationReviewPolicy(value) {
  const raw = value && typeof value === 'object' ? value : {};
  const scenario = normalizeText(raw.scenario).toLowerCase();
  return {
    ...DEFAULT_SIMULATION_REVIEW_POLICY,
    ...raw,
    enabled: raw.enabled === true,
    scenario: SUPPORTED_SCENARIOS.has(scenario) ? scenario : DEFAULT_SIMULATION_REVIEW_POLICY.scenario,
    receiptPath: normalizeText(raw.receiptPath) || DEFAULT_SIMULATION_REVIEW_POLICY.receiptPath,
    summary: normalizeText(raw.summary),
    findings: normalizeFindings(raw.findings)
  };
}

export async function runSimulationReview({
  repoRoot,
  policy = null,
  resolveRepoGitStateFn = resolveRepoGitState
}) {
  const normalizedPolicy = normalizeSimulationReviewPolicy(policy);
  const receiptPathInfo = resolveRepoPath(repoRoot, normalizedPolicy.receiptPath);
  const repoGitState = resolveRepoGitStateFn(repoRoot) ?? {};
  const receiptGit = {
    headSha: normalizeText(repoGitState.headSha) || null,
    branch: normalizeText(repoGitState.branch) || null,
    upstreamDevelopMergeBase: normalizeText(repoGitState.upstreamDevelopMergeBase) || null,
    dirtyTracked: repoGitState.dirtyTracked === true
  };

  let status = 'passed';
  let summary = normalizedPolicy.summary || 'Simulation review passed cleanly.';
  let findings = normalizedPolicy.findings.length > 0 ? [...normalizedPolicy.findings] : buildDefaultScenarioFindings(normalizedPolicy.scenario);

  if (normalizedPolicy.scenario === 'actionable-findings') {
    status = 'failed';
    summary = normalizedPolicy.summary || 'Simulation review produced actionable findings.';
  } else if (normalizedPolicy.scenario === 'provider-failure') {
    status = 'failed';
    summary = normalizedPolicy.summary || 'Simulation review provider failed intentionally.';
  } else if (normalizedPolicy.scenario === 'stale-head') {
    status = 'failed';
    summary = normalizedPolicy.summary || 'Simulation review produced a stale-head receipt intentionally.';
    receiptGit.headSha = receiptGit.headSha ? `${receiptGit.headSha}-stale` : 'stale-head';
  } else if (normalizedPolicy.scenario === 'dirty-tracked') {
    status = 'failed';
    summary = normalizedPolicy.summary || 'Simulation review marked the tracked tree dirty intentionally.';
    receiptGit.dirtyTracked = true;
  } else {
    findings = [];
  }

  const actionableFindingCount = findings.filter((finding) => finding.actionable !== false).length;
  const receipt = {
    schema: SIMULATION_REVIEW_SCHEMA,
    generatedAt: toIso(),
    provider: 'simulation',
    scenario: normalizedPolicy.scenario,
    git: receiptGit,
    overall: {
      status,
      actionableFindingCount,
      message: summary,
      exitCode: status === 'passed' ? 0 : 1
    },
    findings,
    recommendedReviewOrder: ['simulationReview']
  };

  await mkdir(path.dirname(receiptPathInfo.resolved), { recursive: true });
  await writeFile(receiptPathInfo.resolved, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');

  return {
    providerId: 'simulation',
    status,
    source: 'simulation-review',
    reason: summary,
    receiptPath: receiptPathInfo.normalized,
    receipt
  };
}
