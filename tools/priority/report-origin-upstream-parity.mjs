#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertPlaneTransition,
  findRepositoryPlaneEntry,
  loadBranchClassContract,
  resolveRepositoryPlane
} from './lib/branch-classification.mjs';

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', shell: false, ...opts });
}

function ensureCommand(result, cmd) {
  if (result?.error?.code === 'ENOENT') {
    const err = new Error(`Command not found: ${cmd}`);
    err.code = 'ENOENT';
    throw err;
  }
  return result;
}

function trimText(value) {
  return String(value ?? '').trim();
}

function makeErrorMessage(args, result) {
  const details = trimText(result?.stderr) || trimText(result?.stdout) || 'unknown error';
  return `git ${args.join(' ')} failed: ${details}`;
}

function runGit(args, runner = sh) {
  const result = ensureCommand(runner('git', args), 'git');
  if (result.status !== 0) {
    const err = new Error(makeErrorMessage(args, result));
    err.status = result.status;
    err.stderr = result.stderr;
    err.stdout = result.stdout;
    err.args = args;
    throw err;
  }
  return result.stdout || '';
}

export function parseRevListCounts(stdout) {
  const text = trimText(stdout);
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length < 2) {
    throw new Error(`Invalid rev-list count output: ${text || '(empty)'}`);
  }

  const baseOnly = Number(parts[0]);
  const headOnly = Number(parts[1]);
  if (!Number.isInteger(baseOnly) || !Number.isInteger(headOnly)) {
    throw new Error(`Invalid rev-list count output: ${text || '(empty)'}`);
  }

  return { baseOnly, headOnly };
}

export function parseFileList(stdout) {
  return String(stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function toPositiveInt(value, fallback) {
  if (value == null || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Invalid non-negative integer: ${value}`);
  }
  return parsed;
}

export function parseCliArgs(argv = process.argv.slice(2)) {
  const args = Array.from(argv || []);
  const options = {
    baseRef: 'upstream/develop',
    headRef: 'origin/develop',
    sampleLimit: 20,
    outputPath: null,
    githubOutputPath: null,
    stepSummaryPath: null,
    strict: false,
    failOnTreeDiff: false
  };

  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--base-ref') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --base-ref');
      options.baseRef = value;
      continue;
    }
    if (token === '--head-ref') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --head-ref');
      options.headRef = value;
      continue;
    }
    if (token === '--sample-limit') {
      const value = args[++i];
      if (value == null) throw new Error('Missing value for --sample-limit');
      options.sampleLimit = toPositiveInt(value, 20);
      continue;
    }
    if (token === '--output-path') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --output-path');
      options.outputPath = value;
      continue;
    }
    if (token === '--github-output') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --github-output');
      options.githubOutputPath = value;
      continue;
    }
    if (token === '--step-summary') {
      const value = args[++i];
      if (!value) throw new Error('Missing value for --step-summary');
      options.stepSummaryPath = value;
      continue;
    }
    if (token === '--strict') {
      options.strict = true;
      continue;
    }
    if (token === '--fail-on-tree-diff') {
      options.failOnTreeDiff = true;
      continue;
    }
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    throw new Error(`Unknown argument: ${token}`);
  }

  return options;
}

function parseRemoteFromRef(ref) {
  const text = trimText(ref);
  if (!text.includes('/')) return null;
  const [candidate] = text.split('/');
  if (!candidate) return null;
  if (!/^[A-Za-z0-9._-]+$/.test(candidate)) return null;
  return candidate;
}

function runGitOptional(args, runner = sh) {
  const result = ensureCommand(runner('git', args), 'git');
  if (result.status !== 0) return null;
  return trimText(result.stdout);
}

function tryGetRepoRoot(runner = sh) {
  const result = ensureCommand(runner('git', ['rev-parse', '--show-toplevel']), 'git');
  if (result.status !== 0) {
    return null;
  }
  return trimText(result.stdout);
}

function collectRemoteDetails(remoteName, runner = sh) {
  if (!remoteName) {
    return {
      name: null,
      present: false,
      fetchUrl: null,
      pushUrl: null
    };
  }

  const fetchUrl = runGitOptional(['remote', 'get-url', remoteName], runner);
  const pushUrl = runGitOptional(['remote', 'get-url', '--push', remoteName], runner);
  return {
    name: remoteName,
    present: Boolean(fetchUrl || pushUrl),
    fetchUrl: fetchUrl || null,
    pushUrl: pushUrl || null
  };
}

function parseRepositorySlug(url) {
  if (!url) return null;
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/i);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) {
    return null;
  }
  return `${owner}/${repo}`;
}

function resolvePlaneIdentity({ remoteName, remoteDetails, contract }) {
  const normalizedRemote = trimText(remoteName).toLowerCase();
  if (normalizedRemote === 'upstream') {
    return {
      remote: remoteName,
      plane: 'upstream',
      repository: contract.upstreamRepository
    };
  }

  if (normalizedRemote === 'origin' || normalizedRemote === 'personal') {
    const planeEntry = findRepositoryPlaneEntry(contract, normalizedRemote);
    const repository = planeEntry?.repositories?.[0] ?? null;
    if (!repository) {
      throw new Error(`Branch class contract does not define a repository for remote '${remoteName}'.`);
    }
    return {
      remote: remoteName,
      plane: normalizedRemote,
      repository
    };
  }

  const repository =
    parseRepositorySlug(remoteDetails?.fetchUrl) ??
    parseRepositorySlug(remoteDetails?.pushUrl);
  if (!repository) {
    throw new Error(`Unable to resolve repository slug for remote '${remoteName}'.`);
  }
  const plane = resolveRepositoryPlane(repository, contract);
  if (plane === 'fork') {
    throw new Error(`Unable to resolve repository plane for remote '${remoteName}' (${repository}).`);
  }
  return {
    remote: remoteName,
    plane,
    repository
  };
}

function resolveParityPlaneTransition({ baseRef, headRef, contract, runner = sh }) {
  const baseRemote = parseRemoteFromRef(baseRef);
  const headRemote = parseRemoteFromRef(headRef);
  if (!baseRemote || !headRemote) {
    throw new Error(`Parity refs must point at named remotes. Received '${baseRef}' and '${headRef}'.`);
  }

  const baseRemoteDetails = collectRemoteDetails(baseRemote, runner);
  const headRemoteDetails = collectRemoteDetails(headRemote, runner);
  const base = resolvePlaneIdentity({ remoteName: baseRemote, remoteDetails: baseRemoteDetails, contract });
  const head = resolvePlaneIdentity({ remoteName: headRemote, remoteDetails: headRemoteDetails, contract });
  const transition = assertPlaneTransition({
    fromPlane: base.plane,
    toPlane: head.plane,
    action: 'sync',
    contract
  });

  return {
    baseRemote,
    headRemote,
    baseRemoteDetails,
    headRemoteDetails,
    planeTransition: {
      ...transition,
      baseRepository: base.repository,
      headRepository: head.repository
    }
  };
}

function buildParityRecommendation({
  baseRef,
  headRef,
  treeEqual,
  baseOnly,
  headOnly,
  tipDiffCount
}) {
  if (treeEqual && baseOnly === 0 && headOnly === 0) {
    return {
      code: 'aligned',
      summary: 'Tree and history are aligned.',
      nextActions: []
    };
  }

  if (treeEqual) {
    return {
      code: 'history-diverged-tree-equal',
      summary: 'Tree is aligned but commit history diverges (typically due to squash/merge style).',
      nextActions: [
        `No code sync required; optional history normalization can be handled with policy-approved merge strategy between ${baseRef} and ${headRef}.`
      ]
    };
  }

  if (headOnly > 0 && baseOnly === 0) {
    return {
      code: 'sync-base-from-head',
      summary: `${headRef} is ahead with tree drift; sync ${baseRef} from ${headRef}.`,
      nextActions: [
        `Open a sync PR from ${headRef} into ${baseRef} or apply a tip-diff file sync from ${headRef}.`,
        `Validate required checks before merging into ${baseRef}.`
      ]
    };
  }

  if (baseOnly > 0 && headOnly === 0) {
    return {
      code: 'sync-head-from-base',
      summary: `${baseRef} is ahead with tree drift; sync ${headRef} from ${baseRef}.`,
      nextActions: [
        `Open a sync PR from ${baseRef} into ${headRef} or apply a tip-diff file sync from ${baseRef}.`,
        `Validate required checks before merging into ${headRef}.`
      ]
    };
  }

  return {
    code: 'bidirectional-drift',
    summary: `Both ${baseRef} and ${headRef} diverged with tree drift; manual parity branch required.`,
    nextActions: [
      `Create a dedicated parity branch from ${baseRef}, cherry-pick or file-sync intended deltas from ${headRef}.`,
      'Run full validation and merge with admin policy as needed.'
    ]
  };
}

export function collectParity(options = {}, runner = sh) {
  const baseRef = options.baseRef || 'upstream/develop';
  const headRef = options.headRef || 'origin/develop';
  const sampleLimit = toPositiveInt(options.sampleLimit, 20);
  const strict = Boolean(options.strict);
  const now = new Date().toISOString();
  const repoRoot = options.repoRoot || tryGetRepoRoot(runner) || process.cwd();

  try {
    const contract = options.branchClassContract || loadBranchClassContract(repoRoot);
    const baseCommit = trimText(runGit(['rev-parse', '--verify', baseRef], runner));
    const headCommit = trimText(runGit(['rev-parse', '--verify', headRef], runner));
    const baseTree = trimText(runGit(['rev-parse', `${baseRef}^{tree}`], runner));
    const headTree = trimText(runGit(['rev-parse', `${headRef}^{tree}`], runner));
    const countsText = runGit(['rev-list', '--left-right', '--count', `${baseRef}...${headRef}`], runner);
    const counts = parseRevListCounts(countsText);
    const filesText = runGit(['diff', '--name-only', baseRef, headRef], runner);
    const files = parseFileList(filesText);
    const sample = sampleLimit > 0 ? files.slice(0, sampleLimit) : [];
    const treeEqual = baseTree === headTree;
    const historyEqual = counts.baseOnly === 0 && counts.headOnly === 0;
    const recommendation = buildParityRecommendation({
      baseRef,
      headRef,
      treeEqual,
      baseOnly: counts.baseOnly,
      headOnly: counts.headOnly,
      tipDiffCount: files.length
    });
    const {
      baseRemote,
      headRemote,
      baseRemoteDetails,
      headRemoteDetails,
      planeTransition
    } = resolveParityPlaneTransition({
      baseRef,
      headRef,
      contract,
      runner
    });
    const remotes = {};
    if (baseRemoteDetails.name) {
      remotes[baseRemoteDetails.name] = {
        ...baseRemoteDetails,
        plane: planeTransition.from,
        repository: planeTransition.baseRepository
      };
    }
    if (headRemoteDetails.name) {
      remotes[headRemoteDetails.name] = {
        ...headRemoteDetails,
        plane: planeTransition.to,
        repository: planeTransition.headRepository
      };
    }

    return {
      schema: 'origin-upstream-parity@v1',
      status: 'ok',
      generatedAt: now,
      baseRef,
      headRef,
      refs: {
        base: {
          ref: baseRef,
          commit: baseCommit,
          tree: baseTree
        },
        head: {
          ref: headRef,
          commit: headCommit,
          tree: headTree
        }
      },
      treeParity: {
        equal: treeEqual,
        status: treeEqual ? 'equal' : 'different',
        baseTree,
        headTree
      },
      historyParity: {
        equal: historyEqual,
        status: historyEqual ? 'equal' : 'diverged',
        baseOnly: counts.baseOnly,
        headOnly: counts.headOnly
      },
      recommendation,
      planeTransition,
      remoteManagement: {
        baseRemote,
        headRemote,
        remotes
      },
      tipDiff: {
        fileCount: files.length,
        sampleLimit,
        sample,
        treeConsistent: treeEqual ? files.length === 0 : true
      },
      commitDivergence: {
        baseOnly: counts.baseOnly,
        headOnly: counts.headOnly
      }
    };
  } catch (err) {
    if (strict) throw err;
    return {
      schema: 'origin-upstream-parity@v1',
      status: 'unavailable',
      generatedAt: now,
      baseRef,
      headRef,
      reason: err.message
    };
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

function appendGitHubOutput(filePath, name, value) {
  if (!filePath) return;
  fs.appendFileSync(filePath, `${name}=${String(value ?? '')}\n`, 'utf8');
}

export function renderSummaryMarkdown(report) {
  if (!report || report.status !== 'ok') {
    return [
      '### Origin/Upstream Parity',
      '',
      '| Metric | Value |',
      '| --- | --- |',
      `| Status | unavailable |`,
      `| Base Ref | ${report?.baseRef || '(none)'} |`,
      `| Head Ref | ${report?.headRef || '(none)'} |`,
      `| Reason | ${report?.reason || 'unknown'} |`,
      ''
    ].join('\n');
  }

  const lines = [
    '### Origin/Upstream Parity',
    '',
    '| Metric | Value |',
    '| --- | --- |',
    `| Status | ok |`,
    `| Base Ref | ${report.baseRef} |`,
    `| Head Ref | ${report.headRef} |`,
    `| Tree Parity | ${report.treeParity?.status || 'unknown'} |`,
    `| History Parity | ${report.historyParity?.status || 'unknown'} |`,
    `| Tip Diff File Count | ${report.tipDiff.fileCount} |`,
    `| Commit Divergence (base-only/head-only) | ${report.commitDivergence.baseOnly}/${report.commitDivergence.headOnly} |`,
    `| Recommendation | ${report.recommendation?.code || 'n/a'} |`,
    `| Plane Transition | ${report.planeTransition ? `${report.planeTransition.from}->${report.planeTransition.to} (${report.planeTransition.via})` : 'n/a'} |`
  ];

  if (Array.isArray(report.tipDiff.sample) && report.tipDiff.sample.length > 0) {
    lines.push('', 'Tip-diff sample:');
    for (const file of report.tipDiff.sample) {
      lines.push(`- \`${file}\``);
    }
  }
  if (report.recommendation?.summary) {
    lines.push('', `Recommendation summary: ${report.recommendation.summary}`);
  }
  if (Array.isArray(report.recommendation?.nextActions) && report.recommendation.nextActions.length > 0) {
    lines.push('', 'Next actions:');
    for (const action of report.recommendation.nextActions) {
      lines.push(`- ${action}`);
    }
  }

  lines.push('');
  return lines.join('\n');
}

function printHelp() {
  console.log(`Usage:
  node tools/priority/report-origin-upstream-parity.mjs [options]

Options:
  --base-ref <ref>          Base ref (default: upstream/develop)
  --head-ref <ref>          Head ref (default: origin/develop)
  --sample-limit <n>        Max sample files in output (default: 20)
  --output-path <file>      JSON output file path
  --github-output <file>    Append GitHub output variables
  --step-summary <file>     Append markdown summary
  --strict                  Fail on git/ref errors instead of reporting unavailable
  --fail-on-tree-diff       Exit non-zero when tree parity is different
  --help, -h                Show help`);
}

async function main() {
  const options = parseCliArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    process.exitCode = 0;
    return;
  }

  const outputPath =
    options.outputPath ||
    path.join(process.cwd(), 'tests', 'results', '_agent', 'issue', 'origin-upstream-parity.json');
  const report = collectParity(options);
  writeJson(outputPath, report);

  appendGitHubOutput(options.githubOutputPath, 'parity_status', report.status);
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_tip_diff_count',
    report.status === 'ok' ? report.tipDiff.fileCount : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_base_only_commits',
    report.status === 'ok' ? report.commitDivergence.baseOnly : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_head_only_commits',
    report.status === 'ok' ? report.commitDivergence.headOnly : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_tree_equal',
    report.status === 'ok' ? report.treeParity?.equal : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_history_equal',
    report.status === 'ok' ? report.historyParity?.equal : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_recommendation_code',
    report.status === 'ok' ? report.recommendation?.code : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_transition_from',
    report.status === 'ok' ? report.planeTransition?.from : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_transition_to',
    report.status === 'ok' ? report.planeTransition?.to : ''
  );
  appendGitHubOutput(
    options.githubOutputPath,
    'parity_transition_via',
    report.status === 'ok' ? report.planeTransition?.via : ''
  );
  appendGitHubOutput(options.githubOutputPath, 'parity_report_path', outputPath);

  if (options.stepSummaryPath) {
    const summary = renderSummaryMarkdown(report);
    fs.appendFileSync(options.stepSummaryPath, `${summary}\n`, 'utf8');
  }

  console.log(`[parity] status=${report.status} base=${report.baseRef} head=${report.headRef}`);
  if (report.status === 'ok') {
    console.log(
      `[parity] tipDiff=${report.tipDiff.fileCount} commits=${report.commitDivergence.baseOnly}/${report.commitDivergence.headOnly}`
    );
    console.log(
      `[parity] tree=${report.treeParity?.status || 'unknown'} history=${report.historyParity?.status || 'unknown'} recommendation=${report.recommendation?.code || 'n/a'}`
    );
  } else {
    console.log(`[parity] reason=${report.reason}`);
  }
  console.log(`[parity] report=${outputPath}`);

  if (options.failOnTreeDiff) {
    if (report.status !== 'ok') {
      throw new Error('Unable to evaluate tree parity because parity status is unavailable.');
    }
    if (!report.treeParity?.equal) {
      throw new Error(
        `Tree parity mismatch for ${report.baseRef} vs ${report.headRef} (${report.refs?.base?.tree || '<unknown>'} != ${report.refs?.head?.tree || '<unknown>'}).`
      );
    }
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main().catch((err) => {
    console.error(`[parity] ${err.message}`);
    process.exitCode = 1;
  });
}
