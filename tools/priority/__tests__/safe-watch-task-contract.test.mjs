#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse as parseJsonc } from 'jsonc-parser';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

const FILE_CONTRACTS = [
  {
    file: '.vscode/tasks.json',
    label: 'CI: Watch PR checks (safe snapshot)',
    inputId: 'watchPrNumber',
    expectedCwd: '${workspaceFolder}'
  },
  {
    file: 'compare-vi-cli-action.command-center.code-workspace',
    label: 'Command Center: watch PR checks (safe, fork plane)',
    inputId: 'watchPullRequest',
    expectedCwd: '${workspaceFolder:PLANE_FORK__compare-vi-cli-action}'
  },
  {
    file: 'compare-vi-cli-action.code-workspace',
    label: 'Command Center: watch PR checks (safe, fork plane)',
    inputId: 'watchPullRequest',
    expectedCwd: '${workspaceFolder:PLANE_FORK__compare-vi-cli-action}'
  },
  {
    file: 'compare-vi-cli-action.fork-plane.code-workspace',
    label: 'Fork Plane: watch PR checks (safe)',
    inputId: 'forkWatchPullRequest',
    expectedCwd: '${workspaceFolder:PLANE_FORK__compare-vi-cli-action}'
  },
  {
    file: 'compare-vi-cli-action.upstream-plane.code-workspace',
    label: 'Upstream Plane: watch PR checks (safe)',
    inputId: 'upstreamWatchPullRequest',
    expectedCwd: '${workspaceFolder:PLANE_UPSTREAM__compare-vi-cli-action}'
  }
];

function readJsonc(relativePath) {
  const absolutePath = path.join(repoRoot, relativePath);
  const text = readFileSync(absolutePath, 'utf8');
  const parsed = parseJsonc(text);
  return { absolutePath, parsed };
}

function findTaskContainer(parsed) {
  if (Array.isArray(parsed?.tasks)) {
    return { tasks: parsed.tasks, inputs: parsed.inputs ?? [] };
  }
  return {
    tasks: parsed?.tasks?.tasks ?? [],
    inputs: parsed?.tasks?.inputs ?? []
  };
}

function assertSafeWatcherArgs(task, inputId) {
  const args = task?.args ?? [];
  assert.ok(Array.isArray(args), `Task '${task?.label ?? '<unknown>'}' args must be an array`);
  assert.ok(args.includes('ci:watch:safe'), `Task '${task.label}' must call ci:watch:safe`);
  assert.ok(args.includes('--PullRequest'), `Task '${task.label}' must pass --PullRequest`);
  assert.ok(args.includes(`\${input:${inputId}}`), `Task '${task.label}' must reference input ${inputId}`);

  const intervalIndex = args.indexOf('-IntervalSeconds');
  assert.ok(intervalIndex >= 0, `Task '${task.label}' must include -IntervalSeconds`);
  assert.equal(String(args[intervalIndex + 1]), '20', `Task '${task.label}' must set -IntervalSeconds 20`);

  const heartbeatIndex = args.indexOf('-HeartbeatPolls');
  assert.ok(heartbeatIndex >= 0, `Task '${task.label}' must include -HeartbeatPolls`);
  assert.equal(String(args[heartbeatIndex + 1]), '3', `Task '${task.label}' must set -HeartbeatPolls 3`);
}

test('safe PR watch task contract is enforced across committed workspace configs', () => {
  for (const contract of FILE_CONTRACTS) {
    const { parsed } = readJsonc(contract.file);
    const { tasks, inputs } = findTaskContainer(parsed);

    const safeTask = tasks.find((task) => task?.label === contract.label);
    assert.ok(safeTask, `${contract.file} must contain task '${contract.label}'`);
    assert.equal(safeTask.command, 'node', `Task '${contract.label}' in ${contract.file} must use node command`);
    assert.equal(
      safeTask?.options?.cwd,
      contract.expectedCwd,
      `Task '${contract.label}' in ${contract.file} must use cwd '${contract.expectedCwd}'`
    );

    assertSafeWatcherArgs(safeTask, contract.inputId);

    const input = inputs.find((entry) => entry?.id === contract.inputId);
    assert.ok(input, `${contract.file} must define input '${contract.inputId}'`);
    assert.equal(input.type, 'promptString', `Input '${contract.inputId}' in ${contract.file} must be promptString`);
  }
});
