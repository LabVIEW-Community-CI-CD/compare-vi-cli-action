#!/usr/bin/env node

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'release/release-conductor-report@v1';
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'release', 'release-conductor-report.json');
export const DEFAULT_QUEUE_REPORT_PATH = path.join('tests', 'results', '_agent', 'queue', 'queue-supervisor-report.json');
export const DEFAULT_POLICY_SNAPSHOT_PATH = path.join('tests', 'results', '_agent', 'policy', 'policy-state-snapshot.json');
export const DEFAULT_DWELL_MINUTES = 60;
export const DEFAULT_QUARANTINE_STALE_HOURS = 24;

const REQUIRED_DWELL_WORKFLOWS = Object.freeze([
  { name: 'Validate', file: 'validate.yml' },
  { name: 'Policy Guard (Upstream)', file: 'policy-guard-upstream.yml' }
]);

function printUsage() {
  console.log('Usage: node tools/priority/release-conductor.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --apply                     Apply release mutation (default is --dry-run).');
  console.log('  --repair-existing-tag       Repair an existing authoritative tag by recreating it as a signed annotated tag.');
  console.log(`  --report <path>             Write report JSON (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --queue-report <path>       Queue supervisor report path (default: ${DEFAULT_QUEUE_REPORT_PATH}).`);
  console.log(`  --policy-snapshot <path>    Policy snapshot path (default: ${DEFAULT_POLICY_SNAPSHOT_PATH}).`);
  console.log('  --repo <owner/repo>         Target repository (default: GITHUB_REPOSITORY/upstream/origin remote).');
  console.log('  --stream <name>             Release stream name (default: comparevi-cli).');
  console.log('  --channel <stable|rc>       Release channel (default: stable).');
  console.log('  --version <semver>          Proposed version used for release tag proposal (optional).');
  console.log(`  --dwell-minutes <n>         Required green dwell window in minutes (default: ${DEFAULT_DWELL_MINUTES}).`);
  console.log(`  --quarantine-stale-hours <n> Fail when queue quarantine is stale beyond N hours (default: ${DEFAULT_QUARANTINE_STALE_HOURS}).`);
  console.log('  --dry-run                   Force dry-run mode.');
  console.log('  -h, --help                  Show this help text and exit.');
}

function parseIntStrict(value, { label }) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return parsed;
}

function asOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

export function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = asOptional(explicitRepo);
  if (explicit && explicit.includes('/')) {
    return explicit;
  }
  const envRepo = asOptional(environment.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }

  for (const remoteName of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) {
      continue;
    }
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) {
      return parsed;
    }
  }

  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    apply: false,
    dryRun: true,
    repairExistingTag: false,
    reportPath: DEFAULT_REPORT_PATH,
    queueReportPath: DEFAULT_QUEUE_REPORT_PATH,
    policySnapshotPath: DEFAULT_POLICY_SNAPSHOT_PATH,
    repo: null,
    stream: 'comparevi-cli',
    channel: 'stable',
    version: null,
    dwellMinutes: DEFAULT_DWELL_MINUTES,
    quarantineStaleHours: DEFAULT_QUARANTINE_STALE_HOURS,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--apply') {
      options.apply = true;
      options.dryRun = false;
      continue;
    }
    if (token === '--repair-existing-tag') {
      options.repairExistingTag = true;
      continue;
    }
    if (token === '--dry-run') {
      options.apply = false;
      options.dryRun = true;
      continue;
    }

    if (
      token === '--report' ||
      token === '--queue-report' ||
      token === '--policy-snapshot' ||
      token === '--repo' ||
      token === '--stream' ||
      token === '--channel' ||
      token === '--version' ||
      token === '--dwell-minutes' ||
      token === '--quarantine-stale-hours'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--report') options.reportPath = next;
      if (token === '--queue-report') options.queueReportPath = next;
      if (token === '--policy-snapshot') options.policySnapshotPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--stream') options.stream = next;
      if (token === '--channel') options.channel = next.trim().toLowerCase();
      if (token === '--version') options.version = next;
      if (token === '--dwell-minutes') options.dwellMinutes = parseIntStrict(next, { label: '--dwell-minutes' });
      if (token === '--quarantine-stale-hours') {
        options.quarantineStaleHours = parseIntStrict(next, { label: '--quarantine-stale-hours' });
      }
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!['stable', 'rc'].includes(options.channel)) {
    throw new Error(`Invalid --channel '${options.channel}'. Expected stable or rc.`);
  }

  return options;
}

function runCommand(command, args, { cwd, allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0 && !allowFailure) {
    const stderr = result.stderr?.trim();
    throw new Error(`${command} ${args.join(' ')} failed (${result.status})${stderr ? `: ${stderr}` : ''}`);
  }
  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
}

function runGhJson(args, { cwd } = {}) {
  const result = runCommand('gh', args, { cwd, allowFailure: true });
  if (result.status !== 0) {
    const message = result.stderr?.trim() || result.stdout?.trim() || `gh ${args.join(' ')} failed (${result.status})`;
    throw new Error(message);
  }
  const raw = (result.stdout ?? '').trim();
  return raw ? JSON.parse(raw) : null;
}

async function readJsonOptional(filePath) {
  const resolved = path.resolve(filePath);
  if (!existsSync(resolved)) {
    return {
      exists: false,
      path: resolved,
      payload: null,
      error: null
    };
  }

  try {
    const raw = await readFile(resolved, 'utf8');
    return {
      exists: true,
      path: resolved,
      payload: JSON.parse(raw),
      error: null
    };
  } catch (error) {
    return {
      exists: true,
      path: resolved,
      payload: null,
      error: error?.message ?? String(error)
    };
  }
}

function normalizeUpdatedAt(entry) {
  const updatedAt = new Date(entry?.updated_at ?? entry?.updatedAt ?? 0);
  return Number.isNaN(updatedAt.valueOf()) ? null : updatedAt;
}

function normalizeConclusion(entry) {
  return String(entry?.conclusion ?? '').trim().toLowerCase();
}

export function evaluateGreenDwell({
  workflowRunsByName = {},
  now = new Date(),
  dwellMinutes = DEFAULT_DWELL_MINUTES
} = {}) {
  const dwellStartMs = now.valueOf() - dwellMinutes * 60 * 1000;
  const failureConclusions = new Set(['failure', 'cancelled', 'timed_out', 'action_required', 'startup_failure']);
  const details = [];
  const reasons = [];

  for (const spec of REQUIRED_DWELL_WORKFLOWS) {
    const runs = Array.isArray(workflowRunsByName[spec.name]) ? workflowRunsByName[spec.name] : [];
    const inWindow = runs.filter((entry) => {
      const updatedAt = normalizeUpdatedAt(entry);
      return updatedAt && updatedAt.valueOf() >= dwellStartMs;
    });
    const successInWindow = inWindow.some((entry) => normalizeConclusion(entry) === 'success');
    const failureInWindow = inWindow.some((entry) => failureConclusions.has(normalizeConclusion(entry)));
    const latestSuccess = runs
      .filter((entry) => normalizeConclusion(entry) === 'success')
      .map((entry) => normalizeUpdatedAt(entry)?.toISOString() ?? null)
      .find(Boolean);

    const status = successInWindow && !failureInWindow ? 'pass' : 'fail';
    if (!successInWindow) {
      reasons.push(`no-success-${spec.file}`);
    }
    if (failureInWindow) {
      reasons.push(`failure-in-window-${spec.file}`);
    }

    details.push({
      name: spec.name,
      file: spec.file,
      runCount: runs.length,
      inWindowCount: inWindow.length,
      successInWindow,
      failureInWindow,
      latestSuccessAt: latestSuccess
    });
  }

  return {
    status: reasons.length === 0 ? 'pass' : 'fail',
    dwellMinutes,
    evaluatedAt: now.toISOString(),
    reasons: [...new Set(reasons)],
    workflows: details
  };
}

export function evaluateQueueHealthGate(queueReportEnvelope) {
  if (!queueReportEnvelope.exists || queueReportEnvelope.error || !queueReportEnvelope.payload) {
    return {
      status: 'fail',
      reasons: ['queue-report-unavailable'],
      paused: null,
      controllerMode: null
    };
  }

  const queueReport = queueReportEnvelope.payload;
  const paused = Boolean(queueReport?.paused);
  const controllerMode =
    queueReport?.throughputController?.mode ??
    queueReport?.adaptiveInflight?.mode ??
    null;

  const reasons = [];
  if (paused) reasons.push('queue-paused');
  if (controllerMode === 'stabilize') reasons.push('queue-stabilize-mode');

  return {
    status: reasons.length === 0 ? 'pass' : 'fail',
    reasons,
    paused,
    controllerMode
  };
}

export function evaluatePolicySnapshotGate(policySnapshotEnvelope) {
  if (!policySnapshotEnvelope.exists || policySnapshotEnvelope.error || !policySnapshotEnvelope.payload) {
    return {
      status: 'fail',
      reasons: ['policy-snapshot-unavailable'],
      schema: null,
      generatedAt: null
    };
  }

  const payload = policySnapshotEnvelope.payload;
  const reasons = [];
  if (payload?.schema !== 'priority/policy-live-state@v1') {
    reasons.push('policy-snapshot-schema-mismatch');
  }
  const generatedAt = payload?.generatedAt;
  if (!generatedAt || Number.isNaN(Date.parse(generatedAt))) {
    reasons.push('policy-snapshot-generated-at-invalid');
  }
  if (!payload?.state || typeof payload.state !== 'object') {
    reasons.push('policy-snapshot-state-missing');
  }

  return {
    status: reasons.length === 0 ? 'pass' : 'fail',
    reasons,
    schema: payload?.schema ?? null,
    generatedAt: generatedAt ?? null
  };
}

export function evaluateQuarantineGate({
  queueReportEnvelope,
  now = new Date(),
  staleHours = DEFAULT_QUARANTINE_STALE_HOURS
} = {}) {
  if (!queueReportEnvelope.exists || queueReportEnvelope.error || !queueReportEnvelope.payload) {
    return {
      status: 'fail',
      reasons: ['queue-report-unavailable'],
      staleHours,
      staleCount: null,
      activeCount: null,
      staleEntries: []
    };
  }

  const retryHistory =
    queueReportEnvelope.payload?.retryHistory && typeof queueReportEnvelope.payload.retryHistory === 'object'
      ? queueReportEnvelope.payload.retryHistory
      : {};

  const staleCutoffMs = now.valueOf() - staleHours * 60 * 60 * 1000;
  const staleEntries = [];
  let activeCount = 0;

  for (const [number, entry] of Object.entries(retryHistory)) {
    const failures = Array.isArray(entry?.failures) ? entry.failures : [];
    if (failures.length < 2) {
      continue;
    }
    activeCount += 1;
    const latestFailure = failures
      .map((value) => Date.parse(value))
      .filter((value) => Number.isFinite(value))
      .sort((a, b) => b - a)[0];

    if (!Number.isFinite(latestFailure) || latestFailure <= staleCutoffMs) {
      staleEntries.push({
        number: Number(number),
        latestFailureAt: Number.isFinite(latestFailure) ? new Date(latestFailure).toISOString() : null,
        failureCount: failures.length
      });
    }
  }

  const reasons = staleEntries.length > 0 ? ['stale-quarantine-present'] : [];
  return {
    status: reasons.length === 0 ? 'pass' : 'fail',
    reasons,
    staleHours,
    staleCount: staleEntries.length,
    activeCount,
    staleEntries: staleEntries.sort((left, right) => left.number - right.number)
  };
}

function isQueueReportUnavailableGate(gate) {
  if (gate?.status !== 'fail') {
    return false;
  }
  const reasons = Array.isArray(gate?.reasons) ? gate.reasons : [];
  return reasons.length > 0 && reasons.every((reason) => reason === 'queue-report-unavailable');
}

function isDryRunGreenDwellAdvisory(gate) {
  if (gate?.status !== 'fail') {
    return false;
  }
  const reasons = Array.isArray(gate?.reasons) ? gate.reasons : [];
  return reasons.length > 0 && reasons.every((reason) => reason.startsWith('no-success-'));
}

function pushUniqueDecisionEntry(entries, entry) {
  if (!entries.some((candidate) => candidate.code === entry.code)) {
    entries.push(entry);
  }
}

function fetchWorkflowRunsByName({ runGhJsonFn, repository, branch, sampleSize, cwd }) {
  const workflowRunsByName = {};
  const fetchErrors = [];

  for (const workflow of REQUIRED_DWELL_WORKFLOWS) {
    const endpoint = `repos/${repository}/actions/workflows/${workflow.file}/runs?branch=${encodeURIComponent(branch)}&per_page=${sampleSize}`;
    try {
      const response = runGhJsonFn(['api', endpoint], { cwd }) ?? {};
      workflowRunsByName[workflow.name] = Array.isArray(response.workflow_runs) ? response.workflow_runs : [];
    } catch (error) {
      workflowRunsByName[workflow.name] = [];
      fetchErrors.push({
        workflow: workflow.name,
        file: workflow.file,
        message: error?.message ?? String(error)
      });
    }
  }

  return {
    workflowRunsByName,
    fetchErrors
  };
}

function detectSigningMaterial({ runCommandFn, repoRoot, environment = process.env }) {
  const keyResult = runCommandFn('git', ['config', '--get', 'user.signingkey'], {
    cwd: repoRoot,
    allowFailure: true
  });
  const signingKey = asOptional(keyResult.stdout);
  const formatResult = runCommandFn('git', ['config', '--get', 'gpg.format'], {
    cwd: repoRoot,
    allowFailure: true
  });
  const configuredFormat = asOptional(formatResult.stdout);
  const backend = asOptional(environment.RELEASE_TAG_SIGNING_BACKEND) ?? configuredFormat ?? 'openpgp';
  const source = signingKey ? asOptional(environment.RELEASE_TAG_SIGNING_SOURCE) ?? 'git-config' : 'missing';

  return {
    available: Boolean(signingKey),
    signingKey,
    source,
    backend
  };
}

function resolveTargetTag(version) {
  const normalized = asOptional(version);
  if (!normalized) return null;
  return normalized.startsWith('v') ? normalized : `v${normalized}`;
}

function inspectLocalTag({ repoRoot, tagRef, runCommandFn }) {
  if (!tagRef) {
    return {
      present: false,
      objectOid: null
    };
  }

  const result = runCommandFn('git', ['rev-parse', '--verify', '--quiet', `refs/tags/${tagRef}`], {
    cwd: repoRoot,
    allowFailure: true
  });
  return {
    present: result.status === 0,
    objectOid: asOptional(result.stdout)
  };
}

function inspectRemoteTag({ repoRoot, remoteName, tagRef, runCommandFn }) {
  if (!remoteName || !tagRef) {
    return {
      exists: false,
      refName: tagRef ? `refs/tags/${tagRef}` : null,
      objectOid: null,
      targetCommitOid: null,
      annotated: null,
      lookupError: null
    };
  }

  const refName = `refs/tags/${tagRef}`;
  const result = runCommandFn('git', ['ls-remote', '--tags', remoteName, refName, `${refName}^{}`], {
    cwd: repoRoot,
    allowFailure: true
  });
  if (result.status !== 0) {
    return {
      exists: false,
      refName,
      objectOid: null,
      targetCommitOid: null,
      annotated: null,
      lookupError: asOptional(result.stderr) ?? asOptional(result.stdout) ?? `git ls-remote failed (${result.status})`
    };
  }

  let objectOid = null;
  let peeledOid = null;
  for (const rawLine of String(result.stdout ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }
    const [oid, resolvedRef] = line.split(/\s+/, 2);
    if (resolvedRef === refName) {
      objectOid = oid;
    } else if (resolvedRef === `${refName}^{}`) {
      peeledOid = oid;
    }
  }

  const exists = Boolean(objectOid);
  return {
    exists,
    refName,
    objectOid,
    targetCommitOid: peeledOid ?? objectOid,
    annotated: exists ? Boolean(peeledOid) : null,
    lookupError: null
  };
}

function createRepairState({ requested, remoteTag = null, localTag = null }) {
  return {
    requested: Boolean(requested),
    status: 'not-requested',
    remoteTagRef: remoteTag?.refName ?? null,
    remoteTagExists: Boolean(remoteTag?.exists),
    remoteTagAnnotated: remoteTag?.annotated ?? null,
    remoteTagObjectOid: remoteTag?.objectOid ?? null,
    remoteTargetCommitOid: remoteTag?.targetCommitOid ?? null,
    localTagPresent: Boolean(localTag?.present),
    localTagDeleted: false,
    tagRecreated: false,
    pushLeaseExpectedOid: remoteTag?.objectOid ?? null,
    lookupError: remoteTag?.lookupError ?? null
  };
}

function resolveTagPushRemote({ repoRoot, repository, runCommandFn }) {
  for (const remoteName of ['upstream', 'origin']) {
    const remoteResult = runCommandFn('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      allowFailure: true
    });
    const remoteUrl = asOptional(remoteResult.stdout);
    const remoteSlug = parseRemoteUrl(remoteUrl);
    if (remoteSlug && remoteSlug === repository) {
      return {
        remoteName,
        remoteSlug,
        source: 'matching-remote-url'
      };
    }
  }

  return {
    remoteName: null,
    remoteSlug: null,
    source: 'missing'
  };
}

async function writeReport(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runReleaseConductor(options = {}) {
  const repoRoot = options.repoRoot ?? process.cwd();
  const now = options.now ?? new Date();
  const args = options.args ?? parseArgs();
  const runGhJsonFn = options.runGhJsonFn ?? runGhJson;
  const runCommandFn = options.runCommandFn ?? runCommand;
  const readJsonOptionalFn = options.readJsonOptionalFn ?? readJsonOptional;
  const writeReportFn = options.writeReportFn ?? writeReport;
  const environment = options.environment ?? process.env;

  const repository = resolveRepositorySlug(repoRoot, args.repo, environment);
  const queueReportEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.queueReportPath));
  const policySnapshotEnvelope = await readJsonOptionalFn(path.resolve(repoRoot, args.policySnapshotPath));
  const { workflowRunsByName, fetchErrors } = fetchWorkflowRunsByName({
    runGhJsonFn,
    repository,
    branch: 'develop',
    sampleSize: 20,
    cwd: repoRoot
  });

  const greenDwellGate = evaluateGreenDwell({
    workflowRunsByName,
    now,
    dwellMinutes: args.dwellMinutes
  });
  const queueHealthGate = evaluateQueueHealthGate(queueReportEnvelope);
  const policySnapshotGate = evaluatePolicySnapshotGate(policySnapshotEnvelope);
  const quarantineGate = evaluateQuarantineGate({
    queueReportEnvelope,
    now,
    staleHours: args.quarantineStaleHours
  });

  const applyRequested = Boolean(args.apply && !args.dryRun);
  const blockers = [];
  const advisories = [];
  if (fetchErrors.length > 0) {
    blockers.push({
      code: 'workflow-fetch-failed',
      message: 'Unable to fetch required workflow run history for dwell gate.'
    });
  }
  if (greenDwellGate.status !== 'pass') {
    if (!applyRequested && isDryRunGreenDwellAdvisory(greenDwellGate)) {
      pushUniqueDecisionEntry(advisories, {
        code: 'green-dwell-no-recent-success',
        message: `No successful required workflow run was observed in the last ${args.dwellMinutes} minutes; dry-run remains proposal-only.`
      });
    } else {
      blockers.push({
        code: 'green-dwell-failed',
        message: `Required workflows were not continuously green for ${args.dwellMinutes} minutes.`
      });
    }
  }
  if (queueHealthGate.status !== 'pass') {
    if (!applyRequested && isQueueReportUnavailableGate(queueHealthGate)) {
      pushUniqueDecisionEntry(advisories, {
        code: 'queue-report-unavailable-dry-run',
        message: 'Queue supervisor evidence is unavailable; queue health and quarantine checks remain advisory while release conductor stays proposal-only.'
      });
    } else {
      blockers.push({
        code: 'queue-health-failed',
        message: 'Queue supervisor reported paused/stabilize state.'
      });
    }
  }
  if (policySnapshotGate.status !== 'pass') {
    blockers.push({
      code: 'policy-snapshot-failed',
      message: 'Policy snapshot artifact is missing or invalid.'
    });
  }
  if (quarantineGate.status !== 'pass') {
    if (!applyRequested && isQueueReportUnavailableGate(quarantineGate)) {
      pushUniqueDecisionEntry(advisories, {
        code: 'queue-report-unavailable-dry-run',
        message: 'Queue supervisor evidence is unavailable; queue health and quarantine checks remain advisory while release conductor stays proposal-only.'
      });
    } else {
      blockers.push({
        code: 'stale-quarantine-failed',
        message: 'Queue quarantine has stale entries that require manual remediation.'
      });
    }
  }

  const conductorEnabled = String(environment.RELEASE_CONDUCTOR_ENABLED ?? '').trim() === '1';
  if (applyRequested && !conductorEnabled) {
    blockers.push({
      code: 'apply-disabled',
      message: 'Apply mode requested but RELEASE_CONDUCTOR_ENABLED is not set to 1.'
    });
  }

  const signingMaterial = detectSigningMaterial({ runCommandFn, repoRoot, environment });
  const targetTag = resolveTargetTag(args.version);
  let tagCreated = false;
  let tagPushed = false;
  let tagError = null;
  let tagPushError = null;
  let proposalOnly = true;
  const tagPushRemote = resolveTagPushRemote({ repoRoot, repository, runCommandFn });
  const remoteTag = inspectRemoteTag({
    repoRoot,
    remoteName: asOptional(tagPushRemote.remoteName),
    tagRef: targetTag,
    runCommandFn
  });
  const localTag = inspectLocalTag({
    repoRoot,
    tagRef: targetTag,
    runCommandFn
  });
  const repair = createRepairState({
    requested: args.repairExistingTag,
    remoteTag,
    localTag
  });

  if (repair.remoteTagExists && !repair.requested) {
    repair.status = 'repair-available';
    pushUniqueDecisionEntry(advisories, {
      code: 'existing-tag-repair-available',
      message: `Authoritative tag ${targetTag} already exists; rerun release conductor with --repair-existing-tag to recreate it as a signed annotated tag.`
    });
  }
  if (repair.requested && !targetTag) {
    repair.status = 'blocked';
  } else if (repair.requested && remoteTag.lookupError) {
    repair.status = 'blocked';
  } else if (repair.requested && !asOptional(tagPushRemote.remoteName)) {
    repair.status = 'blocked';
  } else if (repair.requested && !repair.remoteTagExists) {
    repair.status = 'blocked';
  } else if (repair.requested && (!repair.remoteTargetCommitOid || !repair.pushLeaseExpectedOid)) {
    repair.status = 'blocked';
  } else if (repair.requested && repair.remoteTagExists) {
    repair.status = applyRequested ? 'blocked' : 'ready';
  }

  if (repair.requested) {
    if (!targetTag) {
      blockers.push({
        code: 'missing-version-for-tag',
        message: 'Repair mode requires --version to identify the authoritative release tag.'
      });
    } else if (!asOptional(tagPushRemote.remoteName)) {
      blockers.push({
        code: 'tag-push-remote-missing',
        message: `Repair mode could not resolve an authoritative push remote matching ${repository}.`
      });
    } else if (remoteTag.lookupError) {
      blockers.push({
        code: 'repair-remote-tag-lookup-failed',
        message: `Unable to inspect authoritative tag ${targetTag}: ${remoteTag.lookupError}`
      });
    } else if (!repair.remoteTagExists) {
      blockers.push({
        code: 'repair-target-tag-missing',
        message: `Repair mode requires existing authoritative tag ${targetTag}, but no authoritative tag ref was found on ${tagPushRemote.remoteName}.`
      });
    } else if (!repair.remoteTargetCommitOid || !repair.pushLeaseExpectedOid) {
      blockers.push({
        code: 'repair-target-unresolved',
        message: `Repair mode could not resolve the authoritative object/commit for ${targetTag}.`
      });
    }
  }

  if (blockers.length === 0 && applyRequested && conductorEnabled) {
    if (!targetTag) {
      blockers.push({
        code: 'missing-version-for-tag',
        message: 'Apply mode requires --version to propose/create a release tag.'
      });
    } else if (!signingMaterial.available) {
      blockers.push({
        code: 'tag-signing-material-missing',
        message: 'Apply mode requires signed-tag readiness before tag push. Configure user.signingkey (or equivalent signing material) and retry.'
      });
    } else if (args.repairExistingTag) {
        if (repair.localTagPresent) {
          const deleteResult = runCommandFn('git', ['tag', '-d', targetTag], {
            cwd: repoRoot,
            allowFailure: true
          });
          if (deleteResult.status !== 0) {
            tagError = asOptional(deleteResult.stderr) ?? asOptional(deleteResult.stdout) ?? 'local tag delete failed';
            blockers.push({
              code: 'repair-local-tag-delete-failed',
              message: `Unable to remove existing local tag ${targetTag} before repair: ${tagError}`
            });
          } else {
            repair.localTagDeleted = true;
          }
        }

        if (blockers.length === 0) {
          const tagResult = runCommandFn(
            'git',
            ['tag', '-s', '-f', targetTag, repair.remoteTargetCommitOid, '-m', `Release ${targetTag}`],
            {
              cwd: repoRoot,
              allowFailure: true
            }
          );
          if (tagResult.status === 0) {
            tagCreated = true;
            repair.tagRecreated = true;
            const pushRemoteName = asOptional(tagPushRemote.remoteName);
            if (!pushRemoteName) {
              tagPushError = 'Unable to resolve an authoritative git remote for repair publication.';
              blockers.push({
                code: 'tag-push-remote-missing',
                message: `Signed repair tag ${targetTag} was created locally but no authoritative push remote matched ${repository}.`
              });
            } else {
              const leaseArg = `--force-with-lease=refs/tags/${targetTag}:${repair.pushLeaseExpectedOid}`;
              const pushResult = runCommandFn(
                'git',
                ['push', leaseArg, pushRemoteName, `refs/tags/${targetTag}:refs/tags/${targetTag}`],
                {
                  cwd: repoRoot,
                  allowFailure: true
                }
              );
              if (pushResult.status === 0) {
                tagPushed = true;
                proposalOnly = false;
                repair.status = 'repaired';
              } else {
                tagPushError = asOptional(pushResult.stderr) ?? asOptional(pushResult.stdout) ?? 'repair tag push failed';
                blockers.push({
                  code: 'repair-tag-push-failed',
                  message: `Signed repair publication failed for ${targetTag}: ${tagPushError}`
                });
              }
            }
          } else {
            tagError = asOptional(tagResult.stderr) ?? asOptional(tagResult.stdout) ?? 'repair tag creation failed';
            blockers.push({
              code: 'repair-tag-recreate-failed',
              message: `Signed repair tag creation failed for ${targetTag}: ${tagError}`
            });
          }
        }
    } else if (repair.remoteTagExists) {
      blockers.push({
        code: 'existing-tag-requires-repair-mode',
        message: `Authoritative tag ${targetTag} already exists. Rerun release conductor with --repair-existing-tag to recreate it as a signed annotated tag at ${repair.remoteTargetCommitOid}.`
      });
    } else if (signingMaterial.available) {
      const tagResult = runCommandFn('git', ['tag', '-s', targetTag, '-m', `Release ${targetTag}`], {
        cwd: repoRoot,
        allowFailure: true
      });
      if (tagResult.status === 0) {
        tagCreated = true;
        const pushRemoteName = asOptional(tagPushRemote.remoteName);
        if (!pushRemoteName) {
          tagPushError = 'Unable to resolve an authoritative git remote for tag publication.';
          blockers.push({
            code: 'tag-push-remote-missing',
            message: `Signed tag ${targetTag} was created locally but no authoritative push remote matched ${repository}.`
          });
        } else {
          const pushResult = runCommandFn('git', ['push', pushRemoteName, `refs/tags/${targetTag}`], {
            cwd: repoRoot,
            allowFailure: true
          });
          if (pushResult.status === 0) {
            tagPushed = true;
            proposalOnly = false;
          } else {
            tagPushError = asOptional(pushResult.stderr) ?? asOptional(pushResult.stdout) ?? 'tag push failed';
            blockers.push({
              code: 'tag-push-failed',
              message: `Signed tag publication failed for ${targetTag}: ${tagPushError}`
            });
          }
        }
      } else {
        tagError = asOptional(tagResult.stderr) ?? asOptional(tagResult.stdout) ?? 'tag creation failed';
        blockers.push({
          code: 'tag-create-failed',
          message: `Signed tag creation failed for ${targetTag}: ${tagError}`
        });
      }
    }
  }

  const status = blockers.length === 0 ? 'pass' : 'fail';
  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    mode: {
      apply: applyRequested,
      dryRun: !applyRequested,
      releaseConductorEnabled: conductorEnabled
    },
    release: {
      stream: args.stream,
      channel: args.channel,
      version: asOptional(args.version),
      targetTag,
      proposalOnly,
      tagCreated,
      tagPushed,
      tagError,
      tagPushError,
      tagPushRemote,
      signingMaterial,
      repair
    },
    inputs: {
      reportPath: args.reportPath,
      queueReportPath: args.queueReportPath,
      policySnapshotPath: args.policySnapshotPath,
      dwellMinutes: args.dwellMinutes,
      quarantineStaleHours: args.quarantineStaleHours
    },
    gates: {
      greenDwell: greenDwellGate,
      queueHealth: queueHealthGate,
      policySnapshot: policySnapshotGate,
      quarantine: quarantineGate
    },
    workflowFetchErrors: fetchErrors,
    decision: {
      status,
      blockerCount: blockers.length,
      blockers,
      advisoryCount: advisories.length,
      advisories
    }
  };

  const reportPath = await writeReportFn(args.reportPath, report);
  return {
    report,
    reportPath,
    exitCode: status === 'pass' ? 0 : 1
  };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const { report, reportPath, exitCode } = await runReleaseConductor({ args });
  console.log(
    `[release-conductor] report: ${reportPath} status=${report.decision.status} blockers=${report.decision.blockerCount} advisories=${report.decision.advisoryCount}`
  );
  if (report.release.targetTag) {
    console.log(`[release-conductor] targetTag=${report.release.targetTag} proposalOnly=${report.release.proposalOnly}`);
  }
  return exitCode;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((exitCode) => {
      if (exitCode !== 0) {
        process.exitCode = exitCode;
      }
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}
