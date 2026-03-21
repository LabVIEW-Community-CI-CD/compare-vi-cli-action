#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'release', 'release-scorecard.json');

const HELP = [
  'Usage: node tools/priority/release-scorecard.mjs [options]',
  '',
  'Options:',
  '  --stream <name>                Release stream id (required).',
  '  --channel <name>               Release channel (required).',
  '  --version <semver>             Release version (optional).',
  '  --repo <owner/repo>            Repository slug (default: env/remotes).',
  `  --output <path>                Output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --ledger <path>                Promotion evidence ledger JSON path (required).',
  '  --slo <path>                   SLO metrics JSON path (required).',
  '  --rollback <path>              Rollback drill health JSON path (required).',
  '  --trust <path>                 Supply-chain trust JSON path (optional).',
  '  --downstream-promotion <path>  Downstream promotion scorecard JSON path (optional).',
  '  --tag-ref <ref>                Tag reference for signed-tag assertions.',
  '  --require-downstream-proving   Treat missing/failing downstream promotion scorecard as blocker.',
  '  --require-signed-tag           Treat unsigned/missing tag signature as blocker.',
  '  --fail-on-blockers             Exit non-zero when blockers exist (default true).',
  '  --no-fail-on-blockers          Emit scorecard without failing process exit.',
  '  -h, --help                     Show help.'
];

function printHelp(log = console.log) {
  for (const line of HELP) log(line);
}

function asOptional(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized || null;
}

function readJson(filePath) {
  const resolved = path.resolve(filePath);
  const raw = fs.readFileSync(resolved, 'utf8');
  return JSON.parse(raw);
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo) {
  if (asOptional(explicitRepo)?.includes('/')) return String(explicitRepo).trim();
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) return process.env.GITHUB_REPOSITORY.trim();
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {
      // ignore
    }
  }
  return null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    stream: null,
    channel: null,
    version: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    ledgerPath: null,
    sloPath: null,
    rollbackPath: null,
    trustPath: null,
    downstreamPromotionPath: null,
    tagRef: null,
    requireDownstreamProving: false,
    requireSignedTag: false,
    failOnBlockers: true,
    help: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    const next = args[i + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--require-signed-tag') {
      options.requireSignedTag = true;
      continue;
    }
    if (token === '--require-downstream-proving') {
      options.requireDownstreamProving = true;
      continue;
    }
    if (token === '--fail-on-blockers') {
      options.failOnBlockers = true;
      continue;
    }
    if (token === '--no-fail-on-blockers') {
      options.failOnBlockers = false;
      continue;
    }

    const stringFlags = new Set([
      '--repo',
      '--stream',
      '--channel',
      '--version',
      '--output',
      '--ledger',
      '--slo',
      '--rollback',
      '--trust',
      '--downstream-promotion',
      '--tag-ref'
    ]);
    if (stringFlags.has(token)) {
      if (!next || next.startsWith('-')) throw new Error(`Missing value for ${token}.`);
      i += 1;
      if (token === '--repo') options.repo = next;
      if (token === '--stream') options.stream = next;
      if (token === '--channel') options.channel = next;
      if (token === '--version') options.version = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--ledger') options.ledgerPath = next;
      if (token === '--slo') options.sloPath = next;
      if (token === '--rollback') options.rollbackPath = next;
      if (token === '--trust') options.trustPath = next;
      if (token === '--downstream-promotion') options.downstreamPromotionPath = next;
      if (token === '--tag-ref') options.tagRef = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  for (const required of ['stream', 'channel', 'ledgerPath', 'sloPath', 'rollbackPath']) {
    if (!asOptional(options[required])) {
      throw new Error(`Missing required option: --${required.replace('Path', '').replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`)}`);
    }
  }
  return options;
}

function loadInputFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return { exists: false, path: resolved, payload: null, error: null };
  }
  try {
    return { exists: true, path: resolved, payload: readJson(resolved), error: null };
  } catch (error) {
    return { exists: true, path: resolved, payload: null, error: error.message || String(error) };
  }
}

function statusFromSlo(payload) {
  if (!payload || typeof payload !== 'object') {
    return { status: 'missing', breachCount: null, blockerCount: null, source: 'missing', blockers: [] };
  }
  const breaches = Array.isArray(payload.breaches) ? payload.breaches : [];
  const promotionGate = payload.promotionGate && typeof payload.promotionGate === 'object' ? payload.promotionGate : null;
  if (promotionGate) {
    return {
      status: promotionGate.status || (breaches.length > 0 ? 'fail' : 'pass'),
      breachCount: breaches.length,
      blockerCount: Number.isFinite(promotionGate.blockerCount) ? promotionGate.blockerCount : null,
      source: 'promotion-gate',
      blockers: Array.isArray(promotionGate.blockers) ? promotionGate.blockers : []
    };
  }
  return {
    status: breaches.length > 0 ? 'fail' : 'pass',
    breachCount: breaches.length,
    blockerCount: breaches.length,
    source: 'breaches',
    blockers: breaches
  };
}

function statusFromRollback(payload) {
  if (!payload || typeof payload !== 'object') {
    return { status: 'missing', pausePromotion: null };
  }
  const summary = payload.summary || {};
  return {
    status: summary.status || 'missing',
    pausePromotion: typeof summary.pausePromotion === 'boolean' ? summary.pausePromotion : null
  };
}

function statusFromLedger(payload) {
  if (!payload || typeof payload !== 'object') {
    return { status: 'missing', reason: null };
  }
  const gate = payload.gate || {};
  return {
    status: gate.status || 'missing',
    reason: gate.reason || null
  };
}

function statusFromTrust(payload) {
  if (!payload || typeof payload !== 'object') {
    return { status: 'not-applicable', failureCount: null, tagVerified: null, tagReason: null };
  }
  const summary = payload.summary || {};
  const tagSignature = payload.tagSignature || {};
  return {
    status: summary.status || 'missing',
    failureCount: Number.isFinite(summary.failureCount) ? summary.failureCount : null,
    tagVerified: typeof tagSignature.verified === 'boolean' ? tagSignature.verified : null,
    tagReason: tagSignature.reason || null
  };
}

function statusFromDownstreamPromotion(payload) {
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'missing',
      schema: null,
      summaryStatus: null,
      blockerCount: null,
      downstreamRepository: null,
      sourceCommitSha: null
    };
  }

  const schema = asOptional(payload.schema);
  const summaryStatus = asOptional(payload?.summary?.status);
  const blockerCount = Number.isFinite(payload?.summary?.blockerCount) ? payload.summary.blockerCount : null;
  const downstreamRepository = asOptional(payload?.gates?.feedbackReport?.downstreamRepository);
  const sourceCommitSha = asOptional(payload?.summary?.provenance?.sourceCommitSha);

  return {
    status: schema === 'priority/downstream-promotion-scorecard@v1' && summaryStatus === 'pass' ? 'pass' : 'fail',
    schema,
    summaryStatus,
    blockerCount,
    downstreamRepository,
    sourceCommitSha
  };
}

export function evaluateReleaseScorecard(inputs) {
  const blockers = [];
  const recordBlocker = (code, message) => blockers.push({ code, message });

  if (!inputs.ledger.exists || inputs.ledger.error) {
    recordBlocker('ledger-missing', 'Promotion evidence ledger artifact is missing or unreadable.');
  }
  if (!inputs.slo.exists || inputs.slo.error) {
    recordBlocker('slo-missing', 'SLO metrics artifact is missing or unreadable.');
  }
  if (!inputs.rollback.exists || inputs.rollback.error) {
    recordBlocker('rollback-missing', 'Rollback health artifact is missing or unreadable.');
  }
  if (inputs.requireDownstreamProving && (!inputs.downstreamPromotionProvided || !inputs.downstreamPromotion.exists || inputs.downstreamPromotion.error)) {
    recordBlocker('downstream-promotion-missing', 'Downstream promotion scorecard is missing or unreadable.');
  } else if (inputs.downstreamPromotionProvided && (!inputs.downstreamPromotion.exists || inputs.downstreamPromotion.error)) {
    recordBlocker('downstream-promotion-missing', 'Downstream promotion scorecard is missing or unreadable.');
  }
  if (inputs.promotion.status !== 'pass') {
    recordBlocker('promotion-gate', `Promotion gate status is ${inputs.promotion.status}.`);
  }
  if (inputs.rollbackGate.status !== 'pass') {
    recordBlocker('rollback-gate', `Rollback drill status is ${inputs.rollbackGate.status}.`);
  }
  if (inputs.sloGate.status === 'fail') {
    const blockerCount = Number.isFinite(inputs.sloGate.blockerCount)
      ? inputs.sloGate.blockerCount
      : inputs.sloGate.breachCount;
    const sourceLabel = inputs.sloGate.source === 'promotion-gate' ? 'SLO promotion gate' : 'SLO breaches';
    recordBlocker('slo-breach', `${sourceLabel} detected (${blockerCount}).`);
  }
  if (inputs.trustProvided && inputs.trustGate.status !== 'pass') {
    recordBlocker('trust-gate', `Supply-chain trust gate status is ${inputs.trustGate.status}.`);
  }
  if (inputs.requireDownstreamProving && inputs.downstreamPromotionGate.status !== 'pass') {
    recordBlocker(
      'downstream-promotion-gate',
      `Downstream promotion scorecard status is ${inputs.downstreamPromotionGate.status}.`
    );
  } else if (inputs.downstreamPromotionProvided && inputs.downstreamPromotion.exists && !inputs.downstreamPromotion.error && inputs.downstreamPromotionGate.status !== 'pass') {
    recordBlocker(
      'downstream-promotion-gate',
      `Downstream promotion scorecard status is ${inputs.downstreamPromotionGate.status}.`
    );
  }
  if (inputs.requireSignedTag && inputs.signedTag.status !== 'pass') {
    recordBlocker('signed-tag', 'Signed tag verification was required but not verified.');
  }

  return {
    status: blockers.length === 0 ? 'pass' : 'fail',
    blockerCount: blockers.length,
    blockers
  };
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runReleaseScorecard(rawOptions = {}) {
  const now = new Date();
  const options = {
    ...rawOptions,
    outputPath: rawOptions.outputPath || DEFAULT_OUTPUT_PATH,
    failOnBlockers: rawOptions.failOnBlockers !== false
  };

  const ledger = loadInputFile(options.ledgerPath);
  const slo = loadInputFile(options.sloPath);
  const rollback = loadInputFile(options.rollbackPath);
  const trust = asOptional(options.trustPath) ? loadInputFile(options.trustPath) : null;
  const downstreamPromotion = asOptional(options.downstreamPromotionPath) ? loadInputFile(options.downstreamPromotionPath) : null;

  const promotion = statusFromLedger(ledger.payload);
  const sloGate = statusFromSlo(slo.payload);
  const rollbackGate = statusFromRollback(rollback.payload);
  const trustGate = statusFromTrust(trust?.payload);
  const downstreamPromotionGate = downstreamPromotion
    ? statusFromDownstreamPromotion(downstreamPromotion.payload)
    : {
        status: 'not-applicable',
        schema: null,
        summaryStatus: null,
        blockerCount: null,
        downstreamRepository: null,
        sourceCommitSha: null
      };
  const signedTag = {
    required: Boolean(options.requireSignedTag),
    ref: asOptional(options.tagRef),
    verified: trustGate.tagVerified,
    status: options.requireSignedTag ? (trustGate.tagVerified === true ? 'pass' : 'fail') : 'not-required',
    reason: trustGate.tagReason || null
  };

  const evaluated = evaluateReleaseScorecard({
    ledger,
    slo,
    rollback,
    promotion,
    sloGate,
    rollbackGate,
    trustGate,
    downstreamPromotion,
    downstreamPromotionGate,
    downstreamPromotionProvided: Boolean(downstreamPromotion),
    requireDownstreamProving: Boolean(options.requireDownstreamProving),
    trustProvided: Boolean(trust),
    requireSignedTag: signedTag.required,
    signedTag
  });

  const report = {
    schema: 'release/scorecard@v1',
    generatedAt: now.toISOString(),
    repository: resolveRepoSlug(options.repo),
    release: {
      stream: options.stream,
      channel: options.channel,
      version: asOptional(options.version),
      tagRef: asOptional(options.tagRef)
    },
    inputs: {
      ledger: { path: ledger.path, exists: ledger.exists, error: ledger.error },
      slo: { path: slo.path, exists: slo.exists, error: slo.error },
      rollback: { path: rollback.path, exists: rollback.exists, error: rollback.error },
      trust: trust ? { path: trust.path, exists: trust.exists, error: trust.error } : null,
      downstreamPromotion: downstreamPromotion
        ? { path: downstreamPromotion.path, exists: downstreamPromotion.exists, error: downstreamPromotion.error }
        : null
    },
    gates: {
      promotion,
      slo: sloGate,
      rollback: rollbackGate,
      trust: trustGate,
      downstreamPromotion: {
        required: Boolean(options.requireDownstreamProving),
        ...downstreamPromotionGate
      },
      signedTag
    },
    summary: evaluated
  };

  const reportPath = writeJson(options.outputPath, report);
  console.log(
    `[release-scorecard] report: ${reportPath} (status=${report.summary.status}, blockers=${report.summary.blockerCount})`
  );

  if (process.env.GITHUB_STEP_SUMMARY) {
    const lines = [
      '## Release Scorecard',
      `- status: \`${report.summary.status}\``,
      `- stream/channel: \`${options.stream}/${options.channel}\``,
      `- blockers: \`${report.summary.blockerCount}\``
    ];
    for (const blocker of report.summary.blockers) {
      lines.push(`- ${blocker.code}: ${blocker.message}`);
    }
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`);
  }

  const exitCode = report.summary.blockerCount > 0 && options.failOnBlockers ? 1 : 0;
  return { exitCode, report, reportPath };
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv);
  } catch (error) {
    console.error(error.message || String(error));
    printHelp(console.error);
    process.exitCode = 1;
    return;
  }
  if (options.help) {
    printHelp();
    return;
  }
  const result = await runReleaseScorecard(options);
  process.exitCode = result.exitCode;
}

const ENTRY_FILE = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === ENTRY_FILE) {
  main().catch((error) => {
    console.error(error.stack || error.message || String(error));
    process.exitCode = 1;
  });
}
