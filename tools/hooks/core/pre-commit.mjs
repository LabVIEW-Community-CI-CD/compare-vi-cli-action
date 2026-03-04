#!/usr/bin/env node
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

const requirementsGateScriptPath = path.join('tools', 'Verify-RequirementsGate.ps1');
info('[pre-commit] Running requirements coverage gate');
const previousEnforcement = runner.enforcement;
runner.enforcement = 'fail';
runner.environment.enforcement = 'fail';
runner.runPwshStep('requirements-coverage-gate', requirementsGateScriptPath, []);
runner.enforcement = previousEnforcement;
runner.environment.enforcement = previousEnforcement;

runner.writeSummary();

if (runner.exitCode !== 0) {
  info('[pre-commit] Hook failed; see tests/results/_hooks/pre-commit.json for details.');
} else {
  info('[pre-commit] OK');
}

process.exit(runner.exitCode);
