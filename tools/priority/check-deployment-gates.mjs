#!/usr/bin/env node

import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/environment-gate-policy@v1';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'deployments',
  'environment-gate-policy.json'
);
export const DEFAULT_ENVIRONMENTS = ['validation', 'production'];

function printUsage() {
  console.log('Usage: node tools/priority/check-deployment-gates.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --report <path>        Report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --repo <owner/repo>    Repository slug (default: GITHUB_REPOSITORY/upstream/origin remote).');
  console.log(`  --environments <list>  Comma list of environments (default: ${DEFAULT_ENVIRONMENTS.join(',')}).`);
  console.log('  --allow-admin-bypass   Do not fail when can_admins_bypass is true.');
  console.log('  --allow-no-reviewers   Do not fail when required reviewers are missing.');
  console.log('  -h, --help             Show help and exit.');
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
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = normalizeText(explicitRepo);
  if (explicit && explicit.includes('/')) return explicit;

  const fromEnv = normalizeText(environment.GITHUB_REPOSITORY);
  if (fromEnv && fromEnv.includes('/')) return fromEnv;

  for (const remote of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remote}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) continue;
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) return parsed;
  }

  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

function parseEnvironmentList(value) {
  return String(value ?? '')
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    reportPath: DEFAULT_REPORT_PATH,
    repo: null,
    environments: [...DEFAULT_ENVIRONMENTS],
    failOnAdminBypass: true,
    failOnMissingReviewers: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--allow-admin-bypass') {
      options.failOnAdminBypass = false;
      continue;
    }
    if (token === '--allow-no-reviewers') {
      options.failOnMissingReviewers = false;
      continue;
    }
    if (token === '--report' || token === '--repo' || token === '--environments') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--report') options.reportPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--environments') options.environments = parseEnvironmentList(next);
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (options.environments.length === 0) {
    throw new Error('At least one environment is required.');
  }
  return options;
}

async function resolveToken() {
  for (const candidate of [process.env.GH_TOKEN, process.env.GITHUB_TOKEN]) {
    const token = normalizeText(candidate);
    if (token) return token;
  }

  const tokenFiles = [process.env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    tokenFiles.push('C:\\github_token.txt');
  }

  for (const filePath of tokenFiles) {
    if (!filePath) continue;
    try {
      await access(filePath);
      const token = normalizeText(await readFile(filePath, 'utf8'));
      if (token) return token;
    } catch {
      // ignore missing token file
    }
  }
  return null;
}

async function requestGitHubJson(url, token) {
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'priority-environment-gate-policy'
    }
  });

  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = new Error(`GitHub API GET ${url} failed (${response.status}).`);
    error.statusCode = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function normalizeReviewers(rule) {
  const reviewers = Array.isArray(rule?.reviewers) ? rule.reviewers : [];
  return reviewers
    .map((entry) => {
      const reviewer = entry?.reviewer ?? {};
      return {
        type: normalizeText(entry?.type) ?? null,
        login: normalizeText(reviewer?.login) ?? null,
        id: Number.isInteger(Number(reviewer?.id)) ? Number(reviewer.id) : null
      };
    })
    .filter((entry) => entry.login || entry.id || entry.type);
}

export function evaluateEnvironmentGatePolicy(envPayload, options = {}) {
  const failOnAdminBypass = options.failOnAdminBypass !== false;
  const failOnMissingReviewers = options.failOnMissingReviewers !== false;

  const rules = Array.isArray(envPayload?.protection_rules) ? envPayload.protection_rules : [];
  const requiredReviewersRule = rules.find((entry) => String(entry?.type ?? '').toLowerCase() === 'required_reviewers') ?? null;
  const reviewers = normalizeReviewers(requiredReviewersRule);
  const reviewerCount = reviewers.length;
  const canAdminsBypass = Boolean(envPayload?.can_admins_bypass);
  const preventSelfReview = requiredReviewersRule?.prevent_self_review === true;

  const checks = {
    requiredReviewers: {
      status: reviewerCount > 0 || !failOnMissingReviewers ? 'pass' : 'fail',
      reviewerCount,
      preventSelfReview
    },
    adminBypassDisabled: {
      status: !canAdminsBypass || !failOnAdminBypass ? 'pass' : 'fail',
      canAdminsBypass
    }
  };

  const reasons = [];
  if (checks.requiredReviewers.status === 'fail') reasons.push('missing-required-reviewers');
  if (checks.adminBypassDisabled.status === 'fail') reasons.push('admin-bypass-enabled');

  return {
    name: normalizeText(envPayload?.name) ?? null,
    status: reasons.length > 0 ? 'fail' : 'pass',
    checks,
    reviewers,
    reasons
  };
}

async function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function runDeploymentGatePolicy(options = {}) {
  const now = options.now ?? new Date();
  const args = options.args ?? parseArgs();
  const repoRoot = options.repoRoot ?? process.cwd();
  const environment = options.environment ?? process.env;
  const resolveTokenFn = options.resolveTokenFn ?? resolveToken;
  const requestGitHubJsonFn = options.requestGitHubJsonFn ?? requestGitHubJson;
  const writeJsonFn = options.writeJsonFn ?? writeJson;

  const repository = resolveRepositorySlug(repoRoot, args.repo, environment);
  const token = normalizeText(options.token ?? (await resolveTokenFn()));
  if (!token) {
    throw new Error('GitHub token unavailable. Set GH_TOKEN/GITHUB_TOKEN or GH_TOKEN_FILE.');
  }

  const environments = [];
  for (const envName of args.environments) {
    const environmentUrl = `https://api.github.com/repos/${repository}/environments/${encodeURIComponent(envName)}`;
    try {
      const payload = await requestGitHubJsonFn(environmentUrl, token);
      const evaluation = evaluateEnvironmentGatePolicy(payload, {
        failOnAdminBypass: args.failOnAdminBypass,
        failOnMissingReviewers: args.failOnMissingReviewers
      });
      environments.push({
        name: envName,
        exists: true,
        ...evaluation
      });
    } catch (error) {
      environments.push({
        name: envName,
        exists: false,
        status: 'fail',
        checks: {
          requiredReviewers: {
            status: 'fail',
            reviewerCount: 0,
            preventSelfReview: false
          },
          adminBypassDisabled: {
            status: 'fail',
            canAdminsBypass: null
          }
        },
        reviewers: [],
        reasons: [error?.statusCode === 404 ? 'environment-missing' : 'environment-query-failed'],
        error: error?.message ?? String(error)
      });
    }
  }

  const failingEnvironments = environments.filter((entry) => entry.status !== 'pass').map((entry) => entry.name);
  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    options: {
      failOnAdminBypass: args.failOnAdminBypass,
      failOnMissingReviewers: args.failOnMissingReviewers,
      environments: args.environments
    },
    summary: {
      status: failingEnvironments.length > 0 ? 'fail' : 'pass',
      environmentCount: environments.length,
      failingEnvironmentCount: failingEnvironments.length,
      failingEnvironments
    },
    environments
  };

  const reportPath = await writeJsonFn(args.reportPath, report);
  return {
    report,
    reportPath,
    exitCode: report.summary.status === 'pass' ? 0 : 1
  };
}

export async function main(argv = process.argv) {
  const args = parseArgs(argv);
  if (args.help) {
    printUsage();
    return 0;
  }

  const result = await runDeploymentGatePolicy({ args });
  console.log(
    `[deployment-gate-policy] report: ${result.reportPath} status=${result.report.summary.status} failing=${result.report.summary.failingEnvironmentCount}`
  );
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
