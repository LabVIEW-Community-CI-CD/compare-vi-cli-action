#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'downstream-promotion-contract.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'downstream-develop-promotion-manifest.json'
);

const HELP = [
  'Usage: node tools/priority/downstream-promotion-manifest.mjs [options]',
  '',
  'Options:',
  '  --source-ref <ref>                    Source git ref (default: upstream/develop).',
  '  --source-sha <sha>                    Immutable upstream commit SHA (required).',
  '  --comparevi-tools-release <id>        CompareVI.Tools release identity (required).',
  '  --comparevi-history-release <id>      comparevi-history release identity (required).',
  '  --scenario-pack-id <id>               Scenario-pack or corpus identity (required).',
  '  --cookiecutter-template-id <id>       Cookiecutter/template identity (required).',
  '  --proving-scorecard-ref <ref>         Proving scorecard reference (required).',
  '  --vi-history-lv32-shadow-proof-receipt <path>  Optional LV32 shadow proof receipt path.',
  '  --actor <value>                       Promotion actor (default: GITHUB_ACTOR).',
  '  --promotion-kind <kind>               promote|replay|rollback (default: promote).',
  '  --replay-of-manifest <ref>            Required when promotion-kind=replay.',
  '  --rollback-of-manifest <ref>          Required when promotion-kind=rollback.',
  `  --policy <path>                       Contract policy path (default: ${DEFAULT_POLICY_PATH}).`,
  `  --output <path>                       Output manifest path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>                   Repository slug (default: env/remotes).',
  '  -h, --help                            Show help.'
];

function printHelp(log = console.log) {
  for (const line of HELP) {
    log(line);
  }
}

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized || null;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) {
    return null;
  }
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo, execSyncFn = execSync) {
  if (asOptional(explicitRepo)?.includes('/')) {
    return asOptional(explicitRepo);
  }
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) {
    return asOptional(process.env.GITHUB_REPOSITORY);
  }
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSyncFn(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) {
        return slug;
      }
    } catch {
      // ignore missing remotes
    }
  }
  return null;
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function resolveGitRef(ref, execSyncFn = execSync) {
  return execSyncFn(`git rev-parse ${ref}`, {
    stdio: ['ignore', 'pipe', 'ignore']
  })
    .toString('utf8')
    .trim();
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

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    sourceRef: 'upstream/develop',
    sourceSha: null,
    compareviToolsRelease: null,
    compareviHistoryRelease: null,
    scenarioPackIdentity: null,
    cookiecutterTemplateIdentity: null,
    provingScorecardRef: null,
    viHistoryLv32ShadowProofReceiptPath: null,
    actor: asOptional(process.env.GITHUB_ACTOR),
    promotionKind: 'promote',
    replayOfManifest: null,
    rollbackOfManifest: null,
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    const stringFlags = new Map([
      ['--source-ref', 'sourceRef'],
      ['--source-sha', 'sourceSha'],
      ['--comparevi-tools-release', 'compareviToolsRelease'],
      ['--comparevi-history-release', 'compareviHistoryRelease'],
      ['--scenario-pack-id', 'scenarioPackIdentity'],
      ['--cookiecutter-template-id', 'cookiecutterTemplateIdentity'],
      ['--proving-scorecard-ref', 'provingScorecardRef'],
      ['--vi-history-lv32-shadow-proof-receipt', 'viHistoryLv32ShadowProofReceiptPath'],
      ['--actor', 'actor'],
      ['--promotion-kind', 'promotionKind'],
      ['--replay-of-manifest', 'replayOfManifest'],
      ['--rollback-of-manifest', 'rollbackOfManifest'],
      ['--policy', 'policyPath'],
      ['--output', 'outputPath'],
      ['--repo', 'repo']
    ]);

    if (stringFlags.has(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      options[stringFlags.get(token)] = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  const required = [
    ['sourceSha', '--source-sha'],
    ['compareviToolsRelease', '--comparevi-tools-release'],
    ['compareviHistoryRelease', '--comparevi-history-release'],
    ['scenarioPackIdentity', '--scenario-pack-id'],
    ['cookiecutterTemplateIdentity', '--cookiecutter-template-id'],
    ['provingScorecardRef', '--proving-scorecard-ref'],
    ['actor', '--actor']
  ];
  for (const [key, flag] of required) {
    if (!asOptional(options[key])) {
      throw new Error(`Missing required option: ${flag}.`);
    }
  }

  if (!['promote', 'replay', 'rollback'].includes(options.promotionKind)) {
    throw new Error('Invalid --promotion-kind. Expected promote, replay, or rollback.');
  }
  if (options.promotionKind === 'replay' && !asOptional(options.replayOfManifest)) {
    throw new Error('Missing required option: --replay-of-manifest.');
  }
  if (options.promotionKind === 'rollback' && !asOptional(options.rollbackOfManifest)) {
    throw new Error('Missing required option: --rollback-of-manifest.');
  }
  if (options.promotionKind !== 'replay' && asOptional(options.replayOfManifest)) {
    throw new Error('--replay-of-manifest requires --promotion-kind replay.');
  }
  if (options.promotionKind !== 'rollback' && asOptional(options.rollbackOfManifest)) {
    throw new Error('--rollback-of-manifest requires --promotion-kind rollback.');
  }

  return options;
}

export async function runDownstreamPromotionManifest(
  options,
  {
    now = new Date(),
    resolveRepoSlugFn = resolveRepoSlug,
    resolveGitRefFn = resolveGitRef,
    readJsonFn = readJson,
    writeJsonFn = writeJson,
    sha256FileFn = sha256File
  } = {}
) {
  const repo = asOptional(resolveRepoSlugFn(options.repo));
  if (!repo) {
    throw new Error('Unable to determine repository slug.');
  }

  const policyPath = path.resolve(options.policyPath || DEFAULT_POLICY_PATH);
  const policy = readJsonFn(policyPath);
  if (policy?.schema !== 'priority/downstream-promotion-contract@v1') {
    throw new Error('Downstream promotion contract schema mismatch.');
  }

  const sourceRef = asOptional(options.sourceRef) || policy.sourceRef;
  const targetBranch = asOptional(policy.targetBranch);
  const targetBranchClassId = asOptional(policy.targetBranchClassId);
  const shadowProofReceiptPath = asOptional(options.viHistoryLv32ShadowProofReceiptPath);
  if (sourceRef !== policy.sourceRef) {
    throw new Error(`Source ref must remain ${policy.sourceRef}.`);
  }
  if (targetBranch !== 'downstream/develop') {
    throw new Error('Downstream promotion contract target branch drifted from downstream/develop.');
  }
  if (targetBranchClassId !== 'downstream-consumer-proving-rail') {
    throw new Error('Downstream promotion contract target branch class drifted.');
  }
  let shadowProofReceipt = null;
  if (shadowProofReceiptPath) {
    const resolvedShadowProofReceiptPath = path.resolve(shadowProofReceiptPath);
    if (!fs.existsSync(resolvedShadowProofReceiptPath) || !fs.statSync(resolvedShadowProofReceiptPath).isFile()) {
      throw new Error(
        `LV32 shadow proof receipt is missing or unreadable: ${resolvedShadowProofReceiptPath}.`
      );
    }
    shadowProofReceipt = {
      path: path.relative(process.cwd(), resolvedShadowProofReceiptPath).replace(/\\/g, '/'),
      sha256: sha256FileFn(resolvedShadowProofReceiptPath)
    };
  }

  let resolvedSourceCommitSha = null;
  let sourceVerificationAttempted = false;
  let sourceVerificationMatched = false;
  try {
    resolvedSourceCommitSha = asOptional(resolveGitRefFn(sourceRef));
    sourceVerificationAttempted = true;
    sourceVerificationMatched = resolvedSourceCommitSha === asOptional(options.sourceSha);
  } catch {
    sourceVerificationAttempted = false;
    sourceVerificationMatched = false;
  }

  if (sourceVerificationAttempted && !sourceVerificationMatched) {
    throw new Error(
      `Source ref ${sourceRef} resolved to ${resolvedSourceCommitSha}, expected ${options.sourceSha}.`
    );
  }

  const manifest = {
    schema: 'priority/downstream-promotion-manifest@v1',
    generatedAt: now.toISOString(),
    repository: repo,
    contract: {
      path: path.relative(process.cwd(), policyPath).replace(/\\/g, '/'),
      sha256: sha256FileFn(policyPath)
    },
    promotion: {
      sourceRef,
      sourceCommitSha: asOptional(options.sourceSha),
      targetBranch,
      targetBranchClassId,
      actor: asOptional(options.actor),
      provingScorecardRef: asOptional(options.provingScorecardRef),
      localSourceVerification: {
        attempted: sourceVerificationAttempted,
        matched: sourceVerificationMatched,
        resolvedCommitSha: resolvedSourceCommitSha
      }
    },
    inputs: {
      compareviToolsRelease: asOptional(options.compareviToolsRelease),
      compareviHistoryRelease: asOptional(options.compareviHistoryRelease),
      scenarioPackIdentity: asOptional(options.scenarioPackIdentity),
      cookiecutterTemplateIdentity: asOptional(options.cookiecutterTemplateIdentity),
      viHistoryLv32ShadowProofReceipt: shadowProofReceipt
    },
    lineage: {
      promotionKind: options.promotionKind,
      replayOfManifest: asOptional(options.replayOfManifest),
      rollbackOfManifest: asOptional(options.rollbackOfManifest)
    }
  };

  const outputPath = writeJsonFn(options.outputPath || DEFAULT_OUTPUT_PATH, manifest);
  return { manifest, outputPath };
}

export async function main(argv = process.argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    console.error(`[downstream-promotion-manifest] ${error.message}`);
    printHelp(console.error);
    return 1;
  }

  if (args.help) {
    printHelp();
    return 0;
  }

  try {
    const { outputPath, manifest } = await runDownstreamPromotionManifest(args);
    console.log(
      `[downstream-promotion-manifest] wrote ${outputPath} (${manifest.promotion.sourceCommitSha} -> ${manifest.promotion.targetBranch})`
    );
    return 0;
  } catch (error) {
    console.error(`[downstream-promotion-manifest] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  const exitCode = await main(process.argv);
  if (exitCode !== 0) {
    process.exit(exitCode);
  }
}
