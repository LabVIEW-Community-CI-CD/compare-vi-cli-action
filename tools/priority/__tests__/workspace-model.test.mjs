#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

const WORKSPACE_FILES = {
  upstream: 'compare-vi-cli-action.upstream-plane.code-workspace',
  fork: 'compare-vi-cli-action.fork-plane.code-workspace',
  commandCenter: 'compare-vi-cli-action.command-center.code-workspace',
  legacyAlias: 'compare-vi-cli-action.code-workspace'
};

function readWorkspace(fileName) {
  const fullPath = path.join(repoRoot, fileName);
  const parsed = JSON.parse(readFileSync(fullPath, 'utf8'));
  return { fullPath, parsed };
}

function assertTasksUseNamedWorkspaceCwd(workspace) {
  const tasks = workspace?.tasks?.tasks ?? [];
  for (const task of tasks) {
    const cwd = task?.options?.cwd ?? '';
    assert.match(
      String(cwd),
      /^\$\{workspaceFolder:[^}]+\}$/,
      `Task '${task?.label ?? '<unknown>'}' must pin cwd to a named workspace folder`
    );
  }
}

test('workspace files parse as JSON and expose folders', () => {
  for (const fileName of Object.values(WORKSPACE_FILES)) {
    const { parsed } = readWorkspace(fileName);
    assert.ok(Array.isArray(parsed.folders), `${fileName} must define folders[]`);
    assert.ok(parsed.folders.length > 0, `${fileName} must include at least one folder`);
  }
});

test('upstream and fork plane workspaces enforce explicit plane folder names', () => {
  const upstream = readWorkspace(WORKSPACE_FILES.upstream).parsed;
  const fork = readWorkspace(WORKSPACE_FILES.fork).parsed;

  assert.equal(upstream.folders.length, 1);
  assert.equal(fork.folders.length, 1);
  assert.equal(upstream.folders[0].name, 'PLANE_UPSTREAM__compare-vi-cli-action');
  assert.equal(fork.folders[0].name, 'PLANE_FORK__compare-vi-cli-action');
});

test('command center workspace includes both planes', () => {
  const commandCenter = readWorkspace(WORKSPACE_FILES.commandCenter).parsed;
  const names = commandCenter.folders.map((folder) => folder?.name);

  assert.ok(names.includes('PLANE_UPSTREAM__compare-vi-cli-action'));
  assert.ok(names.includes('PLANE_FORK__compare-vi-cli-action'));
});

test('workspace tasks pin execution cwd to named workspace folders', () => {
  assertTasksUseNamedWorkspaceCwd(readWorkspace(WORKSPACE_FILES.upstream).parsed);
  assertTasksUseNamedWorkspaceCwd(readWorkspace(WORKSPACE_FILES.fork).parsed);
  assertTasksUseNamedWorkspaceCwd(readWorkspace(WORKSPACE_FILES.commandCenter).parsed);
  assertTasksUseNamedWorkspaceCwd(readWorkspace(WORKSPACE_FILES.legacyAlias).parsed);
});
