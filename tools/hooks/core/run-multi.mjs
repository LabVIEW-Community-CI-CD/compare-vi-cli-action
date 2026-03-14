#!/usr/bin/env node
import * as fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { HookRunner, info, findGitRoot, which } from './runner.mjs';
import { normalizeSummary } from './summary-utils.mjs';

const runner = new HookRunner('hooks-multi');
const repoRoot = findGitRoot();
const resultsDir = path.join(repoRoot, 'tests', 'results', '_hooks');
fs.mkdirSync(resultsDir, { recursive: true });

const pwshPath = runner.resolvePwsh();
let bashPath = which('bash') || null;
if (process.platform === 'win32') {
  const gitBash = 'C:/Program Files/Git/bin/bash.exe';
  if (fs.existsSync(gitBash)) {
    bashPath = gitBash;
  }
}
const toPosix = (value) => value.replace(/\\/g, '/');
const fastPrePushEnv = {
  PREPUSH_SKIP_LEGACY_FIXTURE_CHECKS: process.env.PREPUSH_SKIP_LEGACY_FIXTURE_CHECKS || '1',
  PREPUSH_SKIP_NI_IMAGE_FLAG_SCENARIOS: process.env.PREPUSH_SKIP_NI_IMAGE_FLAG_SCENARIOS || '1'
};

info('[hooks multi] base plane: ' + runner.environment.plane);
info('[hooks multi] enforcement: ' + runner.enforcement);
info('[hooks multi] node: ' + runner.environment.nodeVersion);
info('[hooks multi] pwsh: ' + (pwshPath || 'not found'));
info('[hooks multi] bash: ' + (bashPath || 'not found'));

const combos = [];

if (bashPath && fs.existsSync(bashPath)) {
  const preCommitShellScript = toPosix(path.join('tools', 'hooks', 'pre-commit'));
  const postCommitShellScript = toPosix(path.join('tools', 'hooks', 'post-commit'));
  const prePushShellScript = toPosix(path.join('tools', 'hooks', 'pre-push'));
  combos.push({ hook: 'pre-commit', label: 'shell', command: bashPath, args: [preCommitShellScript] });
  combos.push({ hook: 'post-commit', label: 'shell', command: bashPath, args: [postCommitShellScript] });
  combos.push({ hook: 'pre-push', label: 'shell', command: bashPath, args: [prePushShellScript] });
} else {
  info('[hooks multi] bash not available; skipping shell wrappers.');
}

if (pwshPath) {
  combos.push({ hook: 'pre-commit', label: 'pwsh', command: pwshPath, args: ['-NoLogo', '-NoProfile', '-File', path.join('tools', 'hooks', 'pre-commit.ps1')] });
  combos.push({ hook: 'post-commit', label: 'pwsh', command: pwshPath, args: ['-NoLogo', '-NoProfile', '-File', path.join('tools', 'hooks', 'post-commit.ps1')] });
  combos.push({ hook: 'pre-push', label: 'pwsh', command: pwshPath, args: ['-NoLogo', '-NoProfile', '-File', path.join('tools', 'hooks', 'pre-push.ps1')] });
} else {
  info('[hooks multi] PowerShell not available; skipping PowerShell wrappers.');
}

if (combos.length === 0) {
  console.error('[hooks multi] No wrappers available to execute.');
  process.exit(2);
}

function runWrapper(entry) {
  const summaryFile = path.join(resultsDir, entry.hook + '.json');
  try {
    fs.unlinkSync(summaryFile);
  } catch (err) {
    if (err.code !== 'ENOENT') {
      throw err;
    }
  }

  info('[hooks multi] running ' + entry.hook + ' via ' + entry.label);
  const result = spawnSync(entry.command, entry.args, {
    cwd: repoRoot,
    stdio: 'inherit',
    env: {
      ...process.env,
      HOOKS_ENFORCE: runner.enforcement,
      DETERMINISTIC: '1',
      HOOKS_NODE: process.execPath,
      ...fastPrePushEnv,
      ...(pwshPath ? { HOOKS_PWSH: pwshPath } : {}),
    },
  });

  if (result.status !== 0) {
    throw new Error('Wrapper ' + entry.hook + '/' + entry.label + ' exited with code ' + result.status);
  }

  if (!fs.existsSync(summaryFile)) {
    throw new Error('Expected summary at ' + summaryFile + ' was not produced.');
  }

  const labeled = path.join(resultsDir, entry.hook + '.' + entry.label + '.json');
  fs.copyFileSync(summaryFile, labeled);
  return labeled;
}

function compareSummaries(hook, labels) {
  if (labels.length < 2) {
    return 0;
  }
  const baseLabel = labels[0];
  const basePath = path.join(resultsDir, hook + '.' + baseLabel + '.json');
  const baseData = JSON.parse(fs.readFileSync(basePath, 'utf8'));
  const baseNormalized = normalizeSummary(baseData);
  let differences = 0;

  for (let i = 1; i < labels.length; i += 1) {
    const compareLabel = labels[i];
    const comparePath = path.join(resultsDir, hook + '.' + compareLabel + '.json');
    const compareData = JSON.parse(fs.readFileSync(comparePath, 'utf8'));
    const compareNormalized = normalizeSummary(compareData);

    const baseString = JSON.stringify(baseNormalized, null, 2);
    const compareString = JSON.stringify(compareNormalized, null, 2);
    if (baseString !== compareString) {
      console.error('[hooks multi] Difference detected for ' + hook + ' (' + baseLabel + ' vs ' + compareLabel + ')');
      console.error('--- ' + baseLabel);
      console.error(baseString);
      console.error('--- ' + compareLabel);
      console.error(compareString);
      differences += 1;
    }
  }

  return differences;
}

const perHookLabels = new Map();
let combosExecuted = 0;

for (const entry of combos) {
  try {
    const labeledPath = runWrapper(entry);
    const labels = perHookLabels.get(entry.hook) || [];
    labels.push(entry.label);
    perHookLabels.set(entry.hook, labels);
    combosExecuted += 1;
  } catch (err) {
    console.error('[hooks multi] ' + err.message);
    const exitCode = typeof err.exitCode === 'number' ? err.exitCode : 1;
    process.exit(exitCode);
  }
}

info('[hooks multi] wrappers executed: ' + combosExecuted);

let diffCount = 0;
for (const [hook, labels] of perHookLabels.entries()) {
  diffCount += compareSummaries(hook, labels);
}

if (diffCount > 0) {
  console.error('[hooks multi] Hook summaries differ across planes (' + diffCount + ' difference(s)).');
  process.exit(1);
}

info('[hooks multi] Summaries match across evaluated planes.');
process.exit(0);
