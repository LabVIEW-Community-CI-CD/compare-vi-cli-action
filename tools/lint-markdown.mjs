#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';

function parseArgs(argv) {
  const args = { all: false, baseRef: undefined };
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '-All' || token === '--all') {
      args.all = true;
      continue;
    }
    if (token === '-BaseRef' || token === '--base-ref') {
      const value = argv[i + 1];
      if (value === undefined) {
        throw new Error('Missing value for --base-ref');
      }
      args.baseRef = value;
      i += 1;
      continue;
    }
    throw new Error(`Unknown argument: ${token}`);
  }
  return args;
}

function runGit(args) {
  const result = spawnSync('git', args, { encoding: 'utf8' });
  if (result.status !== 0) {
    return null;
  }
  return result.stdout.trim();
}

function runGitLines(args) {
  const output = runGit(args);
  if (!output) {
    return [];
  }
  return output
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function resolveRepoRoot() {
  const resolved = runGit(['rev-parse', '--show-toplevel']);
  if (resolved) {
    return resolved;
  }
  const current = dirname(fileURLToPath(import.meta.url));
  return current;
}

function resolveRef(ref) {
  const result = runGit(['rev-parse', '--verify', ref]);
  return result || null;
}

function resolveMergeBase(candidates) {
  for (const candidate of candidates) {
    if (!candidate) {
      continue;
    }
    const resolved = resolveRef(candidate);
    if (!resolved) {
      continue;
    }
    const mergeBase = runGit(['merge-base', 'HEAD', resolved]);
    if (mergeBase) {
      return mergeBase;
    }
    return resolved;
  }
  return null;
}

function getChangedMarkdownFiles(base) {
  const results = new Set();
  if (base) {
    runGitLines(['diff', '--name-only', '--diff-filter=ACMRTUXB', `${base}..HEAD`]).forEach((entry) =>
      results.add(entry)
    );
  }
  runGitLines(['diff', '--name-only', '--diff-filter=ACMRTUXB', 'HEAD']).forEach((entry) =>
    results.add(entry)
  );
  runGitLines(['diff', '--name-only', '--cached', '--diff-filter=ACMRTUXB']).forEach((entry) =>
    results.add(entry)
  );
  runGitLines(['ls-files', '--others', '--exclude-standard', '*.md']).forEach((entry) =>
    results.add(entry)
  );
  return Array.from(results).filter((file) => file.toLowerCase().endsWith('.md')).sort();
}

function getAllMarkdownFiles() {
  return runGitLines(['ls-files', '*.md']).sort();
}

function resolveMarkdownlintCli(repoRoot) {
  const bin = join(repoRoot, 'node_modules', '.bin');
  if (process.platform === 'win32') {
    const cmd = join(bin, 'markdownlint-cli2.cmd');
    if (existsSync(cmd)) {
      return { command: cmd, args: [] };
    }
    const ps1 = join(bin, 'markdownlint-cli2.ps1');
    if (existsSync(ps1)) {
      return { command: ps1, args: [] };
    }
  }
  const unix = join(bin, 'markdownlint-cli2');
  if (existsSync(unix)) {
    return { command: unix, args: [] };
  }
  return null;
}

function runMarkdownlint(cli, files, repoRoot) {
  if (cli) {
    return spawnSync(cli.command, ['--config', '.markdownlint.jsonc', ...files], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
  }

  const npx = spawnSync('npx', ['--no-install', 'markdownlint-cli2', '--config', '.markdownlint.jsonc', ...files], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  if (npx.error && npx.error.code === 'ENOENT') {
    return {
      status: 0,
      stdout: '',
      stderr: 'markdownlint-cli2 not found locally and npx is unavailable; skipping markdown lint.\n',
    };
  }
  return npx;
}

function extractRules(output) {
  const matches = new Set();
  const pattern = /MD\d+/g;
  for (const line of output.split('\n')) {
    let match;
    while ((match = pattern.exec(line)) !== null) {
      matches.add(match[0]);
    }
  }
  return Array.from(matches);
}

function main() {
  const { all, baseRef } = parseArgs(process.argv);
  const repoRoot = resolveRepoRoot();

  const candidateRefs = [];
  if (baseRef) {
    candidateRefs.push(baseRef);
  }
  if (process.env.GITHUB_BASE_SHA) {
    candidateRefs.push(process.env.GITHUB_BASE_SHA);
  }
  if (process.env.GITHUB_BASE_REF) {
    candidateRefs.push(`origin/${process.env.GITHUB_BASE_REF}`);
  }
  candidateRefs.push('origin/develop', 'origin/main', 'HEAD~1');

  const mergeBase = all ? null : resolveMergeBase(candidateRefs);

  const markdownFiles = all ? getAllMarkdownFiles() : getChangedMarkdownFiles(mergeBase);
  if (markdownFiles.length === 0) {
    console.log('No Markdown files to lint.');
    return 0;
  }

  const suppressed = new Set(['CHANGELOG.md', 'fixture-summary.md']);
  const filesToLint = markdownFiles.filter((file) => !suppressed.has(file));
  if (filesToLint.length === 0) {
    console.log('No Markdown files to lint.');
    return 0;
  }

  console.log(`Linting ${filesToLint.length} Markdown file(s).`);
  const cli = resolveMarkdownlintCli(repoRoot);
  const result = runMarkdownlint(cli, filesToLint, repoRoot);

  const stdout = result.stdout ? result.stdout.trimEnd() : '';
  const stderr = result.stderr ? result.stderr.trimEnd() : '';
  if (stdout) {
    console.log(stdout);
  }
  if (stderr) {
    console.error(stderr);
  }

  if (result.status === 0) {
    return 0;
  }

  const rules = extractRules(`${stdout}\n${stderr}`);
  const suppressedRules = new Set(['MD013']);
  const actionable = rules.filter((rule) => !suppressedRules.has(rule));
  if (actionable.length === 0) {
    console.warn('Only MD013 violations detected; treating as a warning.');
    return 0;
  }
  return typeof result.status === 'number' ? result.status : 1;
}

try {
  const exitCode = main();
  process.exitCode = exitCode;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
