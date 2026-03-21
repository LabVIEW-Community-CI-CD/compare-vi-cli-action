#!/usr/bin/env node

import { readFile, writeFile, access, mkdir } from 'node:fs/promises';
import { execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const manifestPath = new URL('./policy.json', import.meta.url);
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'policy', 'policy-state-snapshot.json');

function printUsage() {
  console.log('Usage: node tools/priority/policy-snapshot.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --output <path>   Output JSON path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log('  --repo <owner/repo>  Target repository (default: GITHUB_REPOSITORY/upstream/origin remote)');
  console.log('  -h, --help        Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    help: false
  };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (arg === '--output' || arg === '--repo') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--output') {
        options.outputPath = value;
      } else {
        options.repo = value;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }
  return options;
}

export function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(explicitRepo, options = {}) {
  const environment = options.environment ?? process.env;
  const commandRunner = options.commandRunner ?? ((command) => execSync(command, {
    stdio: ['ignore', 'pipe', 'ignore']
  }).toString().trim());
  if (explicitRepo) {
    return explicitRepo;
  }
  if (environment.GITHUB_REPOSITORY && environment.GITHUB_REPOSITORY.includes('/')) {
    return environment.GITHUB_REPOSITORY.trim();
  }
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const url = commandRunner(`git config --get remote.${remoteName}.url`);
      const parsed = parseRemoteUrl(url);
      if (parsed) return parsed;
    } catch {
      // ignore missing remotes
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

async function resolveToken() {
  const direct = [process.env.GH_TOKEN, process.env.GITHUB_TOKEN];
  for (const value of direct) {
    if (value && value.trim()) {
      return value.trim();
    }
  }

  const files = [process.env.GH_TOKEN_FILE];
  if (process.platform === 'win32') {
    files.push('C:\\github_token.txt');
  }
  for (const candidate of files) {
    if (!candidate) continue;
    try {
      await access(candidate);
      const token = (await readFile(candidate, 'utf8')).trim();
      if (token) {
        return token;
      }
    } catch {
      // ignore missing file
    }
  }
  throw new Error('GitHub token not found. Set GH_TOKEN/GITHUB_TOKEN or GH_TOKEN_FILE.');
}

async function requestJson(url, token) {
  const response = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'priority-policy-snapshot',
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28'
    }
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub API request failed ${response.status} ${response.statusText}: ${text}`);
  }
  if (response.status === 204) {
    return null;
  }
  return response.json();
}

function isBranchPattern(branch) {
  return /[*?[\]]/.test(branch);
}

function rulesetSummaryMatches(expectations, candidate) {
  if (!expectations || !candidate) {
    return false;
  }
  if (expectations.name && candidate.name && expectations.name !== candidate.name) {
    return false;
  }
  if (expectations.target && candidate.target && expectations.target !== candidate.target) {
    return false;
  }
  return true;
}

async function loadRulesets(apiBase, token, requestJsonFn) {
  return requestJsonFn(`${apiBase}/rulesets`, token);
}

function findRule(rules = [], type) {
  if (!Array.isArray(rules)) {
    return null;
  }
  return rules.find((rule) => rule?.type === type) ?? null;
}

export function summarizeCopilotReviewState(rulesets = {}) {
  const perRuleset = {};
  const rulesetsWithCopilotCodeReview = [];
  for (const [key, ruleset] of Object.entries(rulesets)) {
    if (!ruleset || typeof ruleset !== 'object') {
      perRuleset[key] = {
        present: false,
        status: 'invalid'
      };
      continue;
    }
    if (typeof ruleset.error === 'string' && ruleset.error.trim()) {
      perRuleset[key] = {
        present: false,
        status: 'unresolved',
        error: ruleset.error
      };
      continue;
    }
    const copilotRule = findRule(ruleset.rules, 'copilot_code_review');
    const present = Boolean(copilotRule);
    if (present) {
      rulesetsWithCopilotCodeReview.push(key);
    }
    perRuleset[key] = {
      present,
      status: 'observed',
      id: ruleset.id ?? null,
      name: ruleset.name ?? null,
      parameters: copilotRule?.parameters ?? null
    };
  }
  return {
    expectedRepositoryAutomaticRequestSetting: 'disabled',
    automaticRequestSettingObservableViaApi: false,
    automaticRequestSettingEvidence: 'manual-settings-page',
    notes: [
      'Repository-level Automatic request Copilot review is not exposed by the REST endpoints used by policy-snapshot.',
      'Ruleset state is observable and must not contain copilot_code_review rules for this contract.'
    ],
    rulesetCopilotCodeReviewPresent: rulesetsWithCopilotCodeReview.length > 0,
    rulesetsWithCopilotCodeReview,
    rulesets: perRuleset
  };
}

function normalizeMergeQueueParameters(parameters = {}) {
  return {
    merge_method: parameters.merge_method ?? null,
    grouping_strategy: parameters.grouping_strategy ?? null,
    max_entries_to_build: parameters.max_entries_to_build ?? null,
    min_entries_to_merge: parameters.min_entries_to_merge ?? null,
    max_entries_to_merge: parameters.max_entries_to_merge ?? null,
    min_entries_to_merge_wait_minutes: parameters.min_entries_to_merge_wait_minutes ?? null,
    check_response_timeout_minutes: parameters.check_response_timeout_minutes ?? null
  };
}

export function buildMergeQueueContinuityAssessment(manifest = {}) {
  const developRuleset = manifest?.rulesets?.develop && typeof manifest.rulesets.develop === 'object'
    ? manifest.rulesets.develop
    : null;
  const mergeQueue = developRuleset?.merge_queue && typeof developRuleset.merge_queue === 'object'
    ? developRuleset.merge_queue
    : null;
  const current = normalizeMergeQueueParameters(mergeQueue ?? {});
  const proposed = mergeQueue
    ? {
        ...current,
        max_entries_to_build: 1,
        max_entries_to_merge: 1
      }
    : null;
  const hasMeasuredContinuity = false;

  return {
    status: mergeQueue ? 'pass' : 'warn',
    recommendation: mergeQueue ? 'retain-grouped-pending-telemetry' : 'repair-develop-merge-queue-policy',
    evidenceLevel: hasMeasuredContinuity ? 'measured' : 'policy-only',
    rationale: mergeQueue
      ? [
          `Develop currently exposes ${current.max_entries_to_build} build slots and ${current.max_entries_to_merge} merge slots in the checked-in queue policy.`,
          'Single-entry groups would reduce batch blast radius, but they would also leave the extra queue headroom underutilized unless the scheduler keeps live/background lanes busy.',
          'Keep the grouped configuration and exploit the added headroom with higher queue occupancy until telemetry justifies a promotion.'
        ]
      : [
          'The develop ruleset does not currently define a merge_queue policy in the checked-in manifest.'
        ],
    current: {
      branch: 'develop',
      mergeQueue: current
    },
    proposed: proposed
      ? {
          branch: 'develop',
          mergeQueue: proposed
        }
      : null,
    comparison: {
      queueOccupancy: {
        currentBatchCeiling: current.max_entries_to_build,
        proposedBatchCeiling: proposed?.max_entries_to_build ?? null,
        expectedDirection: mergeQueue ? 'lower-batch-size' : 'unknown'
      },
      hostedRerunChurn: {
        current: current.max_entries_to_merge != null && current.max_entries_to_merge > 1 ? 'batched' : 'single-entry',
        proposed: mergeQueue ? 'single-entry' : null,
        expectedDirection: mergeQueue ? 'lower' : 'unknown'
      },
      requeueFrequency: {
        current: current.max_entries_to_merge != null && current.max_entries_to_merge > 1 ? 'batch-level' : 'single-entry',
        proposed: mergeQueue ? 'single-entry' : null,
        expectedDirection: mergeQueue ? 'lower-blast-radius' : 'unknown'
      },
      mergeThroughput: {
        current: current.max_entries_to_merge != null && current.max_entries_to_merge > 1 ? 'batched' : 'single-entry',
        proposed: mergeQueue ? 'single-entry' : null,
        expectedDirection: mergeQueue ? 'lower-or-equal' : 'unknown'
      }
    }
  };
}

export async function collectPolicyState({
  repo,
  token,
  manifest,
  requestJsonFn = requestJson
}) {
  const apiBase = `https://api.github.com/repos/${repo}`;
  const repoState = await requestJsonFn(apiBase, token);

  const branches = {};
  for (const branchName of Object.keys(manifest.branches ?? {})) {
    if (isBranchPattern(branchName)) {
      branches[branchName] = {
        skipped: true,
        reason: 'pattern'
      };
      continue;
    }
    const protection = await requestJsonFn(`${apiBase}/branches/${encodeURIComponent(branchName)}/protection`, token);
    branches[branchName] = {
      skipped: false,
      protection
    };
  }

  const rulesets = {};
  for (const [id, expectations] of Object.entries(manifest.rulesets ?? {})) {
    const numeric = Number(id);
    if (Number.isInteger(numeric)) {
      const ruleset = await requestJsonFn(`${apiBase}/rulesets/${numeric}`, token);
      rulesets[id] = ruleset;
      continue;
    }
    const candidates = await loadRulesets(apiBase, token, requestJsonFn);
    const matched = candidates.find((candidate) => rulesetSummaryMatches(expectations, candidate));
    if (!matched?.id) {
      rulesets[id] = {
        error: 'ruleset-not-found'
      };
      continue;
    }
    rulesets[id] = await requestJsonFn(`${apiBase}/rulesets/${matched.id}`, token);
  }

  return {
    repo: {
      name: repoState.full_name,
      allow_squash_merge: repoState.allow_squash_merge,
      allow_merge_commit: repoState.allow_merge_commit,
      allow_rebase_merge: repoState.allow_rebase_merge,
      allow_auto_merge: repoState.allow_auto_merge,
      delete_branch_on_merge: repoState.delete_branch_on_merge,
      updated_at: repoState.updated_at
    },
    branches,
    rulesets,
    copilotReview: summarizeCopilotReviewState(rulesets)
  };
}

async function writeSnapshot(outputPath, payload) {
  const resolved = path.resolve(outputPath);
  await mkdir(path.dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const repository = resolveRepositorySlug(options.repo);
  const token = await resolveToken();
  const state = await collectPolicyState({
    repo: repository,
    token,
    manifest
  });
  state.mergeQueueContinuity = buildMergeQueueContinuityAssessment(manifest);

  const payload = {
    schema: 'priority/policy-live-state@v1',
    generatedAt: new Date().toISOString(),
    repository,
    state
  };
  const outputPath = await writeSnapshot(options.outputPath, payload);
  console.log(`[policy-snapshot] wrote ${outputPath}`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then((code) => {
    if (code !== 0) {
      process.exitCode = code;
    }
  }).catch((error) => {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  });
}
