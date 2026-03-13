#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { HookRunner, info, listStagedFiles } from './runner.mjs';

const runner = new HookRunner('pre-commit');

info('[pre-commit] Collecting staged files');

let stagedFiles = [];

runner.runStep('collect-staged', () => {
  stagedFiles = listStagedFiles();
  return {
    status: 'ok',
    exitCode: 0,
    stdout: stagedFiles.join('\n'),
    stderr: '',
  };
});

if (stagedFiles.length === 0) {
  info('[pre-commit] No staged files detected; skipping checks.');
  runner.addNote('No staged files; hook exited early.');
  runner.writeSummary();
  process.exit(0);
}

const psFiles = stagedFiles.filter((file) => file.match(/\.(ps1|psm1|psd1)$/i));
if (psFiles.length === 0) {
  info('[pre-commit] No staged PowerShell files detected; skipping PowerShell lint.');
  runner.addNote('No staged PowerShell files detected; PowerShell lint skipped.');
} else {
  const scriptPath = path.join('tools', 'hooks', 'scripts', 'pre-commit.ps1');
  info('[pre-commit] Running PowerShell validation script');
  runner.runPwshStep('powershell-validation', scriptPath, [], {
    env: {
      HOOKS_STAGED_FILES_JSON: JSON.stringify(psFiles),
    },
  });
}

const copilotReviewScriptPath = path.join(runner.repoRoot, 'tools', 'priority', 'copilot-cli-review.mjs');
info('[pre-commit] Running local Copilot CLI review on the staged diff');
runner.runStep('copilot-cli-review', () => {
  const result = spawnSync(
    process.execPath,
    [
      copilotReviewScriptPath,
      '--repo-root',
      runner.repoRoot,
      '--profile',
      'pre-commit',
      '--staged-files-json',
      JSON.stringify(stagedFiles)
    ],
    {
      cwd: runner.repoRoot,
      encoding: 'utf8',
      env: process.env
    }
  );

  if (result.error) {
    const error = new Error(`Failed to execute Copilot CLI review: ${result.error.message}`);
    error.exitCode = result.status ?? 1;
    error.stderr = result.stderr ?? '';
    throw error;
  }

  return {
    status: result.status === 0 ? 'ok' : 'failed',
    exitCode: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
});

runner.writeSummary();

if (runner.exitCode !== 0) {
  info('[pre-commit] Hook failed; see tests/results/_hooks/pre-commit.json for details.');
} else {
  info('[pre-commit] OK');
}

process.exit(runner.exitCode);
