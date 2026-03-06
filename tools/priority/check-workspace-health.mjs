#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { evaluateWorkspaceHealth } from './lib/workspace-health.mjs';

const DEFAULT_REPORT_PATH = path.join(
  process.cwd(),
  'tests',
  'results',
  '_agent',
  'health',
  'workspace-health-report.json'
);

function printUsage() {
  console.log(`Usage:
  node tools/priority/check-workspace-health.mjs [options]

Options:
  --repo-root <path>         Repository root to evaluate (default: current working directory)
  --report <path>            JSON report output path
  --lock-stale-seconds <n>   Lock stale threshold in seconds (default: 30)
  --lease-mode <mode>        Lease validation mode: ignore|optional|required (default: optional)
  --expected-owner <value>   Expected lease owner (default: computed current owner)
  --expected-lease-id <id>   Expected lease id (default: AGENT_WRITER_LEASE_ID)
  --lease-root <path>        Lease directory override (relative to repo root allowed)
  --quiet                    Suppress JSON report echo
  --help                     Show this help text
`);
}

export function parseArgs(argv = process.argv.slice(2)) {
  const parsed = {
    repoRoot: process.cwd(),
    report: DEFAULT_REPORT_PATH,
    lockStaleSeconds: 30,
    leaseMode: 'optional',
    expectedLeaseOwner: process.env.AGENT_WRITER_LEASE_OWNER ?? '',
    expectedLeaseId: process.env.AGENT_WRITER_LEASE_ID ?? '',
    leaseRoot: '',
    quiet: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--help' || token === '-h') {
      parsed.help = true;
      continue;
    }
    if (token === '--quiet') {
      parsed.quiet = true;
      continue;
    }

    const next = argv[index + 1];
    if (!next) {
      throw new Error(`Missing value for ${token}`);
    }

    if (token === '--repo-root') {
      parsed.repoRoot = path.resolve(next);
      index += 1;
      continue;
    }
    if (token === '--report') {
      parsed.report = path.resolve(next);
      index += 1;
      continue;
    }
    if (token === '--lock-stale-seconds') {
      const value = Number.parseInt(next, 10);
      if (!Number.isFinite(value) || value < 0) {
        throw new Error(`Invalid --lock-stale-seconds value: ${next}`);
      }
      parsed.lockStaleSeconds = value;
      index += 1;
      continue;
    }
    if (token === '--lease-mode') {
      parsed.leaseMode = String(next).trim().toLowerCase();
      index += 1;
      continue;
    }
    if (token === '--expected-owner') {
      parsed.expectedLeaseOwner = next;
      index += 1;
      continue;
    }
    if (token === '--expected-lease-id') {
      parsed.expectedLeaseId = next;
      index += 1;
      continue;
    }
    if (token === '--lease-root') {
      parsed.leaseRoot = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${token}`);
  }

  return parsed;
}

async function writeReport(reportPath, payload) {
  await fs.mkdir(path.dirname(reportPath), { recursive: true });
  await fs.writeFile(reportPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function printFailureSummary(report) {
  console.error(`[workspace-health] FAIL (${report.failures.length} violation(s))`);
  for (const failure of report.failures) {
    const metadata = [];
    if (failure.path) metadata.push(`path=${failure.path}`);
    if (failure.expectedOwner) metadata.push(`expectedOwner=${failure.expectedOwner}`);
    if (failure.actualOwner) metadata.push(`actualOwner=${failure.actualOwner}`);
    if (failure.message) metadata.push(`message=${failure.message}`);
    if (failure.states) {
      metadata.push(`states=${failure.states.map((entry) => entry.description).join(',')}`);
    }
    if (failure.locks) {
      metadata.push(`locks=${failure.locks.map((entry) => path.basename(entry.path)).join(',')}`);
    }
    const suffix = metadata.length > 0 ? ` (${metadata.join('; ')})` : '';
    console.error(`  - ${failure.id}${suffix}`);
  }
  for (const hint of report.hints) {
    console.error(`  hint: ${hint}`);
  }
}

export async function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const report = evaluateWorkspaceHealth({
    repoRoot: args.repoRoot,
    lockStaleSeconds: args.lockStaleSeconds,
    leaseMode: args.leaseMode,
    expectedLeaseOwner: args.expectedLeaseOwner || undefined,
    expectedLeaseId: args.expectedLeaseId || undefined,
    leaseRoot: args.leaseRoot || undefined
  });

  await writeReport(args.report, report);

  if (!args.quiet) {
    console.log(`[workspace-health] report: ${args.report}`);
  }

  if (report.status === 'pass') {
    console.log(`[workspace-health] PASS (checks=${report.checks.length})`);
    return 0;
  }

  printFailureSummary(report);
  return 1;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli();
    process.exit(exitCode);
  } catch (error) {
    console.error(`[workspace-health] ${error?.message || error}`);
    process.exit(1);
  }
}
