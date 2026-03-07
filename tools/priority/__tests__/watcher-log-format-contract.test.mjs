#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('orchestrated watcher source keeps explicit log-level prefixes for live console output', () => {
  const source = readRepoFile('tools/watchers/orchestrated-watch.ts');

  assert.match(source, /import \{ existsSync, mkdirSync, writeFileSync \} from 'node:fs';/);
  assert.match(source, /type WatcherLogLevel = 'info' \| 'warn' \| 'error';/);
  assert.match(source, /const line = `\[\$\{level\}\] \$\{message\}`;/);
  assert.match(source, /schema: 'comparevi\/runtime-event\/v1'/);
  assert.match(source, /parser\.add_argument\('--events-out'/);
  assert.match(source, /defaults to watcher-events\.ndjson next to --out/);
  assert.match(source, /path: string;/);
  assert.match(source, /present: existsSync\(events\.outPath\),/);
  assert.doesNotMatch(source, /source: events\.source,/);
  assert.match(source, /emitLog\('info', `watching run=\$\{runId\} repo=\$\{repo\}`,/);
  assert.match(source, /emitLog\('info', `status=\$\{status\} conclusion=\$\{conclusion \|\| 'n\/a'\}`,/);
  assert.ok(source.includes('heartbeat run="${title}" status=${status} conclusion=${conclusion || \'n/a\'} jobs=${completedJobs}/${totalJobs} elapsed~${elapsedSeconds}s'));
  assert.match(source, /emitLog\('warn', `run=\$\{runId\} matches current workflow; skipping self-watch to avoid deadlock\.`,/);
  assert.match(source, /emitLog\('error', `fatal: \$\{\(err as Error\)\.message\}`\);/);
});

test('pester artifact watcher prefixes informational and warning lines with severity labels', () => {
  const source = readRepoFile('tools/follow-pester-artifacts.mjs');

  assert.match(source, /console\.log\(`\[info\] \$\{message\}`\);/);
  assert.match(source, /console\.warn\(`\[warn\] \$\{message\}`\);/);
  assert.match(source, /parser\.add_argument\('--events-file'/);
  assert.match(source, /defaults to <results>\/pester-watcher-events\.ndjson/);
  assert.match(source, /schema: 'comparevi\/runtime-event\/v1'/);
  assert.match(source, /source: 'pester-artifact-watcher'/);
  assert.match(source, /events: getRuntimeEventMetadata\(\)/);
});

test('dispatcher source keeps explicit info-level execution and progress lines', () => {
  const source = readRepoFile('Invoke-PesterTests.ps1');

  assert.match(source, /function Write-DispatcherConsoleLine/);
  assert.match(source, /schema\s+=\s+'comparevi\/runtime-event\/v1'/);
  assert.ok(source.includes("[info] Executing Pester tests...") || source.includes("Write-DispatcherConsoleLine -Level info -Phase 'execution' -Message 'Executing Pester tests...'"));
  assert.ok(source.includes('execution-mode: singleInvoker='));
  assert.ok(source.includes('pester-progress: state={0} elapsed~{1}s timeout={2}s partialLog={3}'));
});
