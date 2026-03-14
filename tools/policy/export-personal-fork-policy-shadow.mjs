#!/usr/bin/env node

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

export const POLICY_SHADOW_FILES = [
  '.github/workflows/policy-guard-upstream.yml',
  'tools/policy/branch-required-checks.json',
  'tools/priority/policy.json',
  'tools/policy/promotion-contract.json',
];

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    ref: null,
    workspaceRoot: '.',
    report: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--repo') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error('Missing value for --repo.');
      }
      options.repo = value;
      index += 1;
      continue;
    }
    if (arg === '--ref') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error('Missing value for --ref.');
      }
      options.ref = value;
      index += 1;
      continue;
    }
    if (arg === '--workspace-root') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error('Missing value for --workspace-root.');
      }
      options.workspaceRoot = value;
      index += 1;
      continue;
    }
    if (arg === '--report') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error('Missing value for --report.');
      }
      options.report = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${arg}`);
  }

  if (!options.repo) {
    throw new Error('Missing required --repo.');
  }
  if (!options.ref) {
    throw new Error('Missing required --ref.');
  }

  return options;
}

function encodeRepoPath(relativePath) {
  return String(relativePath)
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

async function resolveToken({
  env = process.env,
  readFileFn = readFile,
} = {}) {
  const direct = [env.GH_TOKEN, env.GITHUB_TOKEN]
    .map((value) => (typeof value === 'string' ? value.trim() : ''))
    .find(Boolean);
  if (direct) {
    return direct;
  }

  const filePath = typeof env.GH_TOKEN_FILE === 'string' ? env.GH_TOKEN_FILE.trim() : '';
  if (filePath) {
    const fromFile = (await readFileFn(filePath, 'utf8')).trim();
    if (fromFile) {
      return fromFile;
    }
  }

  return null;
}

async function requestGithubJson(url, token, fetchFn = globalThis.fetch) {
  if (typeof fetchFn !== 'function') {
    throw new Error('Global fetch is not available; provide fetchFn.');
  }

  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'policy-shadow-exporter',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetchFn(url, { headers });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub contents request failed (${response.status} ${response.statusText}): ${text}`);
  }

  return response.json();
}

export async function exportPersonalForkPolicyShadow({
  repo,
  ref,
  workspaceRoot = '.',
  report = null,
  fetchFn = globalThis.fetch,
  readFileFn = readFile,
  writeFileFn = writeFile,
  mkdirFn = mkdir,
  env = process.env,
} = {}) {
  if (!repo) {
    throw new Error('repo is required.');
  }
  if (!ref) {
    throw new Error('ref is required.');
  }

  const token = await resolveToken({ env, readFileFn });
  const resolvedWorkspaceRoot = path.resolve(workspaceRoot);
  const updatedFiles = [];

  for (const relativePath of POLICY_SHADOW_FILES) {
    const url =
      `https://api.github.com/repos/${repo}/contents/${encodeRepoPath(relativePath)}?ref=${encodeURIComponent(ref)}`;
    const payload = await requestGithubJson(url, token, fetchFn);
    if (payload?.type !== 'file') {
      throw new Error(`Unsupported GitHub contents payload for ${relativePath}: expected file.`);
    }
    if (payload?.encoding !== 'base64' || typeof payload?.content !== 'string') {
      throw new Error(`Unsupported encoding for ${relativePath}: expected base64 content.`);
    }

    const absolutePath = path.join(resolvedWorkspaceRoot, ...relativePath.split('/'));
    await mkdirFn(path.dirname(absolutePath), { recursive: true });
    const content = Buffer.from(payload.content, 'base64').toString('utf8');
    await writeFileFn(absolutePath, content, 'utf8');

    updatedFiles.push({
      path: relativePath,
      sha: payload.sha ?? null,
      size: typeof payload.size === 'number' ? payload.size : Buffer.byteLength(content, 'utf8'),
    });
  }

  const result = {
    schema: 'policy/personal-fork-shadow-export@v1',
    generatedAt: new Date().toISOString(),
    repository: repo,
    ref,
    workspaceRoot: resolvedWorkspaceRoot,
    files: updatedFiles,
  };

  if (report) {
    const reportPath = path.resolve(report);
    await mkdirFn(path.dirname(reportPath), { recursive: true });
    await writeFileFn(reportPath, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  }

  return result;
}

export async function main() {
  const options = parseArgs();
  const result = await exportPersonalForkPolicyShadow(options);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

const isEntrypoint = (() => {
  const invoked = process.argv[1] ? path.resolve(process.argv[1]) : null;
  return invoked === path.resolve(new URL(import.meta.url).pathname);
})();

if (isEntrypoint) {
  await main();
}
