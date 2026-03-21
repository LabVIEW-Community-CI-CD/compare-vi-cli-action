#!/usr/bin/env node

import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createSanitizedNpmEnv } from '../npm/sanitize-env.mjs';
import { createNpmLaunchSpec } from '../npm/spawn.mjs';

export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'security', 'dependency-audit-report.json');
export const DEFAULT_RAW_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'security', 'npm-audit.json');
export const DEFAULT_MODE = 'observe';
export const DEFAULT_REPO_ROOT = '.';
export const DEFAULT_THRESHOLDS = Object.freeze({
  total: 0,
  critical: 0,
  high: 0,
  moderate: 0,
});

const HELP = [
  'Usage: node tools/priority/dependency-audit.mjs [options]',
  '',
  'Options:',
  `  --repo-root <path>               (default: ${DEFAULT_REPO_ROOT})`,
  `  --output <path>                  (default: ${DEFAULT_OUTPUT_PATH})`,
  `  --raw-output <path>              (default: ${DEFAULT_RAW_OUTPUT_PATH})`,
  `  --mode observe|enforce           (default: ${DEFAULT_MODE})`,
  `  --threshold-total <n>            (default: ${DEFAULT_THRESHOLDS.total})`,
  `  --threshold-critical <n>         (default: ${DEFAULT_THRESHOLDS.critical})`,
  `  --threshold-high <n>             (default: ${DEFAULT_THRESHOLDS.high})`,
  `  --threshold-moderate <n>         (default: ${DEFAULT_THRESHOLDS.moderate})`,
  '  --help, -h',
  '',
  'Observe mode always writes the receipt and returns exit code 0 even when vulnerabilities or audit transport',
  'errors are present. Enforce mode fails closed on both breaches and execution errors.',
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
  return normalized.length > 0 ? normalized : null;
}

function parseNonNegativeInteger(value, flag) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`Invalid value for ${flag}: ${value}`);
  }
  return parsed;
}

function normalizeMode(value) {
  const normalized = asOptional(value)?.toLowerCase() ?? DEFAULT_MODE;
  if (!['observe', 'enforce'].includes(normalized)) {
    throw new Error(`Invalid --mode '${value}'. Expected observe or enforce.`);
  }
  return normalized;
}

function compareSeverity(left, right) {
  const ranking = new Map([
    ['critical', 0],
    ['high', 1],
    ['moderate', 2],
    ['low', 3],
    ['info', 4],
    ['unknown', 5],
  ]);
  return (ranking.get(left) ?? 99) - (ranking.get(right) ?? 99);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: DEFAULT_REPO_ROOT,
    outputPath: DEFAULT_OUTPUT_PATH,
    rawOutputPath: DEFAULT_RAW_OUTPUT_PATH,
    mode: DEFAULT_MODE,
    thresholds: { ...DEFAULT_THRESHOLDS },
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (
      token === '--repo-root' ||
      token === '--output' ||
      token === '--raw-output' ||
      token === '--mode' ||
      token === '--threshold-total' ||
      token === '--threshold-critical' ||
      token === '--threshold-high' ||
      token === '--threshold-moderate'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--raw-output') options.rawOutputPath = next;
      if (token === '--mode') options.mode = normalizeMode(next);
      if (token === '--threshold-total') options.thresholds.total = parseNonNegativeInteger(next, token);
      if (token === '--threshold-critical') options.thresholds.critical = parseNonNegativeInteger(next, token);
      if (token === '--threshold-high') options.thresholds.high = parseNonNegativeInteger(next, token);
      if (token === '--threshold-moderate') options.thresholds.moderate = parseNonNegativeInteger(next, token);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function normalizeRelativePath(filePath) {
  return filePath.split(path.sep).join('/');
}

async function readOptionalText(filePath, readFileFn = fs.readFile) {
  try {
    const content = await readFileFn(filePath, 'utf8');
    return {
      exists: true,
      content,
    };
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') {
      return {
        exists: false,
        content: null,
      };
    }
    throw error;
  }
}

function sha256Text(content) {
  return crypto.createHash('sha256').update(content, 'utf8').digest('hex');
}

export async function collectPackageState(
  {
    repoRoot = process.cwd(),
  } = {},
  {
    readFileFn = fs.readFile,
    nodeVersion = process.version,
  } = {},
) {
  const resolvedRepoRoot = path.resolve(repoRoot);
  const packageJsonPath = path.join(resolvedRepoRoot, 'package.json');
  const packageLockPath = path.join(resolvedRepoRoot, 'package-lock.json');

  const packageJson = await readOptionalText(packageJsonPath, readFileFn);
  const packageLock = await readOptionalText(packageLockPath, readFileFn);

  let packageJsonPayload = null;
  let packageLockPayload = null;
  if (packageJson.content) {
    packageJsonPayload = JSON.parse(packageJson.content);
  }
  if (packageLock.content) {
    packageLockPayload = JSON.parse(packageLock.content);
  }

  const packageStateFingerprintInput = {
    nodeVersion,
    packageName: asOptional(packageJsonPayload?.name),
    packageVersion: asOptional(packageJsonPayload?.version),
    packageJsonSha256: packageJson.content ? sha256Text(packageJson.content) : null,
    packageLockSha256: packageLock.content ? sha256Text(packageLock.content) : null,
    packageLockVersion:
      typeof packageLockPayload?.lockfileVersion === 'number'
        ? packageLockPayload.lockfileVersion
        : null,
  };

  return {
    nodeVersion,
    packageJson: {
      path: normalizeRelativePath(path.relative(resolvedRepoRoot, packageJsonPath) || 'package.json'),
      exists: packageJson.exists,
      sha256: packageStateFingerprintInput.packageJsonSha256,
      packageName: packageStateFingerprintInput.packageName,
      packageVersion: packageStateFingerprintInput.packageVersion,
    },
    packageLock: {
      path: normalizeRelativePath(path.relative(resolvedRepoRoot, packageLockPath) || 'package-lock.json'),
      exists: packageLock.exists,
      sha256: packageStateFingerprintInput.packageLockSha256,
      lockfileVersion: packageStateFingerprintInput.packageLockVersion,
    },
    fingerprintSha256: crypto
      .createHash('sha256')
      .update(JSON.stringify(packageStateFingerprintInput))
      .digest('hex'),
  };
}

function normalizeSeverity(value) {
  const normalized = asOptional(value)?.toLowerCase();
  if (!normalized) {
    return 'unknown';
  }
  if (normalized === 'medium') {
    return 'moderate';
  }
  return ['critical', 'high', 'moderate', 'low', 'info'].includes(normalized) ? normalized : 'unknown';
}

function normalizeFixAvailable(value) {
  if (typeof value === 'boolean') {
    return {
      available: value,
      target: null,
      isSemVerMajor: false,
    };
  }

  if (value && typeof value === 'object') {
    return {
      available: true,
      target: asOptional(value.name) ?? asOptional(value.version),
      isSemVerMajor: value.isSemVerMajor === true,
    };
  }

  return {
    available: false,
    target: null,
    isSemVerMajor: false,
  };
}

function normalizeViaEntries(via) {
  if (!Array.isArray(via)) {
    return [];
  }

  return via
    .map((entry) => {
      if (typeof entry === 'string') {
        return {
          source: entry,
          severity: 'unknown',
        };
      }
      return {
        source: asOptional(entry?.source) ?? asOptional(entry?.name),
        severity: normalizeSeverity(entry?.severity),
      };
    })
    .filter((entry) => Boolean(entry.source));
}

export function summarizeAuditPayload(payload, thresholds = DEFAULT_THRESHOLDS) {
  const metadata = payload?.metadata ?? {};
  const vulnerabilityMetadata = metadata?.vulnerabilities ?? {};
  const dependencyMetadata = metadata?.dependencies ?? {};
  const vulnerabilities = payload?.vulnerabilities ?? {};

  const summary = {
    total: Number(vulnerabilityMetadata.total ?? 0),
    critical: Number(vulnerabilityMetadata.critical ?? 0),
    high: Number(vulnerabilityMetadata.high ?? 0),
    moderate: Number(vulnerabilityMetadata.moderate ?? 0),
    low: Number(vulnerabilityMetadata.low ?? 0),
    info: Number(vulnerabilityMetadata.info ?? 0),
    dependencyCounts: {
      prod: Number(dependencyMetadata.prod ?? 0),
      dev: Number(dependencyMetadata.dev ?? 0),
      optional: Number(dependencyMetadata.optional ?? 0),
      peer: Number(dependencyMetadata.peer ?? 0),
      peerOptional: Number(dependencyMetadata.peerOptional ?? 0),
      total: Number(dependencyMetadata.total ?? 0),
    },
  };

  const packages = Object.entries(vulnerabilities)
    .map(([name, entry]) => {
      const fix = normalizeFixAvailable(entry?.fixAvailable);
      const via = normalizeViaEntries(entry?.via);
      return {
        name,
        severity: normalizeSeverity(entry?.severity),
        direct: entry?.isDirect === true,
        range: asOptional(entry?.range),
        fixAvailable: fix.available,
        fixTarget: fix.target,
        fixSemVerMajor: fix.isSemVerMajor,
        viaCount: via.length,
        via,
        nodeCount: Array.isArray(entry?.nodes) ? entry.nodes.length : 0,
      };
    })
    .sort((left, right) => {
      const severityDelta = compareSeverity(left.severity, right.severity);
      if (severityDelta !== 0) {
        return severityDelta;
      }
      return left.name.localeCompare(right.name);
    });

  const breaches = [
    { key: 'total', count: summary.total, threshold: thresholds.total },
    { key: 'critical', count: summary.critical, threshold: thresholds.critical },
    { key: 'high', count: summary.high, threshold: thresholds.high },
    { key: 'moderate', count: summary.moderate, threshold: thresholds.moderate },
  ].filter((entry) => entry.count > entry.threshold);

  return {
    summary,
    packages,
    breaches,
  };
}

async function writeTextFile(filePath, content, writeFileFn = fs.writeFile, mkdirFn = fs.mkdir) {
  const resolved = path.resolve(process.cwd(), filePath);
  await mkdirFn(path.dirname(resolved), { recursive: true });
  await writeFileFn(resolved, content, 'utf8');
  return resolved;
}

export async function runSanitizedNpmAudit({
  spawnFn = spawn,
  env = process.env,
  platform = process.platform,
  nodeExecPath = process.execPath,
} = {}) {
  const sanitizedEnv = createSanitizedNpmEnv(env);
  const launchSpec = createNpmLaunchSpec(['audit', '--json'], sanitizedEnv, platform, nodeExecPath);
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let settled = false;

    const child = spawnFn(launchSpec.command, launchSpec.args, {
      env: sanitizedEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (error) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve({
        command: launchSpec.command,
        args: launchSpec.args,
        stdout,
        stderr,
        exitCode: -1,
        error: error instanceof Error ? error.message : String(error),
      });
    });
    child.on('close', (code, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve({
        command: launchSpec.command,
        args: launchSpec.args,
        stdout,
        stderr,
        exitCode: typeof code === 'number' ? code : signal ? 128 : -1,
        error: signal ? `npm audit terminated by signal ${signal}` : null,
      });
    });
  });
}

export async function runDependencyAudit(
  options,
  {
    now = new Date(),
    runAuditCommandFn = runSanitizedNpmAudit,
    writeFileFn = fs.writeFile,
    mkdirFn = fs.mkdir,
    readFileFn = fs.readFile,
    log = console.log,
    error = console.error,
  } = {},
) {
  const packageState = await collectPackageState(
    {
      repoRoot: options.repoRoot,
    },
    {
      readFileFn,
    },
  );
  const auditExecution = await runAuditCommandFn();
  const rawAuditPath = await writeTextFile(options.rawOutputPath, auditExecution.stdout || '', writeFileFn, mkdirFn);

  let auditPayload = null;
  let parseError = null;
  if (asOptional(auditExecution.stdout)) {
    try {
      auditPayload = JSON.parse(auditExecution.stdout);
    } catch (err) {
      parseError = err instanceof Error ? err.message : String(err);
    }
  } else {
    parseError = 'npm audit produced no JSON payload on stdout.';
  }

  const executionErrors = [];
  if (auditExecution.error) {
    executionErrors.push(auditExecution.error);
  }
  if (parseError) {
    executionErrors.push(`Unable to parse npm audit JSON: ${parseError}`);
  }

  let summary = {
    total: 0,
    critical: 0,
    high: 0,
    moderate: 0,
    low: 0,
    info: 0,
    dependencyCounts: {
      prod: 0,
      dev: 0,
      optional: 0,
      peer: 0,
      peerOptional: 0,
      total: 0,
    },
  };
  let packages = [];
  let breaches = [];

  if (auditPayload && executionErrors.length === 0) {
    const summarized = summarizeAuditPayload(auditPayload, options.thresholds);
    summary = summarized.summary;
    packages = summarized.packages;
    breaches = summarized.breaches;
  }

  let result = 'pass';
  let exitCode = 0;
  if (executionErrors.length > 0) {
    result = 'error';
    exitCode = options.mode === 'enforce' ? 1 : 0;
  } else if (breaches.length > 0) {
    result = options.mode === 'enforce' ? 'fail' : 'warn';
    exitCode = options.mode === 'enforce' ? 1 : 0;
  }

  const report = {
    schema: 'priority/dependency-audit@v1',
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    mode: options.mode,
    result,
    command: {
      command: auditExecution.command,
      args: auditExecution.args,
      sanitizedNpmEnv: true,
      rawOutputPath: rawAuditPath,
    },
    execution: {
      npmExitCode: auditExecution.exitCode,
      stderr: asOptional(auditExecution.stderr),
      jsonParsed: executionErrors.length === 0,
    },
    packageState: {
      nodeVersion: packageState.nodeVersion,
      packageJson: packageState.packageJson,
      packageLock: packageState.packageLock,
      fingerprintSha256: packageState.fingerprintSha256,
    },
    thresholds: options.thresholds,
    summary,
    packages,
    breaches,
    errors: executionErrors,
  };

  const reportPath = await writeTextFile(
    options.outputPath,
    `${JSON.stringify(report, null, 2)}\n`,
    writeFileFn,
    mkdirFn,
  );

  log(`[dependency-audit] report: ${reportPath}`);
  log(`[dependency-audit] raw: ${rawAuditPath}`);
  log(`[dependency-audit] fingerprint=${packageState.fingerprintSha256}`);
  if (result === 'pass') {
    log('[dependency-audit] result=pass');
  } else if (result === 'warn') {
    log(`[dependency-audit] result=warn breaches=${breaches.map((entry) => `${entry.key}:${entry.count}>${entry.threshold}`).join(',')}`);
  } else if (result === 'fail') {
    error(`[dependency-audit] result=fail breaches=${breaches.map((entry) => `${entry.key}:${entry.count}>${entry.threshold}`).join(',')}`);
  } else {
    error(`[dependency-audit] result=error errors=${executionErrors.join('; ')}`);
  }

  return {
    exitCode,
    report,
    reportPath,
    rawAuditPath,
  };
}

const isDirectRun = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectRun) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printHelp();
      process.exit(0);
    }
    const result = await runDependencyAudit(options);
    process.exit(result.exitCode);
  } catch (runError) {
    const message = runError instanceof Error ? runError.message : String(runError);
    console.error(`[dependency-audit] ${message}`);
    process.exit(1);
  }
}
