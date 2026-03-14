#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_ENVIRONMENTS,
  evaluateEnvironmentGatePolicy,
  normalizeReviewers,
  normalizeText,
  requestGitHubJson,
  resolveToken,
  writeJson
} from './check-deployment-gates.mjs';

export const POLICY_SCHEMA = 'priority/deployment-environment-parity@v1';
export const REPORT_SCHEMA = 'priority/deployment-environment-sync@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'deployment-environment-parity.json');
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'deployments',
  'environment-gate-sync.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/sync-deployment-environments.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --policy <path>       Portability policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --report <path>       Report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --target <name>       Target alias or repository slug. Repeat for multiple targets.');
  console.log('  --source-repo <slug>  Override source repository from policy.');
  console.log('  --apply               Apply changes to target repositories.');
  console.log('  -h, --help            Show help and exit.');
}

function normalizeReviewerSpec(entry) {
  const type = normalizeText(entry?.type) ?? 'User';
  if (type === 'User') {
    const login = normalizeText(entry?.login);
    if (!login) {
      throw new Error('User reviewer entries require login.');
    }
    return { type, login };
  }

  if (type === 'Team') {
    const organization = normalizeText(entry?.organization);
    const teamSlug = normalizeText(entry?.teamSlug);
    if (!organization || !teamSlug) {
      throw new Error('Team reviewer entries require organization and teamSlug.');
    }
    return { type, organization, teamSlug };
  }

  throw new Error(`Unsupported reviewer type '${type}'.`);
}

function normalizeEnvironmentOverride(entry) {
  if (!entry || typeof entry !== 'object') {
    return {};
  }

  const override = {};
  if (Array.isArray(entry.reviewers)) {
    override.reviewers = entry.reviewers.map((reviewer) => normalizeReviewerSpec(reviewer));
  }
  if (typeof entry.preventSelfReview === 'boolean') {
    override.preventSelfReview = entry.preventSelfReview;
  }
  if (typeof entry.canAdminsBypass === 'boolean') {
    override.canAdminsBypass = entry.canAdminsBypass;
  }
  return override;
}

function normalizeTargetPolicy(alias, entry) {
  const repository = normalizeText(entry?.repository);
  if (!repository || !repository.includes('/')) {
    throw new Error(`Target '${alias}' is missing repository.`);
  }

  const overrides = {};
  const rawOverrides = entry?.overrides ?? {};
  for (const [environmentName, override] of Object.entries(rawOverrides)) {
    overrides[String(environmentName)] = normalizeEnvironmentOverride(override);
  }

  return {
    alias,
    repository,
    overrides
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    reportPath: DEFAULT_REPORT_PATH,
    targetSelectors: [],
    sourceRepository: null,
    apply: false,
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
      continue;
    }
    if (token === '--policy' || token === '--report' || token === '--target' || token === '--source-repo') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--policy') options.policyPath = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--target') options.targetSelectors.push(next);
      if (token === '--source-repo') options.sourceRepository = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export async function loadPortabilityPolicy(policyPath, readFileFn = readFile) {
  const raw = JSON.parse(await readFileFn(policyPath, 'utf8'));
  if (raw?.schema !== POLICY_SCHEMA) {
    throw new Error(`Unsupported deployment environment policy schema '${raw?.schema ?? 'missing'}'.`);
  }

  const sourceRepository = normalizeText(raw.sourceRepository);
  if (!sourceRepository || !sourceRepository.includes('/')) {
    throw new Error('Deployment environment parity policy requires sourceRepository.');
  }

  const rawTargets = raw.targets ?? {};
  const targetEntries = Object.entries(rawTargets);
  if (targetEntries.length === 0) {
    throw new Error('Deployment environment parity policy requires at least one target.');
  }

  const targets = new Map();
  for (const [alias, value] of targetEntries) {
    const target = normalizeTargetPolicy(alias, value);
    targets.set(alias, target);
  }

  return {
    schema: POLICY_SCHEMA,
    sourceRepository,
    targets
  };
}

function selectTargets(policy, selectors) {
  if (!selectors || selectors.length === 0) {
    return [...policy.targets.values()];
  }

  const selected = [];
  for (const selector of selectors) {
    const normalized = normalizeText(selector);
    if (!normalized) {
      continue;
    }
    if (normalized === 'all') {
      return [...policy.targets.values()];
    }
    const byAlias = policy.targets.get(normalized);
    if (byAlias) {
      selected.push(byAlias);
      continue;
    }
    const byRepository = [...policy.targets.values()].find((target) => target.repository === normalized);
    if (!byRepository) {
      throw new Error(`Unknown deployment environment sync target '${normalized}'.`);
    }
    selected.push(byRepository);
  }

  const deduped = new Map(selected.map((target) => [target.alias, target]));
  return [...deduped.values()];
}

function summarizeEnvironmentContract(envPayload) {
  const requiredReviewersRule =
    (Array.isArray(envPayload?.protection_rules) ? envPayload.protection_rules : []).find(
      (entry) => String(entry?.type ?? '').toLowerCase() === 'required_reviewers'
    ) ?? null;
  return {
    name: normalizeText(envPayload?.name) ?? null,
    canAdminsBypass: Boolean(envPayload?.can_admins_bypass),
    preventSelfReview: requiredReviewersRule?.prevent_self_review === true,
    reviewers: normalizeReviewers(requiredReviewersRule).map((reviewer) => {
      if (reviewer.type === 'Team') {
        return {
          type: 'Team',
          organization: reviewer.login?.split('/')[0] ?? null,
          teamSlug: reviewer.login?.split('/')[1] ?? null
        };
      }
      return {
        type: 'User',
        login: reviewer.login
      };
    })
  };
}

export function buildDesiredEnvironmentContract(sourceEnvironment, targetPolicy) {
  const sourceContract = summarizeEnvironmentContract(sourceEnvironment);
  const override = targetPolicy.overrides[sourceContract.name] ?? {};
  return {
    name: sourceContract.name,
    canAdminsBypass:
      typeof override.canAdminsBypass === 'boolean' ? override.canAdminsBypass : sourceContract.canAdminsBypass,
    preventSelfReview:
      typeof override.preventSelfReview === 'boolean' ? override.preventSelfReview : sourceContract.preventSelfReview,
    reviewers: Array.isArray(override.reviewers) ? override.reviewers : sourceContract.reviewers
  };
}

function reviewerKey(reviewer) {
  if (reviewer.type === 'Team') {
    return `Team:${reviewer.organization}/${reviewer.teamSlug}`;
  }
  return `User:${reviewer.login}`;
}

function contractsEqual(left, right) {
  if (!left || !right) {
    return false;
  }
  if (left.canAdminsBypass !== right.canAdminsBypass || left.preventSelfReview !== right.preventSelfReview) {
    return false;
  }
  const leftKeys = left.reviewers.map((reviewer) => reviewerKey(reviewer)).sort();
  const rightKeys = right.reviewers.map((reviewer) => reviewerKey(reviewer)).sort();
  return JSON.stringify(leftKeys) === JSON.stringify(rightKeys);
}

async function requestGitHubJsonWithMethod(url, token, method = 'GET', payload = null) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'priority-deployment-environment-sync',
      ...(payload ? { 'Content-Type': 'application/json' } : {})
    },
    body: payload ? JSON.stringify(payload) : undefined
  });

  const text = await response.text();
  const json = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const error = new Error(`GitHub API ${method} ${url} failed (${response.status}).`);
    error.statusCode = response.status;
    error.payload = json;
    throw error;
  }
  return json;
}

async function resolveReviewerIds(reviewers, token, requestGitHubJsonFn) {
  const resolved = [];
  for (const reviewer of reviewers) {
    if (reviewer.type === 'User') {
      const payload = await requestGitHubJsonFn(`https://api.github.com/users/${encodeURIComponent(reviewer.login)}`, token);
      const id = Number(payload?.id);
      if (!Number.isInteger(id) || id <= 0) {
        throw new Error(`Unable to resolve user reviewer '${reviewer.login}'.`);
      }
      resolved.push({ type: 'User', id, login: reviewer.login });
      continue;
    }

    if (reviewer.type === 'Team') {
      const payload = await requestGitHubJsonFn(
        `https://api.github.com/orgs/${encodeURIComponent(reviewer.organization)}/teams/${encodeURIComponent(reviewer.teamSlug)}`,
        token
      );
      const id = Number(payload?.id);
      if (!Number.isInteger(id) || id <= 0) {
        throw new Error(`Unable to resolve team reviewer '${reviewer.organization}/${reviewer.teamSlug}'.`);
      }
      resolved.push({ type: 'Team', id, organization: reviewer.organization, teamSlug: reviewer.teamSlug });
      continue;
    }

    throw new Error(`Unsupported reviewer type '${reviewer.type}'.`);
  }
  return resolved;
}

function buildEnvironmentPayload(contract, resolvedReviewers) {
  return {
    reviewers: resolvedReviewers.map((reviewer) => ({ type: reviewer.type, id: reviewer.id })),
    prevent_self_review: contract.preventSelfReview,
    can_admins_bypass: contract.canAdminsBypass
  };
}

async function fetchEnvironment(repository, environmentName, token, requestGitHubJsonFn) {
  const url = `https://api.github.com/repos/${repository}/environments/${encodeURIComponent(environmentName)}`;
  try {
    return {
      exists: true,
      payload: await requestGitHubJsonFn(url, token)
    };
  } catch (error) {
    if (error?.statusCode === 404) {
      return { exists: false, payload: null };
    }
    throw error;
  }
}

export async function runDeploymentEnvironmentSync(options = {}) {
  const args = options.args ?? parseArgs();
  const repoRoot = options.repoRoot ?? process.cwd();
  const loadPolicyFn = options.loadPolicyFn ?? loadPortabilityPolicy;
  const resolveTokenFn = options.resolveTokenFn ?? resolveToken;
  const requestGitHubJsonFn = options.requestGitHubJsonFn ?? requestGitHubJson;
  const putGitHubJsonFn = options.putGitHubJsonFn ?? requestGitHubJsonWithMethod;
  const writeJsonFn = options.writeJsonFn ?? writeJson;

  const policyPath = path.resolve(repoRoot, args.policyPath);
  const policy = await loadPolicyFn(policyPath);
  const sourceRepository = normalizeText(args.sourceRepository) ?? policy.sourceRepository;
  const targets = selectTargets(policy, args.targetSelectors);
  const token = normalizeText(options.token ?? (await resolveTokenFn()));
  if (!token) {
    throw new Error('GitHub token unavailable. Set GH_TOKEN/GITHUB_TOKEN or GH_TOKEN_FILE.');
  }

  const sourceEnvironments = new Map();
  for (const environmentName of DEFAULT_ENVIRONMENTS) {
    const source = await fetchEnvironment(sourceRepository, environmentName, token, requestGitHubJsonFn);
    if (!source.exists) {
      throw new Error(`Source environment '${environmentName}' does not exist in ${sourceRepository}.`);
    }
    sourceEnvironments.set(environmentName, source.payload);
  }

  const targetReports = [];
  for (const target of targets) {
    const environmentReports = [];
    for (const environmentName of DEFAULT_ENVIRONMENTS) {
      const sourcePayload = sourceEnvironments.get(environmentName);
      const desiredContract = buildDesiredEnvironmentContract(sourcePayload, target);
      const current = await fetchEnvironment(target.repository, environmentName, token, requestGitHubJsonFn);
      const beforeContract = current.exists ? summarizeEnvironmentContract(current.payload) : null;
      const resolvedReviewers = await resolveReviewerIds(desiredContract.reviewers, token, requestGitHubJsonFn);
      const desiredPayload = buildEnvironmentPayload(desiredContract, resolvedReviewers);
      const needsApply = !current.exists || !contractsEqual(beforeContract, desiredContract);

      let action = 'noop';
      let afterPayload = current.payload;
      if (args.apply && needsApply) {
        action = current.exists ? 'updated' : 'created';
        const environmentUrl = `https://api.github.com/repos/${target.repository}/environments/${encodeURIComponent(environmentName)}`;
        await putGitHubJsonFn(environmentUrl, token, 'PUT', desiredPayload);
        const refreshed = await fetchEnvironment(target.repository, environmentName, token, requestGitHubJsonFn);
        afterPayload = refreshed.payload;
      } else if (needsApply) {
        action = current.exists ? 'would-update' : 'would-create';
      }

      const afterContract = afterPayload ? summarizeEnvironmentContract(afterPayload) : desiredContract;
      const evaluation = evaluateEnvironmentGatePolicy(
        afterPayload ?? {
          name: environmentName,
          can_admins_bypass: desiredContract.canAdminsBypass,
          protection_rules: [
            {
              type: 'required_reviewers',
              prevent_self_review: desiredContract.preventSelfReview,
              reviewers: desiredContract.reviewers.map((reviewer) =>
                reviewer.type === 'Team'
                  ? {
                      type: 'Team',
                      reviewer: {
                        login: `${reviewer.organization}/${reviewer.teamSlug}`
                      }
                    }
                  : {
                      type: 'User',
                      reviewer: {
                        login: reviewer.login
                      }
                    }
              )
            }
          ]
        },
        { failOnAdminBypass: true, failOnMissingReviewers: true }
      );

      environmentReports.push({
        name: environmentName,
        action,
        status: contractsEqual(afterContract, desiredContract) ? 'pass' : 'fail',
        existsBefore: current.exists,
        desired: desiredContract,
        before: beforeContract,
        after: afterContract,
        evaluation
      });
    }

    const failingEnvironments = environmentReports.filter((entry) => entry.status !== 'pass').map((entry) => entry.name);
    targetReports.push({
      alias: target.alias,
      repository: target.repository,
      status: failingEnvironments.length > 0 ? 'fail' : 'pass',
      failingEnvironments,
      environments: environmentReports
    });
  }

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    apply: args.apply,
    sourceRepository,
    policyPath: path.relative(repoRoot, policyPath),
    targets: targetReports,
    summary: {
      status: targetReports.some((entry) => entry.status !== 'pass') ? 'fail' : 'pass',
      targetCount: targetReports.length,
      failingTargets: targetReports.filter((entry) => entry.status !== 'pass').map((entry) => entry.alias),
      actionsRequired: targetReports.flatMap((entry) => entry.environments).filter((entry) => entry.action.startsWith('would-')).length
    }
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

  const result = await runDeploymentEnvironmentSync({ args });
  console.log(
    `[deployment-gate-sync] report: ${result.reportPath} status=${result.report.summary.status} targets=${result.report.summary.targetCount} actionsRequired=${result.report.summary.actionsRequired}`
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
