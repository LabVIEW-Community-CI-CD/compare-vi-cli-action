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
export const DEFAULT_QUARANTINE_STALE_HOURS = 24;
export const RELEASE_PUBLICATION_WORKFLOW = 'release.yml';
export const RELEASE_PUBLICATION_WORKFLOW_REF = 'develop';
export const RELEASE_PUBLICATION_TAG_INPUT = 'release_tag';
export const RELEASE_PUBLICATION_MODE_INPUT = 'publication_mode';
export const RELEASE_PUBLICATION_MODE_PUBLISH = 'publish';
export const RELEASE_PUBLICATION_MODE_VERIFY_EXISTING_RELEASE = 'verify-existing-release';

function printUsage() {
  console.log('Usage: node tools/priority/release-conductor.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --apply                     Apply release mutation (default is --dry-run).');
  console.log('  --repair-existing-tag       Repair an existing authoritative tag or dispatch protected-tag-safe replay for immutable published tags.');
  console.log(`  --report <path>             Write report JSON (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --queue-report <path>       Queue supervisor report path (default: ${DEFAULT_QUEUE_REPORT_PATH}).`);
  console.log(`  --policy-snapshot <path>    Policy snapshot path (default: ${DEFAULT_POLICY_SNAPSHOT_PATH}).`);
  console.log('  --repo <owner/repo>         Target repository (default: GITHUB_REPOSITORY/upstream/origin remote).');
  console.log('  --stream <name>             Release stream name (default: comparevi-cli).');
  console.log('  --channel <stable|rc>       Release channel (default: stable).');
  console.log('  --version <semver>          Proposed version used for release tag proposal (optional).');
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

function isGitHubNotFoundError(message) {
  const normalized = asOptional(message);
  return Boolean(normalized && (/\b404\b/.test(normalized) || /not found/i.test(normalized)));
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
  const controls =
    queueReport?.controls && typeof queueReport.controls === 'object' ? queueReport.controls : {};
  const burst =
    queueReport?.burst && typeof queueReport.burst === 'object' ? queueReport.burst : {};
  const triggerSignals =
    burst?.triggerSignals && typeof burst.triggerSignals === 'object' ? burst.triggerSignals : {};
  const controllerMode =
    queueReport?.throughputController?.mode ??
    queueReport?.adaptiveInflight?.mode ??
    null;
  const pausedReasons = Array.isArray(queueReport?.pausedReasons) ? queueReport.pausedReasons : [];
  const successRateThrottlePause =
    paused &&
    controllerMode === 'stabilize' &&
    pausedReasons.length > 0 &&
    pausedReasons.every((reason) => reason === 'success-rate-below-threshold');
  const explicitOperatorPause =
    Boolean(controls?.pausedByVariable) ||
    Boolean(controls?.queueAutopilotPaused) ||
    controllerMode === 'pause';
  const activeReleaseQueueActivity =
    Boolean(burst?.active) &&
    (Boolean(triggerSignals?.releaseWindow) ||
      Boolean(triggerSignals?.releaseBranchPullRequest) ||
      Boolean(triggerSignals?.releaseBurstLabel));

  const reasons = [];
  if (successRateThrottlePause && !explicitOperatorPause && !activeReleaseQueueActivity) {
    reasons.push('release-safe-generic-stabilize-pause');
  }
  if (explicitOperatorPause) reasons.push('release-queue-explicit-pause');
  if (activeReleaseQueueActivity) reasons.push('release-queue-activity-active');
  if (paused && !successRateThrottlePause && !explicitOperatorPause) reasons.push('queue-paused');
  if (controllerMode === 'stabilize' && !successRateThrottlePause) reasons.push('queue-stabilize-mode');

  if (successRateThrottlePause && !explicitOperatorPause && !activeReleaseQueueActivity) {
    return {
      status: 'pass',
      reasons: ['release-safe-generic-stabilize-pause'],
      paused,
      controllerMode
    };
  }

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

function describeQueueHealthBlocker(gate) {
  const reasons = Array.isArray(gate?.reasons) ? gate.reasons : [];
  if (reasons.includes('release-queue-explicit-pause')) {
    return 'Queue supervisor reported an explicit release queue pause.';
  }
  if (reasons.includes('release-queue-activity-active')) {
    return 'Queue supervisor reported active release queue activity.';
  }
  if (reasons.includes('queue-report-unavailable')) {
    return 'Queue supervisor evidence is unavailable.';
  }
  return 'Queue supervisor reported release-relevant queue risk.';
}

function pushUniqueDecisionEntry(entries, entry) {
  if (!entries.some((candidate) => candidate.code === entry.code)) {
    entries.push(entry);
  }
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
  const nameResult = runCommandFn('git', ['config', '--get', 'user.name'], {
    cwd: repoRoot,
    allowFailure: true
  });
  const emailResult = runCommandFn('git', ['config', '--get', 'user.email'], {
    cwd: repoRoot,
    allowFailure: true
  });
  const configuredFormat = asOptional(formatResult.stdout);
  const backend = asOptional(environment.RELEASE_TAG_SIGNING_BACKEND) ?? configuredFormat ?? 'openpgp';
  const source = signingKey ? asOptional(environment.RELEASE_TAG_SIGNING_SOURCE) ?? 'git-config' : 'missing';
  const identityName = asOptional(nameResult.stdout);
  const identityEmail = asOptional(emailResult.stdout);
  const identityAvailable = Boolean(identityName && identityEmail);

  return {
    available: Boolean(signingKey),
    signingKey,
    source,
    backend,
    identity: {
      available: identityAvailable,
      name: identityName,
      email: identityEmail,
      source: identityAvailable ? asOptional(environment.RELEASE_TAG_SIGNING_IDENTITY_SOURCE) ?? 'git-config' : 'missing',
      login: asOptional(environment.RELEASE_TAG_SIGNING_IDENTITY_LOGIN),
      accountId: asOptional(environment.RELEASE_TAG_SIGNING_IDENTITY_ID)
    }
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

function inspectImmutableReleaseState({ repository, tagRef, runGhJsonFn, cwd }) {
  const normalizedTagRef = asOptional(tagRef);
  const immutableRelease = {
    status: 'unobserved',
    tagRef: normalizedTagRef,
    repairBlocked: false,
    repositorySetting: {
      status: 'unobserved',
      enabled: null,
      enforcedByOwner: null,
      error: null
    },
    publishedRelease: {
      status: 'unobserved',
      exists: null,
      immutable: null,
      releaseId: null,
      releaseUrl: null,
      tagName: null,
      error: null
    }
  };
  if (!normalizedTagRef) {
    return immutableRelease;
  }

  try {
    const payload = runGhJsonFn(['api', `repos/${repository}/immutable-releases`], { cwd }) ?? {};
    if (typeof payload?.enabled === 'boolean' || typeof payload?.enforced_by_owner === 'boolean') {
      immutableRelease.repositorySetting = {
        status: payload.enabled === true ? 'enabled' : 'disabled',
        enabled: payload.enabled === true,
        enforcedByOwner: payload.enforced_by_owner === true,
        error: null
      };
    } else {
      immutableRelease.repositorySetting = {
        status: 'unverifiable',
        enabled: null,
        enforcedByOwner: null,
        error: 'immutable release settings response shape was not recognized'
      };
    }
  } catch (error) {
    immutableRelease.repositorySetting = {
      status: 'unverifiable',
      enabled: null,
      enforcedByOwner: null,
      error: error?.message ?? String(error)
    };
  }

  try {
    const payload = runGhJsonFn(['api', `repos/${repository}/releases/tags/${normalizedTagRef}`], { cwd }) ?? {};
    const looksLikeRelease =
      typeof payload?.immutable === 'boolean' ||
      Number.isInteger(payload?.id) ||
      Boolean(asOptional(payload?.tag_name)) ||
      Boolean(asOptional(payload?.html_url));
    if (!looksLikeRelease) {
      immutableRelease.publishedRelease = {
        status: 'unverifiable',
        exists: null,
        immutable: null,
        releaseId: null,
        releaseUrl: null,
        tagName: null,
        error: 'release lookup response shape was not recognized'
      };
    } else {
      immutableRelease.publishedRelease = {
        status: payload.immutable === true ? 'immutable' : 'mutable',
        exists: true,
        immutable: payload.immutable === true,
        releaseId: Number.isInteger(payload?.id) ? payload.id : null,
        releaseUrl: asOptional(payload?.html_url) ?? asOptional(payload?.url),
        tagName: asOptional(payload?.tag_name) ?? normalizedTagRef,
        error: null
      };
    }
  } catch (error) {
    const message = error?.message ?? String(error);
    immutableRelease.publishedRelease = {
      status: isGitHubNotFoundError(message) ? 'release-not-found' : 'unverifiable',
      exists: isGitHubNotFoundError(message) ? false : null,
      immutable: null,
      releaseId: null,
      releaseUrl: null,
      tagName: normalizedTagRef,
      error: message
    };
  }

  if (immutableRelease.publishedRelease.status === 'immutable') {
    immutableRelease.status = 'published-release-immutable';
    immutableRelease.repairBlocked = true;
  } else if (immutableRelease.publishedRelease.status === 'mutable') {
    immutableRelease.status = 'published-release-mutable';
  } else if (immutableRelease.publishedRelease.status === 'release-not-found') {
    immutableRelease.status = 'release-not-found';
  } else if (
    immutableRelease.repositorySetting.status === 'unverifiable' ||
    immutableRelease.publishedRelease.status === 'unverifiable'
  ) {
    immutableRelease.status = 'unverifiable';
  }

  return immutableRelease;
}

function buildImmutableRepairReplayMessage({ targetTag, immutableRelease }) {
  const normalizedTag = asOptional(targetTag) ?? 'the current release tag';
  const releaseUrl = asOptional(immutableRelease?.publishedRelease?.releaseUrl);
  const releaseLocation = releaseUrl ? ` (${releaseUrl})` : '';
  return `Authoritative tag ${normalizedTag} already backs an immutable published GitHub Release${releaseLocation}. Rerun release conductor with --repair-existing-tag to dispatch protected-tag-safe release replay from develop without mutating the published release.`;
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
  if (queueHealthGate.status !== 'pass') {
    if (!applyRequested && isQueueReportUnavailableGate(queueHealthGate)) {
      pushUniqueDecisionEntry(advisories, {
        code: 'queue-report-unavailable-dry-run',
        message: 'Queue supervisor evidence is unavailable; queue health and quarantine checks remain advisory while release conductor stays proposal-only.'
      });
    } else {
      blockers.push({
        code: 'queue-health-failed',
        message: describeQueueHealthBlocker(queueHealthGate)
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
  const publicationReplay = {
    requested: Boolean(args.repairExistingTag && applyRequested),
    workflow: RELEASE_PUBLICATION_WORKFLOW,
    ref: RELEASE_PUBLICATION_WORKFLOW_REF,
    tagInputName: RELEASE_PUBLICATION_TAG_INPUT,
    tagInputValue: targetTag,
    modeInputName: RELEASE_PUBLICATION_MODE_INPUT,
    modeInputValue: null,
    dispatched: false,
    status: args.repairExistingTag && applyRequested ? 'blocked' : 'not-requested',
    error: null
  };
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
  const immutableRelease =
    targetTag && (repair.requested || repair.remoteTagExists)
      ? inspectImmutableReleaseState({
          repository,
          tagRef: targetTag,
          runGhJsonFn,
          cwd: repoRoot
        })
      : inspectImmutableReleaseState({
          repository,
          tagRef: null,
          runGhJsonFn,
          cwd: repoRoot
        });
  const repairBlockedByImmutableRelease = Boolean(repair.remoteTagExists && immutableRelease.repairBlocked);

  if (repair.remoteTagExists && !repair.requested) {
    repair.status = repairBlockedByImmutableRelease ? 'ready-equivalent-replay' : 'repair-available';
    pushUniqueDecisionEntry(
      advisories,
      repairBlockedByImmutableRelease
        ? {
            code: 'existing-tag-repair-blocked-by-immutable-release',
            message: buildImmutableRepairReplayMessage({ targetTag, immutableRelease })
          }
        : {
            code: 'existing-tag-repair-available',
            message: `Authoritative tag ${targetTag} already exists; rerun release conductor with --repair-existing-tag to recreate it as a signed annotated tag.`
          }
    );
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
  } else if (repair.requested && repairBlockedByImmutableRelease) {
    repair.status = applyRequested ? 'blocked' : 'ready-equivalent-replay';
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
    } else if (args.repairExistingTag && repairBlockedByImmutableRelease) {
      publicationReplay.modeInputValue = RELEASE_PUBLICATION_MODE_VERIFY_EXISTING_RELEASE;
      const dispatchResult = runCommandFn(
        'gh',
        [
          'workflow',
          'run',
          RELEASE_PUBLICATION_WORKFLOW,
          '--ref',
          RELEASE_PUBLICATION_WORKFLOW_REF,
          '-f',
          `${RELEASE_PUBLICATION_TAG_INPUT}=${targetTag}`,
          '-f',
          `${RELEASE_PUBLICATION_MODE_INPUT}=${RELEASE_PUBLICATION_MODE_VERIFY_EXISTING_RELEASE}`
        ],
        {
          cwd: repoRoot,
          allowFailure: true
        }
      );
      if (dispatchResult.status === 0) {
        proposalOnly = false;
        repair.status = 'equivalent-replay-dispatched';
        publicationReplay.dispatched = true;
        publicationReplay.status = 'dispatched';
      } else {
        publicationReplay.status = 'dispatch-failed';
        publicationReplay.error =
          asOptional(dispatchResult.stderr) ??
          asOptional(dispatchResult.stdout) ??
          'release workflow dispatch failed';
        blockers.push({
          code: 'release-replay-dispatch-failed',
          message: `Release publication replay dispatch failed for ${targetTag}: ${publicationReplay.error}`
        });
      }
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
                publicationReplay.modeInputValue = RELEASE_PUBLICATION_MODE_PUBLISH;
                const dispatchResult = runCommandFn(
                  'gh',
                  [
                    'workflow',
                    'run',
                    RELEASE_PUBLICATION_WORKFLOW,
                    '--ref',
                    RELEASE_PUBLICATION_WORKFLOW_REF,
                    '-f',
                    `${RELEASE_PUBLICATION_TAG_INPUT}=${targetTag}`,
                    '-f',
                    `${RELEASE_PUBLICATION_MODE_INPUT}=${RELEASE_PUBLICATION_MODE_PUBLISH}`
                  ],
                  {
                    cwd: repoRoot,
                    allowFailure: true
                  }
                );
                if (dispatchResult.status === 0) {
                  publicationReplay.dispatched = true;
                  publicationReplay.status = 'dispatched';
                } else {
                  publicationReplay.status = 'dispatch-failed';
                  publicationReplay.error =
                    asOptional(dispatchResult.stderr) ??
                    asOptional(dispatchResult.stdout) ??
                    'release workflow dispatch failed';
                  blockers.push({
                    code: 'release-replay-dispatch-failed',
                    message: `Release publication replay dispatch failed for ${targetTag}: ${publicationReplay.error}`
                  });
                }
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
      blockers.push(
        repairBlockedByImmutableRelease
          ? {
              code: 'existing-tag-repair-blocked-by-immutable-release',
              message: buildImmutableRepairReplayMessage({ targetTag, immutableRelease })
            }
          : {
              code: 'existing-tag-requires-repair-mode',
              message: `Authoritative tag ${targetTag} already exists. Rerun release conductor with --repair-existing-tag to recreate it as a signed annotated tag at ${repair.remoteTargetCommitOid}.`
            }
      );
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
      immutableRelease,
      repair,
      publicationReplay
    },
    inputs: {
      reportPath: args.reportPath,
      queueReportPath: args.queueReportPath,
      policySnapshotPath: args.policySnapshotPath,
      quarantineStaleHours: args.quarantineStaleHours
    },
    gates: {
      queueHealth: queueHealthGate,
      policySnapshot: policySnapshotGate,
      quarantine: quarantineGate
    },
    workflowFetchErrors: [],
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
