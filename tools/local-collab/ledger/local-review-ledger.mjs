#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA = 'comparevi/local-collab-ledger-receipt@v1';
export const LOCAL_COLLAB_LEDGER_LATEST_SCHEMA = 'comparevi/local-collab-ledger-latest@v1';
export const DEFAULT_LOCAL_COLLAB_LEDGER_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'local-collab',
  'ledger'
);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function normalizeArray(values) {
  if (!Array.isArray(values)) {
    return [];
  }
  return values.map((value) => normalizeText(value)).filter(Boolean);
}

function uniqueStrings(values) {
  return [...new Set(normalizeArray(values))];
}

function normalizeInteger(value, fallback = 0) {
  return Number.isInteger(value) ? value : fallback;
}

function normalizePathForReceipt(repoRoot, targetPath) {
  const absolutePath = path.resolve(targetPath);
  const relativePath = path.relative(repoRoot, absolutePath);
  if (!relativePath || relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    throw new Error(`Path must stay within the repository root: ${targetPath}`);
  }
  return relativePath.replace(/\\/g, '/');
}

function runGit(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const stdout = normalizeText(result.stdout);
  const stderr = normalizeText(result.stderr);
  if (result.status !== 0) {
    throw new Error(stderr || stdout || `git ${args.join(' ')} failed`);
  }
  return stdout;
}

function tryGit(repoRoot, args) {
  try {
    return runGit(repoRoot, args);
  } catch {
    return '';
  }
}

export function resolveGitContext(repoRoot) {
  const headSha = tryGit(repoRoot, ['rev-parse', 'HEAD']);
  if (!headSha) {
    throw new Error('Unable to resolve the current git HEAD for the local collaboration ledger.');
  }

  const mergeBaseCandidates = [
    ['merge-base', 'HEAD', 'refs/remotes/upstream/develop'],
    ['merge-base', 'HEAD', 'refs/remotes/origin/develop'],
    ['merge-base', 'HEAD', 'develop'],
    ['rev-parse', 'HEAD~1']
  ];
  const baseSha =
    mergeBaseCandidates
      .map((candidate) => tryGit(repoRoot, candidate))
      .find(Boolean) || headSha;

  return {
    headSha,
    baseSha
  };
}

function deriveProviderId(providers) {
  const normalized = uniqueStrings(providers);
  if (normalized.length === 0) {
    return 'none';
  }
  if (normalized.length === 1) {
    return normalized[0];
  }
  return 'multi';
}

function defaultLedgerReceiptPath(repoRoot, phase, headSha) {
  return path.join(repoRoot, DEFAULT_LOCAL_COLLAB_LEDGER_ROOT, 'receipts', phase, `${headSha}.json`);
}

function defaultLedgerLatestIndexPath(repoRoot, phase) {
  return path.join(repoRoot, DEFAULT_LOCAL_COLLAB_LEDGER_ROOT, 'latest', `${phase}.json`);
}

async function readJsonFile(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function collectSiblingReceiptIds(repoRoot, headSha, excludedPhase) {
  const latestRoot = path.join(repoRoot, DEFAULT_LOCAL_COLLAB_LEDGER_ROOT, 'latest');
  if (!existsSync(latestRoot)) {
    return [];
  }

  const entries = await readdir(latestRoot, { withFileTypes: true });
  const receiptIds = [];
  for (const entry of entries) {
    if (!entry.isFile() || path.extname(entry.name) !== '.json') {
      continue;
    }

    const phase = normalizeText(path.basename(entry.name, '.json'));
    if (!phase || phase === normalizeText(excludedPhase)) {
      continue;
    }

    try {
      const index = await readJsonFile(path.join(latestRoot, entry.name));
      if (normalizeText(index?.headSha) === headSha) {
        const receiptId = normalizeText(index?.receiptId);
        if (receiptId) {
          receiptIds.push(receiptId);
        }
      }
    } catch {
      // Corrupt sibling indexes should not prevent writing the current receipt.
    }
  }

  return uniqueStrings(receiptIds);
}

export async function writeLocalCollaborationLedgerReceipt(options = {}) {
  const repoRoot = path.resolve(normalizeText(options.repoRoot) || process.cwd());
  const phase = normalizeText(options.phase);
  if (!phase) {
    throw new Error('phase is required to write a local collaboration ledger receipt.');
  }

  const git = options.git && typeof options.git === 'object' ? options.git : resolveGitContext(repoRoot);
  const headSha = normalizeText(git.headSha);
  const baseSha = normalizeText(git.baseSha) || headSha;
  if (!headSha) {
    throw new Error('headSha is required to write a local collaboration ledger receipt.');
  }

  const providers = uniqueStrings(options.providers);
  const providerId = normalizeText(options.providerId) || deriveProviderId(providers);
  const receiptId = normalizeText(options.receiptId) || `${phase}:${headSha}`;
  const receiptPath = path.resolve(
    repoRoot,
    normalizeText(options.receiptPath) || defaultLedgerReceiptPath(repoRoot, phase, headSha)
  );
  const latestIndexPath = path.resolve(
    repoRoot,
    normalizeText(options.latestIndexPath) || defaultLedgerLatestIndexPath(repoRoot, phase)
  );

  await mkdir(path.dirname(receiptPath), { recursive: true });
  await mkdir(path.dirname(latestIndexPath), { recursive: true });

  const siblingReceiptIds = await collectSiblingReceiptIds(repoRoot, headSha, phase);
  const receipt = {
    schema: LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA,
    receiptId,
    phase,
    repoRoot,
    forkPlane: normalizeText(options.forkPlane) || null,
    persona: normalizeText(options.persona) || null,
    headSha,
    baseSha,
    providerId,
    providers,
    requestedModel: normalizeText(options.requestedModel) || null,
    effectiveModel: normalizeText(options.effectiveModel) || null,
    startedAt: normalizeText(options.startedAt) || null,
    finishedAt: normalizeText(options.finishedAt) || null,
    durationMs: normalizeInteger(options.durationMs),
    findingCount: normalizeInteger(options.findingCount),
    status: normalizeText(options.status) || null,
    outcome: normalizeText(options.outcome) || null,
    filesTouched: uniqueStrings(options.filesTouched),
    commitCreated: options.commitCreated === true,
    selectionSource: normalizeText(options.selectionSource) || null,
    sourceReceiptIds: uniqueStrings([...(options.sourceReceiptIds ?? []), ...siblingReceiptIds]),
    sourcePaths: uniqueStrings(options.sourcePaths),
    metadata: options.metadata && typeof options.metadata === 'object' ? options.metadata : {}
  };

  const latestIndex = {
    schema: LOCAL_COLLAB_LEDGER_LATEST_SCHEMA,
    phase,
    updatedAt: receipt.finishedAt || receipt.startedAt || new Date().toISOString(),
    headSha,
    receiptId,
    receiptPath: normalizePathForReceipt(repoRoot, receiptPath),
    status: receipt.status,
    outcome: receipt.outcome
  };

  await writeFile(receiptPath, JSON.stringify(receipt, null, 2), 'utf8');
  await writeFile(latestIndexPath, JSON.stringify(latestIndex, null, 2), 'utf8');

  return {
    git: { headSha, baseSha },
    receipt,
    receiptPath,
    latestIndex,
    latestIndexPath
  };
}

export async function assessLatestLocalCollaborationLedgerReceipt(options = {}) {
  const repoRoot = path.resolve(normalizeText(options.repoRoot) || process.cwd());
  const phase = normalizeText(options.phase);
  const expectedHeadSha = normalizeText(options.expectedHeadSha);
  const latestIndexPath = path.resolve(
    repoRoot,
    normalizeText(options.latestIndexPath) || defaultLedgerLatestIndexPath(repoRoot, phase)
  );

  if (!existsSync(latestIndexPath)) {
    return {
      ok: false,
      status: 'missing-index',
      reason: `No latest local collaboration ledger index exists for phase '${phase}'.`,
      latestIndexPath,
      receipt: null,
      receiptPath: null
    };
  }

  let latestIndex;
  try {
    latestIndex = await readJsonFile(latestIndexPath);
  } catch (error) {
    return {
      ok: false,
      status: 'invalid-index',
      reason: normalizeText(error?.message) || 'Latest local collaboration ledger index is not valid JSON.',
      latestIndexPath,
      receipt: null,
      receiptPath: null
    };
  }

  if (
    normalizeText(latestIndex?.schema) !== LOCAL_COLLAB_LEDGER_LATEST_SCHEMA ||
    normalizeText(latestIndex?.phase) !== phase ||
    !normalizeText(latestIndex?.receiptId) ||
    !normalizeText(latestIndex?.receiptPath) ||
    !normalizeText(latestIndex?.headSha)
  ) {
    return {
      ok: false,
      status: 'invalid-index',
      reason: 'Latest local collaboration ledger index is missing required fields.',
      latestIndexPath,
      receipt: null,
      receiptPath: null
    };
  }

  const receiptPath = path.resolve(repoRoot, latestIndex.receiptPath);
  try {
    normalizePathForReceipt(repoRoot, receiptPath);
  } catch (error) {
    return {
      ok: false,
      status: 'invalid-index',
      reason: normalizeText(error?.message) || 'Latest local collaboration ledger receipt path escapes the repo root.',
      latestIndexPath,
      receipt: null,
      receiptPath: null
    };
  }

  if (!existsSync(receiptPath)) {
    return {
      ok: false,
      status: 'missing-receipt',
      reason: 'Latest local collaboration ledger receipt file is missing.',
      latestIndexPath,
      receipt: null,
      receiptPath
    };
  }

  let receipt;
  try {
    receipt = await readJsonFile(receiptPath);
  } catch (error) {
    return {
      ok: false,
      status: 'invalid-receipt',
      reason: normalizeText(error?.message) || 'Local collaboration ledger receipt is not valid JSON.',
      latestIndexPath,
      receipt: null,
      receiptPath
    };
  }

  if (
    normalizeText(receipt?.schema) !== LOCAL_COLLAB_LEDGER_RECEIPT_SCHEMA ||
    normalizeText(receipt?.phase) !== phase ||
    normalizeText(receipt?.receiptId) !== normalizeText(latestIndex.receiptId) ||
    normalizeText(receipt?.headSha) !== normalizeText(latestIndex.headSha)
  ) {
    return {
      ok: false,
      status: 'invalid-receipt',
      reason: 'Local collaboration ledger receipt does not match the latest index contract.',
      latestIndexPath,
      receipt,
      receiptPath
    };
  }

  if (expectedHeadSha && normalizeText(receipt?.headSha) !== expectedHeadSha) {
    return {
      ok: false,
      status: 'stale',
      reason: `Latest local collaboration ledger receipt is stale for phase '${phase}'.`,
      latestIndexPath,
      receipt,
      receiptPath
    };
  }

  return {
    ok: true,
    status: 'valid',
    reason: `Latest local collaboration ledger receipt is valid for phase '${phase}'.`,
    latestIndexPath,
    receipt,
    receiptPath
  };
}
