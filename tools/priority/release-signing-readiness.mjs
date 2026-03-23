#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/release-signing-readiness-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'release-signing-readiness.json'
);
export const DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'release-conductor-report.json'
);
export const REQUIRED_SIGNING_SECRET = 'RELEASE_TAG_SIGNING_PRIVATE_KEY';
export const OPTIONAL_SIGNING_SECRET = 'RELEASE_TAG_SIGNING_PUBLIC_KEY';

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) return null;
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = asOptional(explicitRepo);
  if (explicit && explicit.includes('/')) {
    return explicit;
  }
  const envRepo = asOptional(environment.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }
  for (const remoteName of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) {
      continue;
    }
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) {
      return parsed;
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

function readOptionalJson(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(resolved, 'utf8'));
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function runGhJson(args, { cwd } = {}) {
  const result = spawnSync('gh', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const message = result.stderr?.trim() || result.stdout?.trim() || `gh ${args.join(' ')} failed (${result.status})`;
    throw new Error(message);
  }
  const text = String(result.stdout ?? '').trim();
  return text ? JSON.parse(text) : null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    repo: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    releaseConductorReportPath: DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--repo-root' || token === '--repo' || token === '--output' || token === '--release-conductor-report') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--release-conductor-report') options.releaseConductorReportPath = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  [
    'Usage: node tools/priority/release-signing-readiness.mjs [options]',
    '',
    'Options:',
    '  --repo-root <path>                 Repository root override.',
    '  --repo <owner/repo>                Repository slug override.',
    `  --output <path>                    Output JSON path (default: ${DEFAULT_OUTPUT_PATH}).`,
    `  --release-conductor-report <path>  Release conductor report path (default: ${DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH}).`,
    '  -h, --help                         Show help.'
  ].forEach((line) => console.log(line));
}

function hasSigningWorkflowContract(repoRoot) {
  const workflowPath = path.join(repoRoot, '.github', 'workflows', 'release-conductor.yml');
  if (!fs.existsSync(workflowPath)) {
    return {
      ready: false,
      workflowPath,
      reasons: ['release-conductor-workflow-missing']
    };
  }
  const workflow = fs.readFileSync(workflowPath, 'utf8');
  const requiredSnippets = [
    'Configure release tag signing material',
    'RELEASE_TAG_SIGNING_PRIVATE_KEY',
    'git config gpg.format ssh',
    'git config user.signingkey "$public_key_path"'
  ];
  const missing = requiredSnippets.filter((snippet) => !workflow.includes(snippet));
  return {
    ready: missing.length === 0,
    workflowPath,
    reasons: missing.map((snippet) => `missing-workflow-snippet:${snippet}`)
  };
}

function normalizeSecretInventory(payload) {
  const secrets = Array.isArray(payload?.secrets) ? payload.secrets : [];
  const names = new Set(secrets.map((entry) => String(entry?.name ?? '').trim()).filter(Boolean));
  const requiredPresent = names.has(REQUIRED_SIGNING_SECRET);
  const optionalPresent = names.has(OPTIONAL_SIGNING_SECRET);
  return {
    status: requiredPresent ? 'configured' : 'missing',
    requiredSecretPresent: requiredPresent,
    optionalPublicKeyPresent: optionalPresent,
    listedSecretCount: secrets.length,
    listedSecretNames: Array.from(names).sort()
  };
}

function derivePublicationState(conductorReport) {
  const release = conductorReport?.release ?? null;
  if (!release) {
    return {
      status: 'unobserved',
      tagCreated: false,
      tagPushed: false,
      targetTag: null
    };
  }
  const tagCreated = release.tagCreated === true;
  const tagPushed = release.tagPushed === true;
  return {
    status: tagPushed ? 'authoritative-publication-successful' : tagCreated ? 'tag-created-not-pushed' : 'not-attempted',
    tagCreated,
    tagPushed,
    targetTag: asOptional(release.targetTag)
  };
}

export async function runReleaseSigningReadiness(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot ?? process.cwd());
  const environment = deps.environment ?? process.env;
  const repository = resolveRepositorySlug(repoRoot, options.repo, environment);
  const outputPath = path.resolve(repoRoot, options.outputPath ?? DEFAULT_OUTPUT_PATH);
  const conductorReportPath = path.resolve(
    repoRoot,
    options.releaseConductorReportPath ?? DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH
  );
  const runGhJsonFn = deps.runGhJsonFn ?? runGhJson;
  const readOptionalJsonFn = deps.readOptionalJsonFn ?? readOptionalJson;
  const writeJsonFn = deps.writeJsonFn ?? writeJson;
  const now = deps.now ?? new Date();

  const workflowContract = hasSigningWorkflowContract(repoRoot);
  let secretInventory;
  try {
    const [owner, repo] = repository.split('/');
    const payload = runGhJsonFn(['api', `repos/${owner}/${repo}/actions/secrets?per_page=100`], { cwd: repoRoot });
    secretInventory = {
      ...normalizeSecretInventory(payload),
      source: 'github-actions-secrets-api',
      error: null
    };
  } catch (error) {
    secretInventory = {
      status: 'unverifiable',
      requiredSecretPresent: null,
      optionalPublicKeyPresent: null,
      listedSecretCount: null,
      listedSecretNames: [],
      source: 'github-actions-secrets-api',
      error: error?.message ?? String(error)
    };
  }

  const conductorReport = readOptionalJsonFn(conductorReportPath);
  const publication = derivePublicationState(conductorReport);
  const blockers = [];

  if (!workflowContract.ready) {
    blockers.push({
      code: 'workflow-signing-contract-missing',
      message: 'Release conductor workflow does not yet expose the workflow-owned signing contract.'
    });
  }
  if (secretInventory.status === 'missing') {
    blockers.push({
      code: 'workflow-signing-secret-missing',
      message: `${REQUIRED_SIGNING_SECRET} is not configured for the repository Actions secrets surface.`
    });
  } else if (secretInventory.status === 'unverifiable') {
    blockers.push({
      code: 'workflow-signing-secret-unverifiable',
      message: 'Unable to verify repository Actions secrets from the current automation identity.'
    });
  }

  const summary = {
    status: blockers.length === 0 ? 'pass' : 'warn',
    codePathState: workflowContract.ready ? 'ready' : 'missing-contract',
    signingCapabilityState:
      secretInventory.status === 'configured'
        ? 'configured'
        : secretInventory.status === 'missing'
          ? 'missing'
          : 'unverifiable',
    publicationState: publication.status,
    externalBlocker:
      blockers.find((entry) => entry.code === 'workflow-signing-secret-missing' || entry.code === 'workflow-signing-secret-unverifiable')
        ?.code ?? null,
    blockerCount: blockers.length
  };

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      releaseConductorReportPath: path.relative(repoRoot, conductorReportPath).replace(/\\/g, '/')
    },
    workflowContract: {
      ready: workflowContract.ready,
      workflowPath: path.relative(repoRoot, workflowContract.workflowPath).replace(/\\/g, '/'),
      reasons: workflowContract.reasons
    },
    secretInventory,
    publication,
    summary,
    blockers
  };

  const writtenPath = writeJsonFn(outputPath, report);
  return {
    report,
    outputPath: writtenPath,
    exitCode: summary.status === 'pass' ? 0 : 1
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const { report, outputPath, exitCode } = await runReleaseSigningReadiness(options);
  console.log(
    `[release-signing-readiness] wrote ${outputPath} status=${report.summary.status} externalBlocker=${report.summary.externalBlocker ?? 'none'}`
  );
  return exitCode;
}

const isDirectExecution =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isDirectExecution) {
  main().then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      console.error(`[release-signing-readiness] ${error.message}`);
      process.exitCode = 1;
    }
  );
}
