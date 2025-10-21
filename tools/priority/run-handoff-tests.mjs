import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');

const nodeExecPath = process.env.npm_node_execpath || process.execPath;
const wrapperPath = path.join(repoRoot, 'tools', 'npm', 'run-script.mjs');

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

async function ensureWrapperAvailable() {
  try {
    await fs.access(wrapperPath);
    return { available: true };
  } catch (error) {
    return {
      available: false,
      message: 'npm wrapper missing under tools/npm/run-script.mjs',
      error
    };
  }
}

async function run() {
  const { available, message: availabilityMessage } = await ensureWrapperAvailable();
  const results = [];
  const notes = [];

  if (!available) {
    notes.push(availabilityMessage || 'npm wrapper check failed');
  } else {
    const scripts = ['priority:test', 'hooks:test', 'semver:check', 'priority:policy'];
    const skipPolicy = (process.env.PRIORITY_HANDOFF_SKIP_POLICY || '').toLowerCase();
    if (skipPolicy && skipPolicy !== '0' && skipPolicy !== 'false') {
      scripts.pop();
    }
    for (const script of scripts) {
      const args = [wrapperPath, script];
      const { exitCode, stdout, stderr, startedAt, completedAt, durationMs, error } = await runCommand(nodeExecPath, args);
      results.push({
        command: `node tools/npm/run-script.mjs ${script}`,
        exitCode,
        stdout,
        stderr,
        startedAt: startedAt.toISOString(),
        completedAt: completedAt.toISOString(),
        durationMs
      });

      if (error) {
        notes.push(`Invocation for node tools/npm/run-script.mjs ${script} failed: ${error.message}`);
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

  if (failureCount > 0) {
    for (const entry of results.filter((item) => item.exitCode !== 0)) {
      console.error(
        `[handoff-tests] command failed: ${entry.command}\nstdout:\n${entry.stdout || '(empty)'}\n\nstderr:\n${entry.stderr || '(empty)'}\n`
      );
    }
  }

  if (status === 'error' || failureCount > 0) {
    process.exitCode = 1;
  }
}

run().catch((error) => {
  console.error('[handoff-tests] Unexpected failure:', error);
  process.exitCode = 1;
});
