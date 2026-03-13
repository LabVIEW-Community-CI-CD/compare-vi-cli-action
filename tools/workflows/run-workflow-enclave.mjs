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

function canRunPython3(command, args = []) {
  return canRun(command, [
    ...args,
    '-c',
    'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)'
  ]);
}

function resolvePythonCommand() {
  if (process.env.COMPAREVI_PYTHON_EXE) {
    if (!canRunPython3(process.env.COMPAREVI_PYTHON_EXE)) {
      throw new Error('COMPAREVI_PYTHON_EXE must resolve to a Python 3 interpreter.');
    }
    return [process.env.COMPAREVI_PYTHON_EXE];
  }

  if (process.platform === 'win32' && canRunPython3('py', ['-3'])) {
    return ['py', '-3'];
  }

  if (canRunPython3('python3')) {
    return ['python3'];
  }

  if (canRunPython3('python')) {
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
