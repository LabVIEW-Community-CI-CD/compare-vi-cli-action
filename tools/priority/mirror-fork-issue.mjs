#!/usr/bin/env node

import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { getRepoRoot } from './lib/branch-utils.mjs';
import {
  buildRepositorySlug,
  ensureForkRemote,
  parseRepositorySlug,
  resolveActiveForkRemoteName,
  resolveUpstream,
  runGhGraphql,
  runGhJson
} from './lib/remote-utils.mjs';

const POINTER_PREFIX = '<!-- upstream-issue-url: ';
const DEFAULT_REPORT_DIR = path.join('tests', 'results', '_agent', 'issue');
const STANDING_LABELS = new Set(['standing-priority', 'fork-standing-priority']);

function printUsage() {
  console.log('Usage: node tools/priority/mirror-fork-issue.mjs --issue <number> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --issue <number>              Upstream issue number to mirror (required).');
  console.log('  --fork-remote <origin|personal>  Target fork remote (default: AGENT_PRIORITY_ACTIVE_FORK_REMOTE or origin).');
  console.log(`  --report-dir <path>           Report directory (default: ${DEFAULT_REPORT_DIR}).`);
  console.log('  -h, --help                    Show this help text and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    issue: null,
    forkRemote: null,
    reportDir: DEFAULT_REPORT_DIR,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--help' || arg === '-h') {
      options.help = true;
      continue;
    }
    if (arg === '--issue' || arg === '--fork-remote' || arg === '--report-dir') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${arg}.`);
      }
      index += 1;
      if (arg === '--issue') {
        const number = Number(next);
        if (!Number.isInteger(number) || number <= 0) {
          throw new Error(`Invalid --issue '${next}'.`);
        }
        options.issue = number;
      } else if (arg === '--fork-remote') {
        options.forkRemote = next;
      } else {
        options.reportDir = next;
      }
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  return options;
}

function stripExistingPointer(body) {
  return String(body || '').replace(/^<!--\s*upstream-issue-url:[\s\S]*?-->\s*/i, '').trim();
}

export function buildMirrorBody(upstreamIssue) {
  const pointer = `${POINTER_PREFIX}${upstreamIssue.url} -->`;
  const strippedBody = stripExistingPointer(upstreamIssue.body);
  return strippedBody ? `${pointer}\n\n${strippedBody}\n` : `${pointer}\n`;
}

export function buildDesiredLabels(upstreamLabels = [], existingForkLabels = []) {
  const existing = new Set(existingForkLabels.map((entry) => String(entry).trim().toLowerCase()).filter(Boolean));
  const labels = new Set(['fork-standing-priority']);
  for (const label of upstreamLabels) {
    const normalized = String(label || '').trim().toLowerCase();
    if (!normalized || STANDING_LABELS.has(normalized)) {
      continue;
    }
    if (existing.has(normalized)) {
      labels.add(normalized);
    }
  }
  return Array.from(labels).sort();
}

function ghApi(repoRoot, endpoint, method, payload) {
  const args = ['api', endpoint, '--method', method, '--input', '-'];
  const result = spawnSync('gh', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    input: JSON.stringify(payload),
    stdio: ['pipe', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const message = String(result.stderr || result.stdout || '').trim() || `gh api failed (${result.status})`;
    throw new Error(message);
  }
  const text = String(result.stdout || '').trim();
  return text ? JSON.parse(text) : null;
}

function ensureLabel(repoRoot, repoSlug, labelName) {
  const existingLabels = listForkLabels(repoRoot, repoSlug).map((entry) => String(entry).trim().toLowerCase());
  if (existingLabels.includes(String(labelName).trim().toLowerCase())) {
    return;
  }

  const create = spawnSync(
    'gh',
    ['label', 'create', labelName, '--repo', repoSlug, '--color', '1d76db', '--description', 'Fork standing priority lane'],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  if (create.status !== 0) {
    const message = String(create.stderr || create.stdout || '').trim() || 'Unable to create label.';
    throw new Error(message);
  }
}

function listForkLabels(repoRoot, repoSlug) {
  const labels = runGhJson(
    repoRoot,
    ['label', 'list', '--repo', repoSlug, '--limit', '200', '--json', 'name']
  ) ?? [];
  return labels.map((entry) => entry?.name).filter(Boolean);
}

function normalizeIssueLabelEntries(labels = []) {
  return labels
    .map((entry) => {
      if (typeof entry === 'string') {
        const name = entry.trim();
        return name ? { name, normalized: name.toLowerCase() } : null;
      }
      const name = String(entry?.name || '').trim();
      return name ? { name, normalized: name.toLowerCase() } : null;
    })
    .filter(Boolean);
}

function normalizePointerText(value) {
  return String(value || '').trim().toLowerCase();
}

function buildMirrorPointer(upstreamUrl) {
  return `${POINTER_PREFIX}${upstreamUrl} -->`;
}

export function findMirrorIssue(issues, upstreamUrl) {
  const pointer = normalizePointerText(buildMirrorPointer(upstreamUrl));
  const mirrors = (issues || []).filter((issue) => normalizePointerText(issue?.body).includes(pointer));
  return mirrors.find((issue) => String(issue?.state || '').toLowerCase() === 'open') ?? null;
}

export function planStandingLabelDemotions(forkIssues = [], targetIssueNumber = null) {
  return (forkIssues || [])
    .filter((issue) => String(issue?.state || '').toLowerCase() === 'open')
    .filter((issue) => Number(issue?.number) !== Number(targetIssueNumber))
    .map((issue) => {
      const labels = normalizeIssueLabelEntries(issue?.labels);
      const retainedLabels = labels
        .filter((entry) => !STANDING_LABELS.has(entry.normalized))
        .map((entry) => entry.name);
      const hadStandingLabel = labels.some((entry) => STANDING_LABELS.has(entry.normalized));
      if (!hadStandingLabel) {
        return null;
      }
      return {
        number: issue.number,
        labels: retainedLabels
      };
    })
    .filter(Boolean);
}

export function listOpenForkIssues(
  repoRoot,
  repoSlug,
  {
    runGhGraphqlFn = runGhGraphql
  } = {}
) {
  const repository = parseRepositorySlug(repoSlug);
  const query = `
    query($owner: String!, $repo: String!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        issues(states: OPEN, first: 100, after: $cursor, orderBy: { field: CREATED_AT, direction: ASC }) {
          nodes {
            number
            title
            body
            url
            state
            labels(first: 100) {
              nodes {
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  `;

  const issues = [];
  let cursor = null;
  while (true) {
    const payload = runGhGraphqlFn(
      repoRoot,
      query,
      {
        owner: repository.owner,
        repo: repository.repo,
        cursor
      }
    );
    const connection = payload?.data?.repository?.issues;
    const nodes = Array.isArray(connection?.nodes) ? connection.nodes : [];
    issues.push(
      ...nodes.map((issue) => ({
        ...issue,
        labels: issue?.labels?.nodes ?? []
      }))
    );

    if (!connection?.pageInfo?.hasNextPage) {
      return issues;
    }
    cursor = connection.pageInfo.endCursor;
    if (!cursor) {
      throw new Error(`GitHub issue pagination for ${repoSlug} reported hasNextPage without an end cursor.`);
    }
  }
}

export function runMirrorForkIssue({
  repoRoot = getRepoRoot(),
  options = parseArgs(),
  env = process.env,
  resolveUpstreamFn = resolveUpstream,
  resolveActiveForkRemoteNameFn = resolveActiveForkRemoteName,
  ensureForkRemoteFn = ensureForkRemote,
  runGhJsonFn = runGhJson,
  ghApiFn = ghApi,
  ensureLabelFn = ensureLabel,
  listForkLabelsFn = listForkLabels,
  listOpenForkIssuesFn = listOpenForkIssues
} = {}) {
  if (!options.issue) {
    throw new Error('Missing required --issue option.');
  }

  const upstream = resolveUpstreamFn(repoRoot);
  const forkRemote = options.forkRemote || resolveActiveForkRemoteNameFn(env);
  const forkRepository = ensureForkRemoteFn(repoRoot, upstream, forkRemote);
  const upstreamSlug = buildRepositorySlug(upstream);
  const forkSlug = buildRepositorySlug(forkRepository);

  const upstreamIssue = runGhJsonFn(
    repoRoot,
    [
      'issue',
      'view',
      String(options.issue),
      '--repo',
      upstreamSlug,
      '--json',
      'number,title,body,url,labels,state'
    ]
  );
  if (!upstreamIssue?.number) {
    throw new Error(`Unable to load upstream issue #${options.issue} from ${upstreamSlug}.`);
  }

  ensureLabelFn(repoRoot, forkSlug, 'fork-standing-priority');
  const existingForkLabels = listForkLabelsFn(repoRoot, forkSlug);
  const desiredLabels = buildDesiredLabels(
    (upstreamIssue.labels || []).map((entry) => entry?.name || entry),
    existingForkLabels
  );
  const desiredBody = buildMirrorBody(upstreamIssue);
  const forkIssues = listOpenForkIssuesFn(repoRoot, forkSlug) ?? [];
  const existingMirror = findMirrorIssue(forkIssues, upstreamIssue.url);

  let forkIssue;
  if (existingMirror?.number) {
    forkIssue = ghApiFn(repoRoot, `repos/${forkSlug}/issues/${existingMirror.number}`, 'PATCH', {
      title: upstreamIssue.title,
      body: desiredBody,
      labels: desiredLabels
    });
  } else {
    forkIssue = ghApiFn(repoRoot, `repos/${forkSlug}/issues`, 'POST', {
      title: upstreamIssue.title,
      body: desiredBody,
      labels: desiredLabels
    });
  }

  const demotions = planStandingLabelDemotions(forkIssues, forkIssue.number);
  for (const issue of demotions) {
    try {
      ghApiFn(repoRoot, `repos/${forkSlug}/issues/${issue.number}`, 'PATCH', {
        labels: issue.labels
      });
    } catch (error) {
      throw new Error(`Failed to demote stale standing labels on ${forkSlug}#${issue.number}: ${error.message}`);
    }
  }

  const reportDir = path.isAbsolute(options.reportDir) ? options.reportDir : path.join(repoRoot, options.reportDir);
  const reportPath = path.join(reportDir, `fork-issue-mirror-${forkRemote}-${options.issue}.json`);
  const report = {
    schema: 'priority/fork-issue-mirror@v1',
    generatedAt: new Date().toISOString(),
    upstream: {
      repository: upstreamSlug,
      issueNumber: upstreamIssue.number,
      issueUrl: upstreamIssue.url
    },
    fork: {
      remote: forkRemote,
      repository: forkSlug,
      issueNumber: forkIssue.number,
      issueUrl: forkIssue.html_url ?? forkIssue.url ?? null
    },
    labels: desiredLabels,
    demotedIssues: demotions.map((entry) => entry.number),
    action: existingMirror?.number ? 'updated' : 'created'
  };
  mkdirSync(reportDir, { recursive: true });
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  console.log(`[priority:fork-issue-mirror] ${report.action} ${forkSlug}#${report.fork.issueNumber} for ${upstreamSlug}#${upstreamIssue.number}`);
  return { report, reportPath };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  runMirrorForkIssue({ options });
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const code = main(process.argv);
    if (code !== 0) {
      process.exitCode = code;
    }
  } catch (error) {
    console.error(`[priority:fork-issue-mirror] ${error.message}`);
    process.exitCode = 1;
  }
}
