import { spawn, spawnSync } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');

const nodeExecPath = process.env.npm_node_execpath || process.execPath;
const wrapperPath = path.join(repoRoot, 'tools', 'npm', 'run-script.mjs');

function runGit(args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    env: process.env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  return {
    status: result.status ?? (typeof result.signal === 'string' ? 128 : -1),
    stdout: (result.stdout ?? '').trim(),
    stderr: (result.stderr ?? '').trim()
  };
}

function gitRefExists(ref) {
  const probe = runGit(['show-ref', '--verify', '--quiet', ref]);
  return probe.status === 0;
}

function listGitRemotes() {
  const remotes = runGit(['remote']);
  if (remotes.status !== 0) {
    return [];
  }
  return remotes.stdout.split(/\s+/).filter(Boolean);
}

function ensureLocalBranch(branch, remotes) {
  const notes = [];
  if (gitRefExists(`refs/heads/${branch}`)) {
    return notes;
  }

  const preferred = ['upstream', 'origin'];
  const remoteOrder = [...new Set([...preferred.filter((name) => remotes.includes(name)), ...remotes])];

  for (const remote of remoteOrder) {
    const fetch = runGit(['fetch', '--depth=1', remote, `${branch}:refs/heads/${branch}`]);
    if (fetch.status !== 0) {
      continue;
    }

    notes.push(`Fetched ${branch} from ${remote} for dry-run helpers.`);
    return notes;
  }

  const fallback = runGit(['branch', branch]);
  if (fallback.status === 0) {
    notes.push(`Created local ${branch} from current HEAD (remote branch unavailable).`);
  } else {
    notes.push(`Failed to create local ${branch}: ${fallback.stderr || 'unknown error'}`);
  }

  return notes;
}

function ensureBaseBranchesAvailable() {
  const remotes = listGitRemotes();
  const branches = ['develop', 'main'];
  const notes = [];

  for (const branch of branches) {
    notes.push(...ensureLocalBranch(branch, remotes));
  }

  return notes;
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
  const notes = ensureBaseBranchesAvailable();

  if (!available) {
    notes.push(availabilityMessage || 'npm wrapper check failed');
  } else {
    const scripts = ['priority:test', 'hooks:test', 'semver:check', 'priority:policy'];
    const rawSkipPolicyEnv = process.env.PRIORITY_HANDOFF_SKIP_POLICY;
    const skipPolicyEnv = rawSkipPolicyEnv || '';
    const normalizedSkipPolicy = skipPolicyEnv.trim().toLowerCase();
    if (normalizedSkipPolicy && normalizedSkipPolicy !== '0' && normalizedSkipPolicy !== 'false') {
      scripts.pop();
    }
    for (const script of scripts) {
      const args = [wrapperPath, script];
      const { exitCode, stdout, stderr, startedAt, completedAt, durationMs, error } = await runCommand(nodeExecPath, args);
      let finalExitCode = exitCode;
      if (script === 'priority:policy' && exitCode !== 0) {
        if (
          stderr.includes('Resource not accessible by integration') ||
          stderr.includes('GitHub token not found')
        ) {
          notes.push('Skipped priority:policy due to missing or insufficient token permissions.');
          finalExitCode = 0;
        }
      }
      results.push({
        command: `node tools/npm/run-script.mjs ${script}`,
        exitCode: finalExitCode,
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
