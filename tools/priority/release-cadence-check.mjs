import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEFAULT_MARKER = '<!-- cadence-check:package-staleness -->';
export const DEFAULT_ISSUE_TITLE = '[cadence] Package stream freshness alert';
export const DEFAULT_THRESHOLD_DAYS = 45;
export const DEFAULT_MAX_RUNS = 100;
export const REPORT_SCHEMA = 'release-cadence-check-report@v1';
export const RUN_EVIDENCE_SOURCE = 'workflow-run-log';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');

export function isDirectExecution(entryPath = process.argv[1]) {
  if (!entryPath) {
    return false;
  }

  return path.resolve(entryPath) === path.resolve(__filename);
}

function parseInteger(value, fallback) {
  if (value === null || value === undefined || value === '') {
    return fallback;
  }

  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Expected integer value. Received: ${value}`);
  }
  return parsed;
}

export function parseArgs(argv) {
  const options = {
    repo: process.env.GITHUB_REPOSITORY || '',
    marker: DEFAULT_MARKER,
    issueTitle: DEFAULT_ISSUE_TITLE,
    staleThresholdDays: DEFAULT_THRESHOLD_DAYS,
    maxRuns: DEFAULT_MAX_RUNS,
    dryRun: false,
    outPath: path.join('tests', 'results', '_agent', 'release', 'release-cadence-check-report.json'),
    stepSummaryPath: process.env.GITHUB_STEP_SUMMARY || '',
    ghPath: process.env.GH_PATH || 'gh',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case '--repo':
        options.repo = argv[++index] ?? '';
        break;
      case '--marker':
        options.marker = argv[++index] ?? DEFAULT_MARKER;
        break;
      case '--issue-title':
        options.issueTitle = argv[++index] ?? DEFAULT_ISSUE_TITLE;
        break;
      case '--threshold-days':
        options.staleThresholdDays = parseInteger(argv[++index], DEFAULT_THRESHOLD_DAYS);
        break;
      case '--max-runs':
        options.maxRuns = parseInteger(argv[++index], DEFAULT_MAX_RUNS);
        break;
      case '--out':
        options.outPath = argv[++index] ?? options.outPath;
        break;
      case '--step-summary':
        options.stepSummaryPath = argv[++index] ?? '';
        break;
      case '--gh-path':
        options.ghPath = argv[++index] ?? 'gh';
        break;
      case '--dry-run':
        options.dryRun = true;
        break;
      case '--help':
      case '-h':
        options.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

export function stripAnsi(text) {
  return String(text ?? '').replace(/\x1b\[[0-9;]*m/g, '');
}

export function normalizeLogText(text) {
  return stripAnsi(text).replace(/\r/g, '').replace(/\\`/g, '`');
}

function firstCapture(text, pattern) {
  const match = pattern.exec(text);
  return match?.[1]?.trim() ?? null;
}

function parseMarkdownBulletValue(text, label) {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return firstCapture(text, new RegExp(`- ${escapedLabel}:\\s*\`([^\\n\`]+)\``, 'i'));
}

function parsePublishedTags(text) {
  const tagsSectionIndex = text.indexOf('## Published tags');
  if (tagsSectionIndex < 0) {
    return [];
  }

  const section = text.slice(tagsSectionIndex);
  return Array.from(section.matchAll(/(?:^|\n).*?- `([^`\n]+)`/gm), (match) => match[1]).filter(
    (tag) => !tag.includes('${')
  );
}

export function parseCompareviToolsPublishLog(logText) {
  const text = normalizeLogText(logText);
  const version = parseMarkdownBulletValue(text, 'Version');
  const channel = parseMarkdownBulletValue(text, 'Channel');

  if (!version || !channel) {
    return null;
  }

  return {
    version,
    channel,
    stableFamilyVersion: parseMarkdownBulletValue(text, 'Stable family version'),
    sourceRef: parseMarkdownBulletValue(text, 'Source ref'),
    digest: parseMarkdownBulletValue(text, 'Digest'),
    publishedTags: parsePublishedTags(text),
  };
}

export function parseCompareViSharedPublishLog(logText) {
  const text = normalizeLogText(logText);
  const version = parseMarkdownBulletValue(text, 'Version');
  const channel = parseMarkdownBulletValue(text, 'Channel');
  const publishedRaw = parseMarkdownBulletValue(text, 'Published');

  if (!version || !channel || !publishedRaw) {
    return null;
  }

  return {
    version,
    channel,
    published: publishedRaw.toLowerCase() === 'true',
    registry: parseMarkdownBulletValue(text, 'Registry'),
  };
}

function buildToolsRunEvidence(run, parsed) {
  return {
    stream: 'comparevi-tools',
    runId: run.databaseId,
    runUrl: run.url,
    createdAt: run.createdAt,
    event: run.event,
    headBranch: run.headBranch,
    displayTitle: run.displayTitle,
    evidenceSource: RUN_EVIDENCE_SOURCE,
    version: parsed.version,
    channel: parsed.channel,
    published: true,
    stableRef: parsed.channel === 'stable' ? `v${parsed.stableFamilyVersion ?? parsed.version}` : null,
    stableFamilyVersion: parsed.stableFamilyVersion,
    sourceRef: parsed.sourceRef,
    digest: parsed.digest,
    publishedTags: parsed.publishedTags,
  };
}

function buildSharedRunEvidence(run, parsed) {
  return {
    stream: 'CompareVi.Shared',
    runId: run.databaseId,
    runUrl: run.url,
    createdAt: run.createdAt,
    event: run.event,
    headBranch: run.headBranch,
    displayTitle: run.displayTitle,
    evidenceSource: RUN_EVIDENCE_SOURCE,
    version: parsed.version,
    channel: parsed.channel,
    published: parsed.published,
    stableRef: parsed.channel === 'stable' && parsed.published ? parsed.version : null,
    registry: parsed.registry,
  };
}

export function findLatestRunEvidence({ streamName, runs, fetchRunLog, parseRunLog, buildRunEvidence, isStableEvidence }) {
  const notes = [];
  let latestObserved = null;

  for (const run of runs) {
    if (String(run?.status || '').toLowerCase() !== 'completed' || String(run?.conclusion || '').toLowerCase() !== 'success') {
      continue;
    }

    let logText;
    try {
      logText = fetchRunLog(run);
    } catch (error) {
      notes.push(`run ${run.databaseId}: unable to fetch log (${error.message || error})`);
      continue;
    }

    const parsed = parseRunLog(logText);
    if (!parsed) {
      notes.push(`run ${run.databaseId}: unable to parse publish evidence`);
      continue;
    }

    const evidence = buildRunEvidence(run, parsed);
    if (!latestObserved) {
      latestObserved = evidence;
    }

    if (isStableEvidence(evidence)) {
      return { latestStable: evidence, latestObserved, notes };
    }
  }

  if (!latestObserved) {
    throw new Error(`Unable to resolve any publish evidence for ${streamName}.`);
  }

  return { latestStable: null, latestObserved, notes };
}

export function calculateAgeDays(isoTimestamp, now = new Date()) {
  if (!isoTimestamp) {
    return null;
  }

  const deltaMs = now.getTime() - new Date(isoTimestamp).getTime();
  return Math.floor(deltaMs / (24 * 60 * 60 * 1000));
}

function buildStreamSnapshot({ name, resolved, now, staleThresholdDays }) {
  const latestStable = resolved.latestStable;
  const ageDays = calculateAgeDays(latestStable?.createdAt ?? null, now);
  const stale = !latestStable || ageDays === null || ageDays > staleThresholdDays;

  return {
    name,
    latestStableRef: latestStable?.stableRef ?? 'none',
    latestPublishUtc: latestStable?.createdAt ?? null,
    ageDays,
    stale,
    evidenceSource: RUN_EVIDENCE_SOURCE,
    latestStable,
    latestObserved: resolved.latestObserved ?? null,
    notes: resolved.notes ?? [],
  };
}

export function evaluateReleaseCadence({
  now = new Date(),
  staleThresholdDays = DEFAULT_THRESHOLD_DAYS,
  toolsRuns,
  sharedRuns,
  fetchToolsRunLog,
  fetchSharedRunLog,
}) {
  const resolvedTools = findLatestRunEvidence({
    streamName: 'comparevi-tools',
    runs: toolsRuns,
    fetchRunLog: fetchToolsRunLog,
    parseRunLog: parseCompareviToolsPublishLog,
    buildRunEvidence: buildToolsRunEvidence,
    isStableEvidence: (evidence) => evidence.channel === 'stable',
  });

  const resolvedShared = findLatestRunEvidence({
    streamName: 'CompareVi.Shared',
    runs: sharedRuns,
    fetchRunLog: fetchSharedRunLog,
    parseRunLog: parseCompareViSharedPublishLog,
    buildRunEvidence: buildSharedRunEvidence,
    isStableEvidence: (evidence) => evidence.channel === 'stable' && evidence.published === true,
  });

  const streams = [
    buildStreamSnapshot({
      name: 'comparevi-tools',
      resolved: resolvedTools,
      now,
      staleThresholdDays,
    }),
    buildStreamSnapshot({
      name: 'CompareVi.Shared',
      resolved: resolvedShared,
      now,
      staleThresholdDays,
    }),
  ];

  return {
    schema: REPORT_SCHEMA,
    checkedAtUtc: now.toISOString(),
    staleThresholdDays,
    staleDetected: streams.some((stream) => stream.stale),
    streams,
  };
}

function formatEvidenceCell(stream) {
  if (stream.latestStable) {
    return `${stream.evidenceSource} ([run ${stream.latestStable.runId}](${stream.latestStable.runUrl}))`;
  }

  if (stream.latestObserved) {
    const observed = stream.latestObserved;
    const publishSuffix =
      typeof observed.published === 'boolean'
        ? `, published=${observed.published ? 'true' : 'false'}`
        : '';
    return `no stable publish; latest observed \`${observed.version}\` (${observed.channel}${publishSuffix}) ([run ${observed.runId}](${observed.runUrl}))`;
  }

  return 'no publish evidence';
}

export function buildIssueBody(report, marker = DEFAULT_MARKER) {
  const lines = [];
  lines.push(marker);
  lines.push('');
  lines.push(`# Package stream freshness (${report.checkedAtUtc})`);
  lines.push('');
  lines.push(`Threshold: **>${report.staleThresholdDays} days** without a stable publish.`);
  lines.push('');
  lines.push('Evidence source: successful publish workflow logs, not package-registry enumeration.');
  lines.push('');
  lines.push('| Stream | Latest stable ref | Latest publish (UTC) | Age (days) | Status | Evidence |');
  lines.push('|---|---|---|---:|---|---|');

  for (const stream of report.streams) {
    lines.push(
      `| ${stream.name} | \`${stream.latestStableRef}\` | ${stream.latestPublishUtc ?? 'missing'} | ${stream.ageDays ?? 'n/a'} | ${stream.stale ? 'stale' : 'fresh'} | ${formatEvidenceCell(stream)} |`
    );
  }

  lines.push('');

  if (report.staleDetected) {
    lines.push('## Action');
    lines.push('');

    for (const stream of report.streams.filter((candidate) => candidate.stale)) {
      if (stream.latestObserved) {
        lines.push(
          `- ${stream.name}: cut a stable publish or document intentional deferral. Latest observed run is \`${stream.latestObserved.version}\` (${stream.latestObserved.channel}) at ${stream.latestObserved.createdAt}.`
        );
      } else {
        lines.push(`- ${stream.name}: investigate missing publish evidence before treating the stream as current.`);
      }
    }
  } else {
    lines.push('All streams are currently fresh. This issue can remain closed.');
  }

  return `${lines.join('\n')}\n`;
}

export function buildStepSummary(report) {
  const lines = [];
  lines.push('## Release Cadence Check');
  lines.push('');
  lines.push(`- Checked at: \`${report.checkedAtUtc}\``);
  lines.push(`- Threshold: \`${report.staleThresholdDays}\` days`);
  lines.push(`- Evidence source: \`${RUN_EVIDENCE_SOURCE}\``);
  lines.push('');
  lines.push('| Stream | Latest stable ref | Latest publish | Age (days) | Status |');
  lines.push('| --- | --- | --- | ---: | --- |');

  for (const stream of report.streams) {
    lines.push(
      `| ${stream.name} | ${stream.latestStableRef} | ${stream.latestPublishUtc ?? 'missing'} | ${stream.ageDays ?? 'n/a'} | ${stream.stale ? 'stale' : 'fresh'} |`
    );
  }

  return `${lines.join('\n')}\n`;
}

function ensureParentDirectory(filePath) {
  const directory = path.dirname(filePath);
  if (directory && directory !== '.' && !fs.existsSync(directory)) {
    fs.mkdirSync(directory, { recursive: true });
  }
}

function writeJsonFile(filePath, value) {
  ensureParentDirectory(filePath);
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function writeTextFile(filePath, value) {
  ensureParentDirectory(filePath);
  fs.writeFileSync(filePath, value, 'utf8');
}

function appendStepSummary(filePath, markdown) {
  if (!filePath) {
    return;
  }
  ensureParentDirectory(filePath);
  fs.appendFileSync(filePath, markdown, 'utf8');
}

function runGhCommand(ghPath, args, { cwd = repoRoot } = {}) {
  const result = spawnSync(ghPath, args, {
    cwd,
    encoding: 'utf8',
    env: process.env,
  });

  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || `${ghPath} ${args.join(' ')} failed`);
  }

  return result.stdout;
}

function runGhJson(ghPath, args, options = {}) {
  return JSON.parse(runGhCommand(ghPath, args, options));
}

function fetchWorkflowRuns(ghPath, repo, workflowFile, maxRuns) {
  return runGhJson(ghPath, [
    'run',
    'list',
    '--repo',
    repo,
    '--workflow',
    workflowFile,
    '--limit',
    String(maxRuns),
    '--json',
    'databaseId,createdAt,displayTitle,event,headBranch,status,conclusion,url',
  ]);
}

function fetchRunLog(ghPath, repo, runId) {
  return runGhCommand(ghPath, ['run', 'view', String(runId), '--repo', repo, '--log']);
}

function parseIssueNumberFromUrl(url) {
  const match = /\/issues\/(\d+)$/.exec(String(url ?? ''));
  return match ? Number.parseInt(match[1], 10) : null;
}

function findExistingCadenceIssue(ghPath, repo, marker) {
  const issues = runGhJson(ghPath, [
    'issue',
    'list',
    '--repo',
    repo,
    '--state',
    'all',
    '--limit',
    '200',
    '--json',
    'number,title,body,state,url',
  ]);

  return issues.find((issue) => typeof issue.body === 'string' && issue.body.includes(marker)) ?? null;
}

function withTempBodyFile(bodyText, callback) {
  const tempDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-cadence-check-'));
  const bodyPath = path.join(tempDirectory, 'body.md');
  writeTextFile(bodyPath, bodyText);

  try {
    return callback(bodyPath);
  } finally {
    fs.rmSync(tempDirectory, { recursive: true, force: true });
  }
}

function reconcileIssue({ ghPath, repo, report, marker, issueTitle, bodyText, dryRun }) {
  const existing = findExistingCadenceIssue(ghPath, repo, marker);

  if (dryRun) {
    return {
      mode: 'dry-run',
      action: report.staleDetected ? (existing ? 'would-update' : 'would-create') : existing ? 'would-close' : 'none',
      issueNumber: existing?.number ?? null,
      issueUrl: existing?.url ?? null,
    };
  }

  if (report.staleDetected) {
    return withTempBodyFile(bodyText, (bodyPath) => {
      if (existing) {
        if (String(existing.state).toLowerCase() === 'closed') {
          runGhCommand(ghPath, ['issue', 'reopen', String(existing.number), '--repo', repo]);
        }

        runGhCommand(ghPath, [
          'issue',
          'edit',
          String(existing.number),
          '--repo',
          repo,
          '--title',
          issueTitle,
          '--body-file',
          bodyPath,
        ]);

        return {
          mode: 'live',
          action: 'updated',
          issueNumber: existing.number,
          issueUrl: existing.url,
        };
      }

      const createdUrl = runGhCommand(ghPath, [
        'issue',
        'create',
        '--repo',
        repo,
        '--title',
        issueTitle,
        '--body-file',
        bodyPath,
      ]).trim();

      return {
        mode: 'live',
        action: 'created',
        issueNumber: parseIssueNumberFromUrl(createdUrl),
        issueUrl: createdUrl,
      };
    });
  }

  if (existing && String(existing.state).toLowerCase() !== 'closed') {
    runGhCommand(ghPath, [
      'issue',
      'comment',
      String(existing.number),
      '--repo',
      repo,
      '--body',
      `Freshness check at ${report.checkedAtUtc}: all package streams are within the ${report.staleThresholdDays}-day window. Closing this issue.`,
    ]);
    runGhCommand(ghPath, ['issue', 'close', String(existing.number), '--repo', repo, '--reason', 'completed']);

    return {
      mode: 'live',
      action: 'closed',
      issueNumber: existing.number,
      issueUrl: existing.url,
    };
  }

  return {
    mode: 'live',
    action: 'none',
    issueNumber: existing?.number ?? null,
    issueUrl: existing?.url ?? null,
  };
}

export function runReleaseCadenceCheck(options, dependencies = {}) {
  const now = dependencies.now ?? new Date();
  const ghPath = options.ghPath || 'gh';
  const repo = options.repo;

  if (!repo) {
    throw new Error('Repository slug is required. Pass --repo <owner/repo> or set GITHUB_REPOSITORY.');
  }

  const toolsRuns =
    dependencies.toolsRuns ??
    fetchWorkflowRuns(ghPath, repo, 'publish-tools-image.yml', options.maxRuns ?? DEFAULT_MAX_RUNS);
  const sharedRuns =
    dependencies.sharedRuns ??
    fetchWorkflowRuns(ghPath, repo, 'publish-shared-package.yml', options.maxRuns ?? DEFAULT_MAX_RUNS);

  const report = evaluateReleaseCadence({
    now,
    staleThresholdDays: options.staleThresholdDays,
    toolsRuns,
    sharedRuns,
    fetchToolsRunLog:
      dependencies.fetchToolsRunLog ??
      ((run) => fetchRunLog(ghPath, repo, run.databaseId)),
    fetchSharedRunLog:
      dependencies.fetchSharedRunLog ??
      ((run) => fetchRunLog(ghPath, repo, run.databaseId)),
  });

  const body = buildIssueBody(report, options.marker);
  const stepSummary = buildStepSummary(report);
  const issue = reconcileIssue({
    ghPath,
    repo,
    report,
    marker: options.marker,
    issueTitle: options.issueTitle,
    bodyText: body,
    dryRun: options.dryRun,
  });

  const finalReport = {
    ...report,
    issue: {
      title: options.issueTitle,
      marker: options.marker,
      ...issue,
    },
  };

  if (options.outPath) {
    writeJsonFile(options.outPath, finalReport);
  }

  if (options.stepSummaryPath) {
    appendStepSummary(options.stepSummaryPath, stepSummary);
  }

  return finalReport;
}

export function buildUsageText() {
  return `Usage: node tools/priority/release-cadence-check.mjs [options]

Options:
  --repo <owner/repo>         Repository slug (defaults to GITHUB_REPOSITORY)
  --threshold-days <n>        Stale threshold in days (default: ${DEFAULT_THRESHOLD_DAYS})
  --max-runs <n>              Maximum workflow runs to fetch per stream (default: ${DEFAULT_MAX_RUNS})
  --out <path>                Write JSON report to this path
  --step-summary <path>       Append a Markdown summary to this file
  --marker <text>             Marker used to find/update the cadence issue
  --issue-title <title>       Title for the cadence issue
  --gh-path <path>            gh executable path (default: gh)
  --dry-run                   Evaluate and report without mutating issues
  --help                      Show this help text`;
}

function printUsage() {
  console.log(buildUsageText());
}

export function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`[release-cadence-check] ${error.message || error}`);
    printUsage();
    return 1;
  }

  if (options.help) {
    printUsage();
    return 0;
  }

  try {
    const report = runReleaseCadenceCheck(options);
    console.log(
      `[release-cadence-check] staleDetected=${report.staleDetected} issueAction=${report.issue.action} report=${
        options.outPath || 'none'
      }`
    );
    return 0;
  } catch (error) {
    console.error(`[release-cadence-check] ${error.message || error}`);
    return 1;
  }
}

if (isDirectExecution()) {
  process.exitCode = main();
}
