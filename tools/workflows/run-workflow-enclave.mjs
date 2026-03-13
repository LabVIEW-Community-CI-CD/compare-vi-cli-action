#!/usr/bin/env node

import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const workflowEnclavePath = path.join(scriptDir, 'workflow_enclave.py');

function canRun(command, args = []) {
  const probe = spawnSync(command, args, {
    stdio: 'ignore',
    windowsHide: true
  });
  return probe.status === 0;
}

function resolvePythonCommand() {
  if (process.env.COMPAREVI_PYTHON_EXE) {
    return [process.env.COMPAREVI_PYTHON_EXE];
  }

  if (process.platform === 'win32' && canRun('py', ['-3', '--version'])) {
    return ['py', '-3'];
  }

  if (canRun('python3', ['--version'])) {
    return ['python3'];
  }

  if (canRun('python', ['--version'])) {
    return ['python'];
  }

  throw new Error('Unable to locate a Python interpreter. Set COMPAREVI_PYTHON_EXE or install python3/python.');
}

try {
  const pythonCommand = resolvePythonCommand();
  const completed = spawnSync(pythonCommand[0], [...pythonCommand.slice(1), workflowEnclavePath, ...process.argv.slice(2)], {
    stdio: 'inherit',
    windowsHide: true
  });

  if (typeof completed.status === 'number') {
    process.exit(completed.status);
  }

  process.exit(1);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
