#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const LEDGER_SCHEMA = 'ops-decision-ledger@v1';
export const REPLAY_SCHEMA = 'ops-decision-replay@v1';
export const DEFAULT_LEDGER_PATH = path.join('tests', 'results', '_agent', 'ops', 'ops-decision-ledger.json');
export const DEFAULT_REPLAY_PATH = path.join('tests', 'results', '_agent', 'ops', 'ops-decision-replay.json');

const SENSITIVE_KEY_PATTERN = /(token|secret|authorization|password|apikey|api_key|privatekey|private_key)/i;
const SENSITIVE_VALUE_PATTERN = /(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|bearer\s+[a-z0-9\-_\.]+)/i;

function printUsage() {
  console.log('Usage: node tools/priority/decision-ledger.mjs <append|replay> [options]');
  console.log('');
  console.log('Commands:');
  console.log('  append   Append a redacted decision report entry to the ledger.');
  console.log('  replay   Reconstruct decision artifacts from ledger entries.');
  console.log('');
  console.log('Options (append):');
  console.log(`  --decision <path>   Decision report input (required).`);
  console.log(`  --ledger <path>     Ledger path (default: ${DEFAULT_LEDGER_PATH}).`);
  console.log('  --source <text>     Source label for the ledger entry (default: manual).');
  console.log('');
  console.log('Options (replay):');
  console.log(`  --ledger <path>      Ledger path (default: ${DEFAULT_LEDGER_PATH}).`);
  console.log(`  --output <path>      Replay output path (default: ${DEFAULT_REPLAY_PATH}).`);
  console.log('  --sequence <n>       Replay a specific sequence (default: all entries).');
  console.log('  --fingerprint <id>   Replay entries by event fingerprint.');
  console.log('');
  console.log('General:');
  console.log('  -h, --help           Show help and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function parsePositiveInteger(value, { label }) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`Invalid value for ${label}: ${value}`);
  }
  return parsed;
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

function computeDigest(value) {
  const hash = createHash('sha256');
  hash.update(JSON.stringify(stableSortValue(value)));
  return hash.digest('hex');
}

function redactString(value) {
  if (!SENSITIVE_VALUE_PATTERN.test(value)) {
    return value;
  }
  return '[REDACTED]';
}

export function redactSensitiveFields(value, contextKey = null) {
  if (Array.isArray(value)) {
    return value.map((entry) => redactSensitiveFields(entry, contextKey));
  }

  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const output = {};
    for (const [key, child] of Object.entries(value)) {
      if (SENSITIVE_KEY_PATTERN.test(key)) {
        output[key] = '[REDACTED]';
        continue;
      }
      output[key] = redactSensitiveFields(child, key);
    }
    return output;
  }

  if (typeof value === 'string') {
    if (contextKey && SENSITIVE_KEY_PATTERN.test(contextKey)) {
      return '[REDACTED]';
    }
    return redactString(value);
  }

  return value;
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    command: null,
    decisionPath: null,
    ledgerPath: DEFAULT_LEDGER_PATH,
    outputPath: DEFAULT_REPLAY_PATH,
    source: 'manual',
    sequence: null,
    fingerprint: null,
    help: false
  };

  if (args.length === 0) {
    throw new Error('Command is required (append|replay).');
  }

  const command = args[0].trim().toLowerCase();
  if (!['append', 'replay'].includes(command)) {
    if (command === '--help' || command === '-h') {
      options.help = true;
      return options;
    }
    throw new Error(`Unknown command: ${args[0]}`);
  }
  options.command = command;

  for (let index = 1; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (
      token === '--decision' ||
      token === '--ledger' ||
      token === '--output' ||
      token === '--source' ||
      token === '--sequence' ||
      token === '--fingerprint'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--decision') options.decisionPath = next;
      if (token === '--ledger') options.ledgerPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--source') options.source = next;
      if (token === '--sequence') options.sequence = parsePositiveInteger(next, { label: '--sequence' });
      if (token === '--fingerprint') options.fingerprint = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.command === 'append' && !normalizeText(options.decisionPath)) {
    throw new Error('--decision is required for append.');
  }

  return options;
}

async function readJsonFile(filePath) {
  const resolved = path.resolve(filePath);
  if (!existsSync(resolved)) {
    throw new Error(`File not found: ${resolved}`);
  }
  const raw = await readFile(resolved, 'utf8');
  return JSON.parse(raw);
}

async function readLedger(filePath) {
  const resolved = path.resolve(filePath);
  if (!existsSync(resolved)) {
    return {
      schema: LEDGER_SCHEMA,
      generatedAt: null,
      entryCount: 0,
      entries: []
    };
  }

  const payload = JSON.parse(await readFile(resolved, 'utf8'));
  if (payload?.schema !== LEDGER_SCHEMA || !Array.isArray(payload?.entries)) {
    throw new Error(`Invalid ledger format at ${resolved}`);
  }
  return payload;
}

async function writeJsonFile(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function appendDecisionLedgerEntry({
  decisionPath,
  ledgerPath = DEFAULT_LEDGER_PATH,
  source = 'manual',
  now = new Date(),
  readDecisionFn = readJsonFile,
  readLedgerFn = readLedger,
  writeJsonFn = writeJsonFile
} = {}) {
  const decision = await readDecisionFn(decisionPath);
  const redactedDecision = redactSensitiveFields(decision);
  const ledger = await readLedgerFn(ledgerPath);
  const previousEntries = Array.isArray(ledger.entries) ? [...ledger.entries] : [];
  const nextSequence = previousEntries.length + 1;

  const entry = {
    sequence: nextSequence,
    appendedAt: now.toISOString(),
    source: normalizeText(source) ?? 'manual',
    decisionDigest: computeDigest(redactedDecision),
    decision: redactedDecision,
    fingerprint: normalizeText(redactedDecision?.event?.fingerprint) ?? null
  };

  const nextLedger = {
    schema: LEDGER_SCHEMA,
    generatedAt: now.toISOString(),
    entryCount: previousEntries.length + 1,
    entries: [...previousEntries, entry]
  };

  const resolvedLedgerPath = await writeJsonFn(ledgerPath, nextLedger);
  return {
    ledger: nextLedger,
    ledgerPath: resolvedLedgerPath,
    entry
  };
}

export function replayDecisionLedger(ledger, options = {}) {
  const sequence = options.sequence ?? null;
  const fingerprint = normalizeText(options.fingerprint);
  const entries = Array.isArray(ledger?.entries) ? ledger.entries : [];

  const selected = entries.filter((entry) => {
    if (sequence != null && entry.sequence !== sequence) {
      return false;
    }
    if (fingerprint && entry.fingerprint !== fingerprint) {
      return false;
    }
    return true;
  });

  return {
    schema: REPLAY_SCHEMA,
    generatedAt: new Date(options.now ?? Date.now()).toISOString(),
    sourceSchema: ledger?.schema ?? null,
    selection: {
      sequence: sequence ?? null,
      fingerprint: fingerprint ?? null
    },
    count: selected.length,
    decisions: selected.map((entry) => ({
      sequence: entry.sequence,
      fingerprint: entry.fingerprint,
      decisionDigest: entry.decisionDigest,
      decision: entry.decision
    }))
  };
}

export async function runDecisionLedger(options = {}) {
  const args = options.args ?? parseArgs(options.argv ?? process.argv);
  if (args.help) {
    printUsage();
    return { exitCode: 0, mode: null, outputPath: null, payload: null };
  }

  if (args.command === 'append') {
    const appended = await appendDecisionLedgerEntry({
      decisionPath: args.decisionPath,
      ledgerPath: args.ledgerPath,
      source: args.source,
      now: options.now ?? new Date(),
      readDecisionFn: options.readDecisionFn ?? readJsonFile,
      readLedgerFn: options.readLedgerFn ?? readLedger,
      writeJsonFn: options.writeJsonFn ?? writeJsonFile
    });

    return {
      exitCode: 0,
      mode: 'append',
      outputPath: appended.ledgerPath,
      payload: appended.ledger
    };
  }

  const ledger = await (options.readLedgerFn ?? readLedger)(args.ledgerPath);
  const replay = replayDecisionLedger(ledger, {
    now: options.now ?? new Date(),
    sequence: args.sequence,
    fingerprint: args.fingerprint
  });
  const outputPath = await (options.writeJsonFn ?? writeJsonFile)(args.outputPath, replay);

  return {
    exitCode: 0,
    mode: 'replay',
    outputPath,
    payload: replay
  };
}

export async function main(argv = process.argv) {
  const result = await runDecisionLedger({ argv });
  if (result.mode === 'append') {
    console.log(`[ops-decision-ledger] appended: ${result.outputPath}`);
  } else if (result.mode === 'replay') {
    console.log(`[ops-decision-ledger] replay: ${result.outputPath}`);
  }
  return result.exitCode;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) {
        process.exitCode = code;
      }
    })
    .catch((error) => {
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}
