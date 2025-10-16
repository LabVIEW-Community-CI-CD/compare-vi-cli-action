import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');

const nodeExecPath = process.env.npm_node_execpath || process.execPath;
const npmCliPath = process.env.npm_execpath;
const fallbackNpm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
let npmCommand;
let npmArgsPrefix;

if (npmCliPath) {
  npmCommand = nodeExecPath;
  npmArgsPrefix = [npmCliPath, 'run'];
} else {
  npmCommand = fallbackNpm;
  npmArgsPrefix = ['run'];
}

function runCommand(command, args) {
  return new Promise((resolve) => {
    const startTime = new Date();
    let stdout = '';
    let stderr = '';
    let error;
    let settled = false;

    const child = spawn(command, args, {
      cwd: repoRoot,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    child.on('error', (err) => {
      error = err;
      if (settled) {
        return;
      }
      settled = true;
      const completedAt = new Date();
      resolve({
        exitCode: -1,
        stdout: stdout.trimEnd(),
        stderr: (stderr + err.message).trim(),
        startedAt: startTime,
        completedAt,
        durationMs: completedAt.getTime() - startTime.getTime(),
        error: err
      });
    });

    child.on('close', (code, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      const completedAt = new Date();
      const exitCode = typeof code === 'number' ? code : signal ? 128 : -1;
      resolve({
        exitCode,
        stdout: stdout.trimEnd(),
        stderr: stderr.trimEnd(),
        startedAt: startTime,
        completedAt,
        durationMs: completedAt.getTime() - startTime.getTime(),
        error
      });
    });
  });
}

async function ensureNpmAvailable() {
  if (npmCliPath) {
    return { available: true };
  }

  const check = await runCommand(npmCommand, ['--version']);
  if (check.error && check.error.code === 'ENOENT') {
    return {
      available: false,
      message: 'npm executable not found in PATH',
      error: check.error
    };
  }

  if (check.exitCode !== 0) {
    const parts = [`npm --version exited with code ${check.exitCode}`];
    if (check.stderr) {
      parts.push(`stderr: ${check.stderr}`);
    }
    return {
      available: false,
      message: parts.join('; '),
      error: check.error
    };
  }

  return { available: true };
}

async function run() {
  const { available, message: availabilityMessage } = await ensureNpmAvailable();
  const results = [];
  const notes = [];

  if (!available) {
    notes.push(availabilityMessage || 'npm executable check failed');
  } else {
    const scripts = ['priority:test', 'hooks:test', 'semver:check'];
    for (const script of scripts) {
      const args = [...npmArgsPrefix, script];
      const { exitCode, stdout, stderr, startedAt, completedAt, durationMs, error } = await runCommand(npmCommand, args);
      results.push({
        command: `npm run ${script}`,
        exitCode,
        stdout,
        stderr,
        startedAt: startedAt.toISOString(),
        completedAt: completedAt.toISOString(),
        durationMs
      });

      if (error) {
        notes.push(`Invocation for npm run ${script} failed: ${error.message}`);
        break;
      }
    }
  }

  const handoffDir = path.join(repoRoot, 'tests', 'results', '_agent', 'handoff');
  await fs.mkdir(handoffDir, { recursive: true });
  const summaryPath = path.join(handoffDir, 'test-summary.json');

  const failureCount = results.filter((entry) => entry.exitCode !== 0).length;
  let status;
  if (!available) {
    status = 'error';
  } else if (results.length === 0) {
    status = 'skipped';
  } else if (failureCount > 0) {
    status = 'failed';
  } else {
    status = 'passed';
  }

  const summary = {
    schema: 'agent-handoff/test-results@v1',
    generatedAt: new Date().toISOString(),
    status,
    total: results.length,
    failureCount,
    results,
    runner: {
      name: process.env.RUNNER_NAME,
      os: process.env.RUNNER_OS,
      arch: process.env.RUNNER_ARCH,
      job: process.env.GITHUB_JOB,
      imageOS: process.env.ImageOS,
      imageVersion: process.env.ImageVersion
    }
  };

  if (notes.length > 0) {
    summary.notes = notes;
  }

  await fs.writeFile(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
  console.log(
    `[handoff-tests] status=${status} total=${summary.total} failures=${failureCount} -> ${summaryPath}`
  );

  if (status === 'error' || failureCount > 0) {
    process.exitCode = 1;
  }
}

run().catch((error) => {
  console.error('[handoff-tests] Unexpected failure:', error);
  process.exitCode = 1;
});
