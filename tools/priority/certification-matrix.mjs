#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'certification-matrix.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'certification',
  'certification-matrix.json'
);

export function printUsage() {
  console.log('Usage: node tools/priority/certification-matrix.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>           Target repository (default: env/remotes).');
  console.log(`  --policy <path>               Policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --output <path>               Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --channel <stable|rc>         Release channel (default: infer from ref/tag).');
  console.log('  --branch <name>               Branch to evaluate (default: policy.target_branch or develop).');
  console.log('  --enforce <none|stable|always> Gate mode (default: stable).');
  console.log('  --lookback-days <n>           Run lookback window (default: policy/defaults or 45).');
  console.log('  --max-runs <n>                Max workflow runs fetched per lane workflow (default: 50).');
  console.log('  -h, --help                    Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    channel: null,
    branch: null,
    enforceMode: 'stable',
    lookbackDays: null,
    maxRuns: 50,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--policy' ||
      token === '--output' ||
      token === '--channel' ||
      token === '--branch' ||
      token === '--enforce'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = next;
      if (token === '--policy') options.policyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--channel') options.channel = next.toLowerCase();
      if (token === '--branch') options.branch = next;
      if (token === '--enforce') options.enforceMode = next.toLowerCase();
      continue;
    }

    if (token === '--lookback-days' || token === '--max-runs') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 1) {
        throw new Error(`Invalid value for ${token}: ${next}`);
      }
      if (token === '--lookback-days') options.lookbackDays = parsed;
      if (token === '--max-runs') options.maxRuns = parsed;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.channel && options.channel !== 'stable' && options.channel !== 'rc') {
    throw new Error(`Invalid --channel value: ${options.channel}. Expected stable or rc.`);
  }
  if (!['none', 'stable', 'always'].includes(options.enforceMode)) {
    throw new Error(`Invalid --enforce value: ${options.enforceMode}. Expected none|stable|always.`);
  }
  return options;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, rawRepo] = repoPath.split('/');
  if (!owner || !rawRepo) return null;
  const repo = rawRepo.endsWith('.git') ? rawRepo.slice(0, -4) : rawRepo;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(explicitRepo) {
  if (explicitRepo) return explicitRepo;
  const envRepo = process.env.GITHUB_REPOSITORY?.trim();
  if (envRepo && envRepo.includes('/')) return envRepo;
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const parsed = parseRemoteUrl(raw);
      if (parsed) return parsed;
    } catch {
      // ignore missing remote
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

export function resolveToken() {
  for (const value of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    if (value && value.trim()) return value.trim();
  }
  for (const candidate of [process.env.GH_TOKEN_FILE, process.platform === 'win32' ? 'C:\\github_token.txt' : null]) {
    if (!candidate || !fs.existsSync(candidate)) continue;
    const value = fs.readFileSync(candidate, 'utf8').trim();
    if (value) return value;
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

export async function requestJson(url, token, method = 'GET') {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-certification-matrix',
      'X-GitHub-Api-Version': '2022-11-28'
    }
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`GitHub API ${method} ${url} failed (${response.status}): ${text}`);
  }
  return payload;
}

function inferChannel(explicitChannel) {
  if (explicitChannel) return explicitChannel;
  const refName = process.env.GITHUB_REF_NAME || process.env.GITHUB_REF || '';
  if (/-rc\./i.test(refName)) return 'rc';
  return 'stable';
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Policy file not found: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function asDateMs(value) {
  const parsed = Date.parse(value || '');
  return Number.isFinite(parsed) ? parsed : null;
}

function round(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function computeAgeHours(referenceMs, observedMs) {
  if (!Number.isFinite(referenceMs) || !Number.isFinite(observedMs) || observedMs > referenceMs) {
    return null;
  }
  return (referenceMs - observedMs) / 3_600_000;
}

export function normalizePolicy(policy, overrides = {}) {
  if (!policy || typeof policy !== 'object') {
    throw new Error('Certification policy is missing or invalid.');
  }
  const lanes = Array.isArray(policy.lanes) ? policy.lanes : [];
  if (lanes.length === 0) {
    throw new Error('Certification policy has no lanes.');
  }

  const defaults = policy.defaults || {};
  const targetBranch = overrides.branch || policy.target_branch || 'develop';
  const lookbackDays = overrides.lookbackDays ?? Number.parseInt(defaults.lookback_days || '45', 10);
  const maxRuns = overrides.maxRuns ?? Number.parseInt(defaults.max_runs || '50', 10);
  const laneDefaultMaxAgeHours = Number.parseInt(defaults.max_age_hours || '1080', 10);

  if (!Number.isFinite(lookbackDays) || lookbackDays < 1) {
    throw new Error(`Invalid lookback_days value: ${defaults.lookback_days}`);
  }
  if (!Number.isFinite(maxRuns) || maxRuns < 1) {
    throw new Error(`Invalid max_runs value: ${defaults.max_runs}`);
  }
  if (!Number.isFinite(laneDefaultMaxAgeHours) || laneDefaultMaxAgeHours < 1) {
    throw new Error(`Invalid max_age_hours value: ${defaults.max_age_hours}`);
  }

  const normalizedLanes = lanes.map((lane, index) => {
    if (!lane || typeof lane !== 'object') {
      throw new Error(`Lane at index ${index} is invalid.`);
    }
    const id = String(lane.id || '').trim();
    const workflow = String(lane.workflow || '').trim();
    const jobName = String(lane.job_name || lane.jobName || '').trim();
    if (!id) throw new Error(`Lane at index ${index} is missing id.`);
    if (!workflow) throw new Error(`Lane '${id}' is missing workflow.`);
    if (!jobName) throw new Error(`Lane '${id}' is missing job_name.`);

    const laneMaxAge = Number.parseInt(lane.max_age_hours ?? laneDefaultMaxAgeHours, 10);
    if (!Number.isFinite(laneMaxAge) || laneMaxAge < 1) {
      throw new Error(`Lane '${id}' has invalid max_age_hours.`);
    }

    let runBranch = targetBranch;
    if (lane.branch != null) {
      const laneBranch = String(lane.branch).trim();
      if (!laneBranch || laneBranch === '*' || laneBranch.toLowerCase() === 'any') {
        runBranch = null;
      } else {
        runBranch = laneBranch;
      }
    }
    const event = lane.event == null ? null : String(lane.event).trim().toLowerCase();

    return {
      id,
      workflow,
      jobName,
      runBranch,
      event,
      maxAgeHours: laneMaxAge,
      requiredForStable: lane.required_for_stable !== false,
      matrix: {
        runner: String(lane.runner || ''),
        os: String(lane.os || ''),
        imageTag: String(lane.image_tag || ''),
        scenario: String(lane.scenario || '')
      }
    };
  });

  return {
    schema: String(policy.schema || ''),
    targetBranch,
    lookbackDays,
    maxRuns,
    lanes: normalizedLanes
  };
}

export function buildWorkflowRunsUrl(repo, workflow, branch, maxRuns) {
  const perPage = Math.max(1, Math.min(maxRuns, 100));
  const query = new URLSearchParams({
    status: 'completed',
    per_page: String(perPage)
  });
  if (branch && String(branch).trim()) {
    query.set('branch', String(branch).trim());
  }
  return `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/runs?${query.toString()}`;
}

async function fetchWorkflowRuns(repo, token, workflow, branch, lookbackDays, maxRuns) {
  const url = buildWorkflowRunsUrl(repo, workflow, branch, maxRuns);
  const payload = await requestJson(url, token, 'GET');
  const runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
  const cutoffMs = Date.now() - lookbackDays * 24 * 3_600_000;
  return runs.filter((run) => {
    const createdMs = asDateMs(run.created_at);
    return Number.isFinite(createdMs) && createdMs >= cutoffMs;
  });
}

async function fetchRunJobs(repo, token, runId) {
  const url = `https://api.github.com/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`;
  const payload = await requestJson(url, token, 'GET');
  return Array.isArray(payload?.jobs) ? payload.jobs : [];
}

async function findLatestLaneObservation(repo, token, lane, context, cache) {
  const workflowCacheKey = `${lane.workflow}::${lane.runBranch || '*'}`;
  if (!cache.workflowRuns.has(workflowCacheKey)) {
    const runs = await fetchWorkflowRuns(
      repo,
      token,
      lane.workflow,
      lane.runBranch,
      context.lookbackDays,
      context.maxRuns
    );
    cache.workflowRuns.set(workflowCacheKey, runs);
  }

  const runs = cache.workflowRuns.get(workflowCacheKey) || [];
  let fallbackObservation = null;
  for (const run of runs) {
    if (lane.event && String(run.event || '').toLowerCase() !== lane.event) {
      continue;
    }
    const runId = run.id;
    if (!cache.runJobs.has(runId)) {
      const jobs = await fetchRunJobs(repo, token, runId);
      cache.runJobs.set(runId, jobs);
    }
    const jobs = cache.runJobs.get(runId) || [];
    const match = jobs.find((job) => String(job?.name || '').trim() === lane.jobName);
    if (!match) continue;
    const conclusion = String(match.conclusion || '').toLowerCase();
    if (!['skipped', 'neutral', ''].includes(conclusion)) {
      return {
        run,
        job: match
      };
    }
    if (!fallbackObservation) {
      fallbackObservation = {
        run,
        job: match
      };
    }
  }
  return fallbackObservation;
}

export function evaluateLane(lane, observation, now = new Date()) {
  const nowMs = now.getTime();
  if (!observation) {
    return {
      ...lane,
      status: 'missing',
      complete: false,
      success: false,
      stale: false,
      ageHours: null,
      reason: 'no-run-with-matching-job',
      latest: null
    };
  }

  const run = observation.run || {};
  const job = observation.job || {};
  const completedAtMs = asDateMs(job.completed_at) ?? asDateMs(run.updated_at) ?? asDateMs(run.created_at);
  const ageHours = computeAgeHours(nowMs, completedAtMs);
  const conclusion = String(job.conclusion || '').toLowerCase();
  const complete = !(conclusion === 'skipped' || conclusion === 'neutral' || !conclusion);
  const success = conclusion === 'success';
  const stale = Number.isFinite(ageHours) && ageHours > lane.maxAgeHours;

  let status = 'pass';
  let reason = 'lane-healthy';
  if (!complete) {
    status = 'incomplete';
    reason = `job-conclusion-${conclusion || 'unknown'}`;
  } else if (stale) {
    status = 'stale';
    reason = `age-hours-${round(ageHours, 2)}-exceeds-${lane.maxAgeHours}`;
  } else if (!success) {
    status = 'failed';
    reason = `job-conclusion-${conclusion || 'unknown'}`;
  }

  return {
    ...lane,
    status,
    complete,
    success,
    stale,
    ageHours: round(ageHours, 4),
    reason,
    latest: {
      workflowRunId: run.id ?? null,
      workflowRunNumber: run.run_number ?? null,
      workflowRunAttempt: run.run_attempt ?? null,
      workflowRunUrl: run.html_url ?? null,
      workflowEvent: run.event ?? null,
      workflowCreatedAt: run.created_at ?? null,
      workflowUpdatedAt: run.updated_at ?? null,
      workflowHeadSha: run.head_sha ?? null,
      jobId: job.id ?? null,
      jobName: job.name ?? null,
      jobConclusion: conclusion || null,
      jobStartedAt: job.started_at ?? null,
      jobCompletedAt: job.completed_at ?? null,
      jobUrl: job.html_url ?? null
    }
  };
}

export function evaluateGate(lanes, channel, enforceMode) {
  const considered = lanes.filter((lane) => lane.requiredForStable);
  const blocking = considered.filter((lane) => lane.status !== 'pass');
  const enforced = enforceMode === 'always' || (enforceMode === 'stable' && channel === 'stable');
  const shouldFail = enforced && blocking.length > 0;
  const status = shouldFail ? 'fail' : blocking.length > 0 ? 'warn' : 'pass';
  let reason = 'all-required-lanes-pass';
  if (blocking.length > 0 && !enforced) {
    reason = 'lane-failures-observed-but-not-enforced-for-channel';
  } else if (blocking.length > 0) {
    reason = 'required-lane-failure-or-stale-or-incomplete';
  }

  return {
    enforced,
    mode: enforceMode,
    status,
    shouldFail,
    blockingLaneIds: blocking.map((lane) => lane.id),
    reason
  };
}

function countByStatus(lanes, status) {
  return lanes.filter((lane) => lane.status === status).length;
}

export function buildCertificationReport({
  repository,
  branch,
  channel,
  enforceMode,
  policyPath,
  policySha256,
  lanes,
  generatedAt = new Date()
}) {
  const gate = evaluateGate(lanes, channel, enforceMode);
  const required = lanes.filter((lane) => lane.requiredForStable);
  const requiredPassing = required.filter((lane) => lane.status === 'pass').length;

  return {
    schema: 'priority/certification-matrix@v1',
    generatedAt: generatedAt.toISOString(),
    repository,
    branch,
    channel,
    policy: {
      path: policyPath,
      sha256: policySha256
    },
    summary: {
      laneCount: lanes.length,
      requiredLaneCount: required.length,
      requiredPassing,
      passCount: countByStatus(lanes, 'pass'),
      staleCount: countByStatus(lanes, 'stale'),
      missingCount: countByStatus(lanes, 'missing'),
      incompleteCount: countByStatus(lanes, 'incomplete'),
      failedCount: countByStatus(lanes, 'failed'),
      status: gate.status
    },
    gate,
    lanes
  };
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function hashFile(filePath) {
  const data = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(data).digest('hex');
}

function appendSummary(report, outputPath) {
  const stepSummary = process.env.GITHUB_STEP_SUMMARY;
  if (!stepSummary) return;
  const lines = [
    '### Certification Matrix',
    `- Repository: \`${report.repository}\``,
    `- Branch: \`${report.branch}\``,
    `- Channel: \`${report.channel}\``,
    `- Gate mode: \`${report.gate.mode}\``,
    `- Gate enforced: \`${report.gate.enforced}\``,
    `- Gate status: \`${report.gate.status}\``,
    `- Blocking lanes: \`${report.gate.blockingLaneIds.join(', ') || 'none'}\``,
    `- Artifact: \`${outputPath}\``,
    '',
    '| Lane | Status | Age (hours) | Job conclusion |',
    '| --- | --- | ---: | --- |'
  ];
  for (const lane of report.lanes) {
    lines.push(
      `| \`${lane.id}\` | \`${lane.status}\` | \`${lane.ageHours ?? 'n/a'}\` | \`${lane.latest?.jobConclusion || 'n/a'}\` |`
    );
  }
  fs.appendFileSync(stepSummary, `${lines.join('\n')}\n`, 'utf8');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const repository = resolveRepositorySlug(options.repo);
  const channel = inferChannel(options.channel);
  const policyPath = path.resolve(options.policyPath);
  const policyRaw = readJson(policyPath);
  const policy = normalizePolicy(policyRaw, {
    branch: options.branch,
    lookbackDays: options.lookbackDays,
    maxRuns: options.maxRuns
  });

  const token = resolveToken();
  const now = new Date();
  const cache = {
    workflowRuns: new Map(),
    runJobs: new Map()
  };

  const laneResults = [];
  for (const lane of [...policy.lanes].sort((a, b) => a.id.localeCompare(b.id))) {
    const observation = await findLatestLaneObservation(
      repository,
      token,
      lane,
      {
        branch: policy.targetBranch,
        lookbackDays: policy.lookbackDays,
        maxRuns: policy.maxRuns
      },
      cache
    );
    laneResults.push(evaluateLane(lane, observation, now));
  }

  const report = buildCertificationReport({
    repository,
    branch: policy.targetBranch,
    channel,
    enforceMode: options.enforceMode,
    policyPath: path.relative(process.cwd(), policyPath).replace(/\\/g, '/'),
    policySha256: hashFile(policyPath),
    lanes: laneResults,
    generatedAt: now
  });

  const outputPath = writeJson(options.outputPath, report);
  appendSummary(report, options.outputPath);
  console.log(
    `[certification-matrix] wrote ${outputPath} (status=${report.summary.status}, blocking=${report.gate.blockingLaneIds.length})`
  );
  return report.gate.shouldFail ? 1 : 0;
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
