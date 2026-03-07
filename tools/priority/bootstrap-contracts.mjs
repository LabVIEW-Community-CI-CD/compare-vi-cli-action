#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { run as runPolicyCheck } from './check-policy.mjs';
import { getRepoRoot } from './lib/branch-utils.mjs';

export const REPORT_SCHEMA = 'priority/bootstrap-contracts-report@v1';
export const LABEL_POLICY_SCHEMA = 'priority-bootstrap-labels@v1';
export const DEFAULT_LABEL_POLICY_PATH = path.join('tools', 'policy', 'priority-bootstrap-labels.json');
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'policy', 'bootstrap-contracts-report.json');
export const DEFAULT_POLICY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'policy',
  'bootstrap-contracts-policy-report.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/bootstrap-contracts.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>         Target repository slug (default: env/upstream/origin).');
  console.log(`  --labels-policy <path>      Label policy JSON (default: ${DEFAULT_LABEL_POLICY_PATH}).`);
  console.log(`  --report <path>             Bootstrap report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log(`  --policy-report <path>      Policy check report output path (default: ${DEFAULT_POLICY_REPORT_PATH}).`);
  console.log('  --dry-run                   Compute plan without mutating repository labels.');
  console.log('  --skip-policy               Skip policy check/apply execution.');
  console.log('  --apply-policy              Apply policy contract via check-policy --apply.');
  console.log('  --strict-policy             Fail command when policy check does not return pass.');
  console.log('  --policy-fail-on-skip       Pass --fail-on-skip to policy check.');
  console.log('  -h, --help                  Show help and exit.');
}

function normalizeText(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text ? text : null;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, rawRepo] = repoPath.split('/');
  if (!owner || !rawRepo) return null;
  const repo = rawRepo.replace(/\.git$/i, '');
  if (!repo) return null;
  return `${owner}/${repo}`;
}

function normalizeRepositorySlug(value) {
  const slug = normalizeText(value);
  if (!slug || !slug.includes('/')) {
    throw new Error(`Invalid repository slug '${value}'. Expected owner/repo.`);
  }
  const [owner, repo] = slug.split('/', 2);
  if (!owner || !repo) {
    throw new Error(`Invalid repository slug '${value}'. Expected owner/repo.`);
  }
  return `${owner}/${repo}`;
}

function readGitConfig(repoRoot) {
  const gitConfigPath = path.join(repoRoot, '.git', 'config');
  if (!fs.existsSync(gitConfigPath)) {
    return null;
  }
  return fs.readFileSync(gitConfigPath, 'utf8');
}

function readRemoteUrlFromConfig(configText, remoteName) {
  if (!configText) return null;
  const escapedRemote = remoteName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = configText.match(new RegExp(`\\[remote\\s+"${escapedRemote}"\\]([\\s\\S]*?)(?:\\n\\[|$)`, 'i'));
  const section = match?.[1];
  if (!section) return null;
  const urlMatch = section.match(/^\s*url\s*=\s*(.+)$/im);
  return urlMatch?.[1]?.trim() || null;
}

export function resolveRepositorySlug(repoRoot, explicitRepo, env = process.env) {
  if (explicitRepo) {
    return normalizeRepositorySlug(explicitRepo);
  }
  if (env.GITHUB_REPOSITORY && env.GITHUB_REPOSITORY.includes('/')) {
    return normalizeRepositorySlug(env.GITHUB_REPOSITORY);
  }
  const config = readGitConfig(repoRoot);
  for (const remoteName of ['upstream', 'origin']) {
    const parsed = parseRemoteUrl(readRemoteUrlFromConfig(config, remoteName));
    if (parsed) {
      return normalizeRepositorySlug(parsed);
    }
  }
  throw new Error('Unable to resolve repository slug. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    labelsPolicyPath: DEFAULT_LABEL_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    policyReportPath: DEFAULT_POLICY_REPORT_PATH,
    dryRun: false,
    skipPolicy: false,
    applyPolicy: false,
    strictPolicy: false,
    policyFailOnSkip: false,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--dry-run') {
      options.dryRun = true;
      continue;
    }
    if (token === '--skip-policy') {
      options.skipPolicy = true;
      continue;
    }
    if (token === '--apply-policy') {
      options.applyPolicy = true;
      continue;
    }
    if (token === '--strict-policy') {
      options.strictPolicy = true;
      continue;
    }
    if (token === '--policy-fail-on-skip') {
      options.policyFailOnSkip = true;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--labels-policy' ||
      token === '--report' ||
      token === '--policy-report'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeRepositorySlug(next);
      if (token === '--labels-policy') options.labelsPolicyPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--policy-report') options.policyReportPath = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function readJson(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`File not found: ${resolved}`);
  }
  try {
    return JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (error) {
    throw new Error(`Invalid JSON in ${resolved}: ${error.message}`);
  }
}

export function normalizeLabelPolicy(payload = {}) {
  if (payload?.schema !== LABEL_POLICY_SCHEMA) {
    throw new Error(`Invalid labels policy schema '${payload?.schema}'. Expected '${LABEL_POLICY_SCHEMA}'.`);
  }
  const labels = [];
  const seen = new Set();
  for (const entry of Array.isArray(payload.labels) ? payload.labels : []) {
    const name = normalizeText(entry?.name);
    if (!name) {
      throw new Error('Labels policy contains an entry with missing name.');
    }
    const nameKey = name.toLowerCase();
    if (seen.has(nameKey)) {
      throw new Error(`Labels policy contains duplicate label '${name}'.`);
    }
    seen.add(nameKey);
    const description = normalizeText(entry?.description) ?? '';
    const rawColor = normalizeText(entry?.color)?.replace(/^#/, '') ?? '';
    if (!/^[0-9a-fA-F]{6}$/.test(rawColor)) {
      throw new Error(`Label '${name}' has invalid color '${entry?.color}'.`);
    }
    labels.push({
      name,
      description,
      color: rawColor.toLowerCase()
    });
  }
  if (labels.length === 0) {
    throw new Error('Labels policy contains no labels.');
  }
  labels.sort((left, right) => left.name.localeCompare(right.name));
  return {
    schema: LABEL_POLICY_SCHEMA,
    schemaVersion: normalizeText(payload.schemaVersion) ?? '1.0.0',
    labels
  };
}

export function buildLabelPlan(desiredLabels, existingLabels) {
  const existingMap = new Map();
  for (const label of Array.isArray(existingLabels) ? existingLabels : []) {
    const name = normalizeText(label?.name);
    if (!name) continue;
    existingMap.set(name.toLowerCase(), {
      name,
      description: normalizeText(label?.description) ?? '',
      color: normalizeText(label?.color)?.replace(/^#/, '').toLowerCase() ?? ''
    });
  }

  const operations = [];
  for (const label of desiredLabels) {
    const existing = existingMap.get(label.name.toLowerCase());
    if (!existing) {
      operations.push({
        type: 'create',
        name: label.name,
        desired: label,
        current: null
      });
      continue;
    }
    const colorChanged = existing.color !== label.color;
    const descriptionChanged = existing.description !== label.description;
    if (colorChanged || descriptionChanged) {
      operations.push({
        type: 'update',
        name: label.name,
        currentName: existing.name,
        desired: label,
        current: existing
      });
      continue;
    }
    operations.push({
      type: 'noop',
      name: label.name,
      desired: label,
      current: existing
    });
  }
  return operations;
}

export function resolveToken(env = process.env) {
  for (const candidate of [env.GH_TOKEN, env.GITHUB_TOKEN]) {
    const token = normalizeText(candidate);
    if (token) return token;
  }
  const candidates = [env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    candidates.push('C:\\github_token.txt');
  }
  for (const candidate of candidates) {
    const tokenPath = normalizeText(candidate);
    if (!tokenPath || !fs.existsSync(tokenPath)) continue;
    const token = normalizeText(fs.readFileSync(tokenPath, 'utf8'));
    if (token) return token;
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN (or GH_TOKEN_FILE).');
}

async function requestGitHubJson(url, { token, method = 'GET', body = null, fetchFn = globalThis.fetch } = {}) {
  if (typeof fetchFn !== 'function') {
    throw new Error('Fetch API is unavailable.');
  }
  if (!token) {
    throw new Error('GitHub token is required.');
  }
  const response = await fetchFn(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'priority-bootstrap-contracts',
      'X-GitHub-Api-Version': '2022-11-28'
    },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!response.ok) {
    const error = new Error(`GitHub API ${method} ${url} failed (${response.status}).`);
    error.status = response.status;
    try {
      error.payload = await response.json();
    } catch {}
    throw error;
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function listRepositoryLabels(repository, token, fetchFn) {
  const endpoint = `https://api.github.com/repos/${repository}/labels?per_page=100`;
  const payload = await requestGitHubJson(endpoint, { token, fetchFn });
  return Array.isArray(payload) ? payload : [];
}

async function createRepositoryLabel(repository, token, label, fetchFn) {
  const endpoint = `https://api.github.com/repos/${repository}/labels`;
  return requestGitHubJson(endpoint, {
    token,
    method: 'POST',
    body: {
      name: label.name,
      description: label.description,
      color: label.color
    },
    fetchFn
  });
}

async function updateRepositoryLabel(repository, token, labelName, label, fetchFn) {
  const encodedName = encodeURIComponent(labelName);
  const endpoint = `https://api.github.com/repos/${repository}/labels/${encodedName}`;
  return requestGitHubJson(endpoint, {
    token,
    method: 'PATCH',
    body: {
      new_name: label.name,
      description: label.description,
      color: label.color
    },
    fetchFn
  });
}

export async function runBootstrapContracts({
  argv = process.argv,
  now = new Date(),
  repoRoot = getRepoRoot(),
  env = process.env,
  readJsonFn = readJson,
  writeJsonFn = writeJson,
  fetchFn = globalThis.fetch,
  resolveRepositorySlugFn = resolveRepositorySlug,
  resolveTokenFn = resolveToken,
  runPolicyCheckFn = runPolicyCheck
} = {}) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return { exitCode: 0, report: null, reportPath: null };
  }

  const repository = resolveRepositorySlugFn(repoRoot, args.repo, env);
  const labelsPolicyPath = path.resolve(repoRoot, args.labelsPolicyPath);
  const reportPath = path.resolve(repoRoot, args.reportPath);
  const policyReportPath = path.resolve(repoRoot, args.policyReportPath);
  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'fail',
    repository,
    flags: {
      dryRun: args.dryRun,
      skipPolicy: args.skipPolicy,
      applyPolicy: args.applyPolicy,
      strictPolicy: args.strictPolicy,
      policyFailOnSkip: args.policyFailOnSkip
    },
    inputs: {
      labelsPolicyPath,
      reportPath,
      policyReportPath
    },
    labels: {
      desiredCount: 0,
      existingCount: 0,
      createdCount: 0,
      updatedCount: 0,
      unchangedCount: 0
    },
    operations: [],
    policy: {
      executed: false,
      mode: args.applyPolicy ? 'apply' : 'verify',
      result: args.skipPolicy ? 'skipped' : 'unknown',
      exitCode: null,
      reportPath: policyReportPath
    },
    errors: []
  };

  try {
    const policy = normalizeLabelPolicy(readJsonFn(labelsPolicyPath));
    report.labels.desiredCount = policy.labels.length;

    let token = null;
    let existingLabels = [];
    if (!args.dryRun) {
      token = resolveTokenFn(env);
      existingLabels = await listRepositoryLabels(repository, token, fetchFn);
    }
    report.labels.existingCount = existingLabels.length;
    const plan = buildLabelPlan(policy.labels, existingLabels);

    for (const operation of plan) {
      if (operation.type === 'create') {
        if (!args.dryRun) {
          await createRepositoryLabel(repository, token, operation.desired, fetchFn);
          report.operations.push({
            type: 'label-create',
            name: operation.name,
            wrote: true
          });
        } else {
          report.operations.push({
            type: 'label-create',
            name: operation.name,
            wrote: false
          });
        }
        report.labels.createdCount += 1;
        continue;
      }

      if (operation.type === 'update') {
        if (!args.dryRun) {
          await updateRepositoryLabel(repository, token, operation.currentName, operation.desired, fetchFn);
          report.operations.push({
            type: 'label-update',
            name: operation.name,
            currentName: operation.currentName,
            wrote: true
          });
        } else {
          report.operations.push({
            type: 'label-update',
            name: operation.name,
            currentName: operation.currentName,
            wrote: false
          });
        }
        report.labels.updatedCount += 1;
        continue;
      }

      report.operations.push({
        type: 'label-noop',
        name: operation.name,
        wrote: false
      });
      report.labels.unchangedCount += 1;
    }

    if (!args.skipPolicy) {
      const policyArgv = ['node', 'check-policy.mjs', '--report', policyReportPath];
      if (args.applyPolicy) {
        policyArgv.push('--apply');
      }
      if (args.policyFailOnSkip) {
        policyArgv.push('--fail-on-skip');
      }
      const policyExitCode = await runPolicyCheckFn({
        argv: policyArgv,
        env,
        fetchFn
      });
      report.policy.executed = true;
      report.policy.exitCode = policyExitCode;

      if (fs.existsSync(policyReportPath)) {
        const policyReport = readJsonFn(policyReportPath);
        report.policy.result = normalizeText(policyReport?.result) ?? (policyExitCode === 0 ? 'pass' : 'fail');
      } else {
        report.policy.result = policyExitCode === 0 ? 'pass' : 'fail';
      }

      if (args.strictPolicy && report.policy.result !== 'pass') {
        report.errors.push(`Policy contract check returned '${report.policy.result}' in strict mode.`);
      }
    }

    if (report.errors.length > 0) {
      report.status = 'fail';
    } else if (!args.skipPolicy && report.policy.result !== 'pass') {
      report.status = 'warn';
    } else {
      report.status = 'pass';
    }
  } catch (error) {
    report.errors.push(error.message || String(error));
    report.status = 'fail';
  }

  const resolvedReportPath = writeJsonFn(reportPath, report);
  const exitCode = report.status === 'fail' ? 1 : 0;
  return { exitCode, report, reportPath: resolvedReportPath };
}

export async function main(argv = process.argv) {
  try {
    const result = await runBootstrapContracts({ argv });
    if (result.report) {
      console.log(`[bootstrap-contracts] report: ${result.reportPath}`);
      console.log(
        `[bootstrap-contracts] status=${result.report.status} created=${result.report.labels.createdCount} updated=${result.report.labels.updatedCount} unchanged=${result.report.labels.unchangedCount}`
      );
      if (result.report.errors.length > 0) {
        console.error(`[bootstrap-contracts] ${result.report.errors.join('; ')}`);
      }
    }
    return result.exitCode;
  } catch (error) {
    console.error(error.message || error);
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isDirectExecution) {
  main().then((exitCode) => {
    process.exit(exitCode);
  });
}
