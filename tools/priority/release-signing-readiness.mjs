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
export const DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'release-published-bundle-observer.json'
);
export const REQUIRED_SIGNING_SECRET = 'RELEASE_TAG_SIGNING_PRIVATE_KEY';
export const OPTIONAL_SIGNING_SECRET = 'RELEASE_TAG_SIGNING_PUBLIC_KEY';
export const REQUIRED_SIGNING_SCOPE = 'admin:ssh_signing_key';
export const RELEASE_CONDUCTOR_ENABLE_VARIABLE = 'RELEASE_CONDUCTOR_ENABLED';

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
    releasePublishedBundleObserverPath: DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (
      token === '--repo-root' ||
      token === '--repo' ||
      token === '--output' ||
      token === '--release-conductor-report' ||
      token === '--release-published-bundle-observer'
    ) {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--release-conductor-report') options.releaseConductorReportPath = next;
      if (token === '--release-published-bundle-observer') options.releasePublishedBundleObserverPath = next;
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
    `  --release-published-bundle-observer <path> Published bundle observer path (default: ${DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH}).`,
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
    'RELEASE_TAG_SIGNING_IDENTITY_NAME',
    'RELEASE_TAG_SIGNING_IDENTITY_EMAIL',
    "gh api user --jq '.login'",
    'git config gpg.format ssh',
    'git config user.signingkey "$public_key_path"',
    'git config user.name "$signing_name"',
    'git config user.email "$signing_email"'
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

function normalizeVariableInventory(payload) {
  const variables = Array.isArray(payload?.variables) ? payload.variables : [];
  const values = new Map(
    variables
      .map((entry) => [String(entry?.name ?? '').trim(), asOptional(entry?.value)])
      .filter(([name]) => Boolean(name))
  );
  const configuredValue = values.get(RELEASE_CONDUCTOR_ENABLE_VARIABLE) ?? null;
  const enabled = configuredValue === '1';
  return {
    status: enabled ? 'enabled' : 'disabled',
    variablePresent: values.has(RELEASE_CONDUCTOR_ENABLE_VARIABLE),
    enabled,
    configuredValue,
    listedVariableCount: variables.length,
    listedVariableNames: Array.from(values.keys()).sort()
  };
}

function normalizeSigningAuthority(payload) {
  const keys = Array.isArray(payload) ? payload : Array.isArray(payload?.ssh_signing_keys) ? payload.ssh_signing_keys : [];
  return {
    status: keys.length > 0 ? 'ready' : 'keys-missing',
    requiredScope: REQUIRED_SIGNING_SCOPE,
    scopeAvailable: true,
    listedKeyCount: keys.length
  };
}

function hasMissingScopeError(message, scope) {
  if (!message || !scope) {
    return false;
  }
  return message.includes(scope) || message.includes(`"${scope}"`);
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

function derivePublishedBundleObserverState(observerReport) {
  if (!observerReport) {
    return {
      status: 'unobserved',
      releaseTag: null,
      assetName: null,
      publishedAt: null,
      authoritativeConsumerPin: null
    };
  }

  return {
    status: asOptional(observerReport?.summary?.status) || 'unobserved',
    releaseTag: asOptional(observerReport?.summary?.releaseTag) || asOptional(observerReport?.selection?.releaseTag),
    assetName: asOptional(observerReport?.summary?.assetName) || asOptional(observerReport?.selection?.assetName),
    publishedAt: asOptional(observerReport?.summary?.publishedAt) || asOptional(observerReport?.selection?.publishedAt),
    authoritativeConsumerPin: asOptional(observerReport?.summary?.authoritativeConsumerPin)
  };
}

function derivePublicationControlState({
  workflowContract,
  secretInventory,
  releaseConductorApply,
  signingAuthority,
  publication,
  publishedBundleObserver,
  immutableRepairBlocker
}) {
  const observedReleaseTag =
    asOptional(publishedBundleObserver?.releaseTag) ||
    (publication?.tagPushed === true ? asOptional(publication?.targetTag) : null);
  const consumerPin = asOptional(publishedBundleObserver?.authoritativeConsumerPin);
  const consumerAligned =
    asOptional(publishedBundleObserver?.status) === 'producer-native-ready' &&
    observedReleaseTag != null &&
    consumerPin != null &&
    consumerPin === observedReleaseTag;
  const publishReady =
    workflowContract?.ready === true &&
    secretInventory?.status === 'configured' &&
    releaseConductorApply?.status === 'enabled' &&
    signingAuthority?.status === 'ready' &&
    immutableRepairBlocker == null;

  if (consumerAligned) {
    return 'published-consumer-aligned';
  }
  if (observedReleaseTag) {
    return 'published-observed';
  }
  if (publication?.tagCreated === true && publication?.tagPushed !== true) {
    return 'tag-created-not-pushed';
  }
  if (publishReady) {
    return 'ready-to-publish';
  }
  return publication?.status ?? 'unobserved';
}

function createPublishedBundleBlocker(publishedBundleObserver) {
  switch (publishedBundleObserver.status) {
    case 'release-unobserved':
      return {
        code: 'published-bundle-release-unobserved',
        message: 'No published CompareVI.Tools release could be observed yet for the producer-native vi-history distributor contract.'
      };
    case 'release-not-found':
      return {
        code: 'published-bundle-release-not-found',
        message: 'The requested CompareVI.Tools release tag was not found on GitHub, so producer-native vi-history publication is still unavailable.'
      };
    case 'asset-missing':
      return {
        code: 'published-bundle-asset-missing',
        message: 'The observed CompareVI.Tools release does not publish a CompareVI.Tools zip asset yet.'
      };
    case 'download-failed':
      return {
        code: 'published-bundle-download-failed',
        message: 'The published CompareVI.Tools asset could not be downloaded for producer-native vi-history verification.'
      };
    case 'extract-failed':
      return {
        code: 'published-bundle-extract-failed',
        message: 'The published CompareVI.Tools asset could not be extracted for producer-native vi-history verification.'
      };
    case 'metadata-missing':
      return {
        code: 'published-bundle-metadata-missing',
        message: 'The published CompareVI.Tools asset is missing comparevi-tools-release.json, so the producer-native vi-history contract is not published yet.'
      };
    case 'producer-native-incomplete':
      return {
        code: 'published-bundle-producer-native-incomplete',
        message: 'The published CompareVI.Tools asset exists, but it is still missing the producer-native vi-history consumer contract.'
      };
    default:
      return null;
  }
}

function createImmutableRepairBlocker(conductorReport) {
  const blockerCodes = new Set(
    (Array.isArray(conductorReport?.decision?.blockers) ? conductorReport.decision.blockers : [])
      .map((entry) => String(entry?.code ?? '').trim())
      .filter(Boolean)
  );
  const immutableBlocked =
    conductorReport?.release?.immutableRelease?.repairBlocked === true ||
    blockerCodes.has('repair-target-release-immutable') ||
    blockerCodes.has('existing-tag-repair-blocked-by-immutable-release');
  if (!immutableBlocked) {
    return null;
  }

  const targetTag = asOptional(conductorReport?.release?.targetTag) ?? 'the current release tag';
  return {
    code: 'release-repair-immutable-blocked',
    message: `Release conductor observed ${targetTag} as an immutable published GitHub Release, so in-place repair_existing_tag replay is blocked until a protected-tag authority path or new authoritative tag is used.`
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
  const publishedBundleObserverPath = path.resolve(
    repoRoot,
    options.releasePublishedBundleObserverPath ?? DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH
  );
  const runGhJsonFn = deps.runGhJsonFn ?? runGhJson;
  const readOptionalJsonFn = deps.readOptionalJsonFn ?? readOptionalJson;
  const writeJsonFn = deps.writeJsonFn ?? writeJson;
  const now = deps.now ?? new Date();

  const workflowContract = hasSigningWorkflowContract(repoRoot);
  const [owner, repo] = repository.split('/');
  let secretInventory;
  try {
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

  let releaseConductorApply;
  try {
    const payload = runGhJsonFn(['api', `repos/${owner}/${repo}/actions/variables?per_page=100`], { cwd: repoRoot });
    releaseConductorApply = {
      ...normalizeVariableInventory(payload),
      source: 'github-actions-variables-api',
      error: null
    };
  } catch (error) {
    releaseConductorApply = {
      status: 'unverifiable',
      variablePresent: null,
      enabled: null,
      configuredValue: null,
      listedVariableCount: null,
      listedVariableNames: [],
      source: 'github-actions-variables-api',
      error: error?.message ?? String(error)
    };
  }

  let signingAuthority;
  try {
    const payload = runGhJsonFn(['api', 'user/ssh_signing_keys?per_page=100'], { cwd: repoRoot });
    signingAuthority = {
      ...normalizeSigningAuthority(payload),
      source: 'github-user-ssh-signing-keys-api',
      error: null
    };
  } catch (error) {
    const message = error?.message ?? String(error);
    const scopeMissing = hasMissingScopeError(message, REQUIRED_SIGNING_SCOPE);
    signingAuthority = {
      status: scopeMissing ? 'scope-missing' : 'unverifiable',
      requiredScope: REQUIRED_SIGNING_SCOPE,
      scopeAvailable: scopeMissing ? false : null,
      listedKeyCount: null,
      source: 'github-user-ssh-signing-keys-api',
      error: message
    };
  }

  const conductorReport = readOptionalJsonFn(conductorReportPath);
  const publishedBundleObserverReport = readOptionalJsonFn(publishedBundleObserverPath);
  if (
    publishedBundleObserverReport &&
    publishedBundleObserverReport.schema !== 'priority/release-published-bundle-observer-report@v1'
  ) {
    throw new Error(
      `Expected priority/release-published-bundle-observer-report@v1 at ${publishedBundleObserverPath}.`
    );
  }
  const publication = derivePublicationState(conductorReport);
  const publishedBundleObserver = derivePublishedBundleObserverState(publishedBundleObserverReport);
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
  if (releaseConductorApply.status === 'disabled') {
    blockers.push({
      code: 'release-conductor-apply-disabled',
      message: `${RELEASE_CONDUCTOR_ENABLE_VARIABLE} is not set to 1 for the repository Actions variable surface.`
    });
  } else if (releaseConductorApply.status === 'unverifiable') {
    blockers.push({
      code: 'release-conductor-apply-unverifiable',
      message: 'Unable to verify release conductor apply gating from the current automation identity.'
    });
  }
  if (signingAuthority.status === 'keys-missing') {
    blockers.push({
      code: 'workflow-signing-key-missing',
      message: 'Authenticated identity can inspect SSH signing keys, but no SSH signing key is currently registered.'
    });
  } else if (signingAuthority.status === 'scope-missing') {
    blockers.push({
      code: 'workflow-signing-admin-scope-missing',
      message: `${REQUIRED_SIGNING_SCOPE} is not available to the current automation identity, so SSH signing-key authority cannot be verified or managed.`
    });
  } else if (signingAuthority.status === 'unverifiable') {
    blockers.push({
      code: 'workflow-signing-authority-unverifiable',
      message: 'Unable to verify SSH signing-key authority for the current automation identity.'
    });
  }

  const publishedBundleBlocker = createPublishedBundleBlocker(publishedBundleObserver);
  if (publishedBundleBlocker) {
    blockers.push(publishedBundleBlocker);
  }
  const immutableRepairBlocker = createImmutableRepairBlocker(conductorReport);
  if (immutableRepairBlocker) {
    blockers.push(immutableRepairBlocker);
  }
  const publicationControlState = derivePublicationControlState({
    workflowContract,
    secretInventory,
    releaseConductorApply,
    signingAuthority,
    publication,
    publishedBundleObserver,
    immutableRepairBlocker
  });

  const externalBlockerPriority = [
    'workflow-signing-secret-missing',
    'workflow-signing-secret-unverifiable',
    'workflow-signing-admin-scope-missing',
    'workflow-signing-key-missing',
    'workflow-signing-authority-unverifiable',
    'release-conductor-apply-disabled',
    'release-conductor-apply-unverifiable',
    'release-repair-immutable-blocked'
  ];

  const summary = {
    status: blockers.length === 0 ? 'pass' : 'warn',
    codePathState: workflowContract.ready ? 'ready' : 'missing-contract',
    signingCapabilityState:
      secretInventory.status === 'configured'
        ? 'configured'
        : secretInventory.status === 'missing'
          ? 'missing'
          : 'unverifiable',
    signingAuthorityState: signingAuthority.status,
    releaseConductorApplyState: releaseConductorApply.status,
    publicationState: publicationControlState,
    publishedBundleState: publishedBundleObserver.status,
    publishedBundleReleaseTag: publishedBundleObserver.releaseTag,
    publishedBundleAuthoritativeConsumerPin: publishedBundleObserver.authoritativeConsumerPin,
    externalBlocker: externalBlockerPriority.find((code) => blockers.some((entry) => entry.code === code)) ?? null,
    blockerCount: blockers.length
  };

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      releaseConductorReportPath: path.relative(repoRoot, conductorReportPath).replace(/\\/g, '/'),
      releasePublishedBundleObserverPath: path.relative(repoRoot, publishedBundleObserverPath).replace(/\\/g, '/')
    },
    workflowContract: {
      ready: workflowContract.ready,
      workflowPath: path.relative(repoRoot, workflowContract.workflowPath).replace(/\\/g, '/'),
      reasons: workflowContract.reasons
    },
    secretInventory,
    releaseConductorApply,
    signingAuthority,
    publication,
    publishedBundleObserver,
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
