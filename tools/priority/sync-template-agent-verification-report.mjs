#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolveArtifactDestinationRoot } from './lib/storage-root-policy.mjs';
import { runResolveDownstreamProvingArtifact } from './resolve-downstream-proving-artifact.mjs';
import {
  DEFAULT_TEMPLATE_POLICY_PATH,
  evaluateTemplateAgentVerificationReport
} from './template-agent-verification-report.mjs';

export const REPORT_SCHEMA = 'priority/template-agent-verification-sync-report@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DEFAULT_LOCAL_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-report.json'
);
export const DEFAULT_LOCAL_OVERLAY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-report.local.json'
);
export const DEFAULT_AUTHORITY_REPORT_PATH = path.join(
  'template-verification',
  'template-agent-verification-report.json'
);
export const DEFAULT_PROVING_SELECTION_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-downstream-proving-selection.json'
);
export const DEFAULT_PROVING_SELECTION_DESTINATION_ROOT = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-downstream-proving-artifacts'
);
export const DEFAULT_MONITORING_MODE_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'monitoring-mode.json'
);
export const DEFAULT_SUPPORTED_PROOF_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-report.supported.json'
);
export const DEFAULT_PROVING_BRANCH = 'develop';
export const DEFAULT_PROVING_WORKFLOW = 'downstream-promotion.yml';
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-sync.json'
);

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function asOptional(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) {
    return null;
  }
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo, execSyncFn = execSync) {
  if (asOptional(explicitRepo)?.includes('/')) {
    return asOptional(explicitRepo);
  }
  if (asOptional(process.env.GITHUB_REPOSITORY)?.includes('/')) {
    return asOptional(process.env.GITHUB_REPOSITORY);
  }
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSyncFn(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) {
        return slug;
      }
    } catch {
      // ignore missing remotes
    }
  }
  return null;
}

function resolveGitSha(revision, execSyncFn = execSync) {
  try {
    return asOptional(
      execSyncFn(`git rev-parse ${revision}`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim()
    );
  } catch {
    return null;
  }
}

function resolveExpectedSourceSha(explicitSourceSha, execSyncFn = execSync) {
  return (
    asOptional(explicitSourceSha) ||
    resolveGitSha('upstream/develop', execSyncFn) ||
    resolveGitSha('origin/develop', execSyncFn) ||
    resolveGitSha('HEAD', execSyncFn)
  );
}

async function defaultRunGhJson(args) {
  const result = spawnSync('gh', args, {
    encoding: 'utf8',
    maxBuffer: 50 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.error || result.status !== 0) {
    const message =
      asOptional(result.stderr) ||
      asOptional(result.stdout) ||
      result.error?.message ||
      `gh ${args.join(' ')} failed`;
    throw new Error(message);
  }
  return JSON.parse(result.stdout || 'null');
}

function parseDate(value) {
  const normalized = asOptional(value);
  if (!normalized) {
    return null;
  }
  const parsed = Date.parse(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function readOptionalJson(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return {
      path: resolvedPath,
      exists: false,
      payload: null,
      error: null
    };
  }
  try {
    return {
      path: resolvedPath,
      exists: true,
      payload: JSON.parse(fs.readFileSync(resolvedPath, 'utf8')),
      error: null
    };
  } catch (error) {
    return {
      path: resolvedPath,
      exists: true,
      payload: null,
      error: error?.message ?? String(error)
    };
  }
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

function removeFile(filePath) {
  const resolvedPath = path.resolve(filePath);
  fs.rmSync(resolvedPath, { force: true });
}

function copyFile(sourcePath, destinationPath) {
  const resolvedSourcePath = path.resolve(sourcePath);
  const resolvedDestinationPath = path.resolve(destinationPath);
  fs.mkdirSync(path.dirname(resolvedDestinationPath), { recursive: true });
  fs.copyFileSync(resolvedSourcePath, resolvedDestinationPath);
  return resolvedDestinationPath;
}

function describeReport(input) {
  const payload = input?.payload;
  return {
    path: input?.path ?? null,
    exists: input?.exists === true,
    parseError: asOptional(input?.error),
    schema: asOptional(payload?.schema),
    summaryStatus: asOptional(payload?.summary?.status),
    verificationStatus: asOptional(payload?.verification?.status),
    generatedAt: asOptional(payload?.generatedAt),
    generatedAtMs: parseDate(payload?.generatedAt),
    templateRepository: asOptional(payload?.provenance?.templateDependency?.repository),
    templateVersion: asOptional(payload?.provenance?.templateDependency?.version),
    templateRef: asOptional(payload?.provenance?.templateDependency?.ref),
    cookiecutterVersion: asOptional(payload?.provenance?.templateDependency?.cookiecutterVersion),
    runUrl: asOptional(payload?.verification?.runUrl),
    provider: asOptional(payload?.verification?.provider),
    valid:
      payload?.schema === 'priority/template-agent-verification-report@v1' &&
      typeof payload === 'object' &&
      payload != null
  };
}

export function resolveAuthorityReportPath(repoRoot, policy, env = process.env) {
  const authorityRelativePath =
    asOptional(policy?.templateAgentVerificationLane?.authoritativeReportPath) ?? DEFAULT_AUTHORITY_REPORT_PATH;
  const authorityRootSelection = resolveArtifactDestinationRoot({
    repoRoot,
    destinationRoot: path.dirname(authorityRelativePath),
    destinationRootExplicit: false,
    policy: policy?.storageRoots,
    env
  });

  return {
    authorityReportPath: path.join(
      authorityRootSelection.destinationRoot,
      path.basename(authorityRelativePath)
    ),
    authorityRootSelection
  };
}

async function resolveHostedAuthorityReport({
  repoRoot,
  repository,
  branch,
  workflow,
  expectedSourceSha,
  destinationRoot,
  outputPath,
  env,
  runGhJsonFn = defaultRunGhJson,
  runResolveDownstreamProvingArtifactFn = runResolveDownstreamProvingArtifact
}) {
  const selectionResult = await runResolveDownstreamProvingArtifactFn(
    {
      repo: repository,
      workflow,
      branch,
      expectedSourceSha,
      destinationRoot,
      destinationRootExplicit: true,
      outputPath
    },
    {
      env,
      runGhJsonFn
    }
  );
  const hostedAuthoritySourcePath =
    selectionResult?.selected?.templateAgentVerificationStatus === 'pass'
      ? selectionResult.selected.templateAgentVerificationReportPath
      : null;
  const hostedAuthorityReport = hostedAuthoritySourcePath
    ? describeReport(readOptionalJson(hostedAuthoritySourcePath))
    : describeReport(null);
  return {
    selectionResult,
    hostedAuthorityReport
  };
}

function deriveCanonicalTemplateHeadSha(repositories) {
  for (const entry of repositories) {
    const canonicalHeadSha = asOptional(entry?.branchAlignment?.canonicalHeadSha);
    if (canonicalHeadSha) {
      return canonicalHeadSha;
    }
  }
  for (const entry of repositories) {
    if (asOptional(entry?.role) === 'canonical-template') {
      const headSha = asOptional(entry?.branchAlignment?.headSha);
      if (headSha) {
        return headSha;
      }
    }
  }
  return null;
}

function resolveSupportedProofCandidate(monitoringModePayload, policy) {
  if (monitoringModePayload?.schema !== 'agent-handoff/monitoring-mode-v1') {
    return null;
  }
  if (asOptional(monitoringModePayload?.templateMonitoring?.status) !== 'pass') {
    return null;
  }

  const repositories = Array.isArray(monitoringModePayload?.templateMonitoring?.repositories)
    ? monitoringModePayload.templateMonitoring.repositories
    : [];
  const canonicalRepository =
    asOptional(repositories.find((entry) => asOptional(entry?.role) === 'canonical-template')?.repository) ??
    asOptional(policy?.templateAgentVerificationLane?.targetRepository);
  const canonicalHeadSha = deriveCanonicalTemplateHeadSha(repositories);
  const selectedMonitor =
    repositories.find((entry) => {
      if (asOptional(entry?.supportedProof?.status) !== 'pass') {
        return false;
      }
      if (!asOptional(entry?.supportedProof?.runUrl)) {
        return false;
      }
      const branchAlignmentStatus = asOptional(entry?.branchAlignment?.status);
      if (entry?.branchAlignment != null && branchAlignmentStatus !== 'pass') {
        return false;
      }
      const supportedHeadSha = asOptional(entry?.supportedProof?.headSha);
      if (canonicalHeadSha && supportedHeadSha && supportedHeadSha !== canonicalHeadSha) {
        return false;
      }
      return true;
    }) ?? null;

  if (!selectedMonitor || !canonicalRepository || !canonicalHeadSha) {
    return null;
  }

  return {
    canonicalRepository,
    canonicalHeadSha,
    selectedMonitor
  };
}

function synthesizeSupportedProofAuthorityReport({
  policy,
  templatePolicy,
  repository,
  branch,
  expectedSourceSha,
  monitoringModeInput,
  monitoringModePath,
  supportedProofReportPath,
  readOptionalJsonFn,
  writeJsonFn
}) {
  const supportedProofCandidate = resolveSupportedProofCandidate(monitoringModeInput?.payload, policy);
  if (!supportedProofCandidate || !repository || !expectedSourceSha) {
    removeFile(supportedProofReportPath);
    return describeReport(null);
  }

  const report = evaluateTemplateAgentVerificationReport({
    policy,
    repo: repository,
    iterationLabel: `supported template proof for compare ${expectedSourceSha.slice(0, 8)}`,
    iterationRef: `${branch}:${expectedSourceSha.slice(0, 8)}`,
    iterationHeadSha: expectedSourceSha,
    verificationStatus: 'pass',
    durationSeconds: null,
    provider: 'hosted-github-workflow',
    runUrl: supportedProofCandidate.selectedMonitor.supportedProof.runUrl,
    templateRepo: supportedProofCandidate.canonicalRepository,
    templateVersion: supportedProofCandidate.canonicalHeadSha,
    templateRef: supportedProofCandidate.canonicalHeadSha,
    cookiecutterVersion: asOptional(templatePolicy?.cookiecutterVersion),
    executionPlane: 'hosted-github-actions',
    containerImage: null,
    generatedConsumerWorkspaceRoot: null,
    laneId: 'supported-template-proof',
    agentId: 'compare-monitoring-mode',
    fundingWindowId: null
  });

  report.authorityProjection = {
    source: 'supported-template-proof',
    monitoringModePath: path.resolve(monitoringModePath),
    supportedRepository: supportedProofCandidate.selectedMonitor.repository,
    supportedRole: asOptional(supportedProofCandidate.selectedMonitor.role),
    canonicalRepository: supportedProofCandidate.canonicalRepository,
    canonicalHeadSha: supportedProofCandidate.canonicalHeadSha,
    supportedProofRunUrl: asOptional(supportedProofCandidate.selectedMonitor.supportedProof?.runUrl),
    supportedProofHeadSha: asOptional(supportedProofCandidate.selectedMonitor.supportedProof?.headSha)
  };

  writeJsonFn(supportedProofReportPath, report);
  return describeReport(readOptionalJsonFn(supportedProofReportPath));
}

function selectAuthoritySource(authorityReport, hostedAuthorityReport, supportedProofAuthorityReport) {
  if (!authorityReport.valid && !hostedAuthorityReport.valid && !supportedProofAuthorityReport.valid) {
    return {
      source: 'none',
      reason: 'no-valid-report',
      selectedPath: null
    };
  }

  if (hostedAuthorityReport.valid) {
    return {
      source: 'hosted-authority',
      reason: 'downstream-proving-artifact-current',
      selectedPath: hostedAuthorityReport.path
    };
  }

  if (
    supportedProofAuthorityReport.valid &&
    authorityReport.valid &&
    authorityReport.runUrl === supportedProofAuthorityReport.runUrl &&
    authorityReport.templateRef === supportedProofAuthorityReport.templateRef &&
    authorityReport.templateVersion === supportedProofAuthorityReport.templateVersion
  ) {
    return {
      source: 'authority',
      reason: 'shared-authority-matches-supported-proof',
      selectedPath: authorityReport.path
    };
  }

  if (supportedProofAuthorityReport.valid) {
    return {
      source: 'supported-proof-authority',
      reason: 'supported-template-proof-current',
      selectedPath: supportedProofAuthorityReport.path
    };
  }

  return {
    source: 'authority',
    reason: 'shared-authority-current',
    selectedPath: authorityReport.path
  };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    localReportPath: DEFAULT_LOCAL_REPORT_PATH,
    localOverlayReportPath: DEFAULT_LOCAL_OVERLAY_REPORT_PATH,
    authorityReportPath: null,
    templatePolicyPath: DEFAULT_TEMPLATE_POLICY_PATH,
    monitoringModePath: DEFAULT_MONITORING_MODE_PATH,
    supportedProofReportPath: DEFAULT_SUPPORTED_PROOF_REPORT_PATH,
    repo: null,
    branch: DEFAULT_PROVING_BRANCH,
    workflow: DEFAULT_PROVING_WORKFLOW,
    expectedSourceSha: null,
    provingSelectionOutputPath: DEFAULT_PROVING_SELECTION_OUTPUT_PATH,
    provingSelectionDestinationRoot: DEFAULT_PROVING_SELECTION_DESTINATION_ROOT,
    outputPath: DEFAULT_OUTPUT_PATH,
    repoRoot: process.cwd(),
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (
      token === '--policy' ||
      token === '--local-report' ||
      token === '--local-overlay-report' ||
      token === '--authority-report' ||
      token === '--template-policy' ||
      token === '--monitoring-mode' ||
      token === '--supported-proof-report' ||
      token === '--repo' ||
      token === '--branch' ||
      token === '--workflow' ||
      token === '--expected-source-sha' ||
      token === '--proving-selection-output' ||
      token === '--proving-selection-destination-root' ||
      token === '--output' ||
      token === '--repo-root'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--policy') options.policyPath = next;
      if (token === '--local-report') options.localReportPath = next;
      if (token === '--local-overlay-report') options.localOverlayReportPath = next;
      if (token === '--authority-report') options.authorityReportPath = next;
      if (token === '--template-policy') options.templatePolicyPath = next;
      if (token === '--monitoring-mode') options.monitoringModePath = next;
      if (token === '--supported-proof-report') options.supportedProofReportPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--branch') options.branch = next;
      if (token === '--workflow') options.workflow = next;
      if (token === '--expected-source-sha') options.expectedSourceSha = next;
      if (token === '--proving-selection-output') options.provingSelectionOutputPath = next;
      if (token === '--proving-selection-destination-root') options.provingSelectionDestinationRoot = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo-root') options.repoRoot = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export async function syncTemplateAgentVerificationReport(
  options,
  {
    env = process.env,
    execSyncFn = execSync,
    resolveRepoSlugFn = resolveRepoSlug,
    readOptionalJsonFn = readOptionalJson,
    writeJsonFn = writeJson,
    copyFileFn = copyFile,
    runResolveDownstreamProvingArtifactFn = runResolveDownstreamProvingArtifact,
    runGhJsonFn = defaultRunGhJson
  } = {}
) {
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const policyPath = path.resolve(repoRoot, options.policyPath || DEFAULT_POLICY_PATH);
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const templatePolicyPath = path.resolve(repoRoot, options.templatePolicyPath || DEFAULT_TEMPLATE_POLICY_PATH);
  const templatePolicy = readOptionalJsonFn(templatePolicyPath)?.payload ?? {};
  const monitoringModePath = path.resolve(repoRoot, options.monitoringModePath || DEFAULT_MONITORING_MODE_PATH);
  const supportedProofReportPath = path.resolve(
    repoRoot,
    options.supportedProofReportPath || DEFAULT_SUPPORTED_PROOF_REPORT_PATH
  );
  const repository = resolveRepoSlugFn(options.repo, execSyncFn);
  const branch = asOptional(options.branch) || DEFAULT_PROVING_BRANCH;
  const workflow = asOptional(options.workflow) || DEFAULT_PROVING_WORKFLOW;
  const expectedSourceSha = resolveExpectedSourceSha(options.expectedSourceSha, execSyncFn);
  const localReportPath = path.resolve(
    repoRoot,
    options.localReportPath ||
      asOptional(policy?.templateAgentVerificationLane?.reportPath) ||
      DEFAULT_LOCAL_REPORT_PATH
  );
  const localOverlayReportPath = path.resolve(
    repoRoot,
    options.localOverlayReportPath || DEFAULT_LOCAL_OVERLAY_REPORT_PATH
  );
  const { authorityReportPath, authorityRootSelection } = options.authorityReportPath
    ? {
        authorityReportPath: path.resolve(options.authorityReportPath),
        authorityRootSelection: null
      }
    : resolveAuthorityReportPath(repoRoot, policy, env);
  const provingSelectionOutputPath = path.resolve(
    repoRoot,
    options.provingSelectionOutputPath || DEFAULT_PROVING_SELECTION_OUTPUT_PATH
  );
  const provingSelectionDestinationRoot = path.resolve(
    repoRoot,
    options.provingSelectionDestinationRoot || DEFAULT_PROVING_SELECTION_DESTINATION_ROOT
  );

  const localReport = describeReport(readOptionalJsonFn(localReportPath));
  let authorityReport = describeReport(readOptionalJsonFn(authorityReportPath));
  let hostedAuthorityReport = describeReport(null);
  const monitoringMode = readOptionalJsonFn(monitoringModePath);
  const supportedProofAuthorityReport = synthesizeSupportedProofAuthorityReport({
    policy,
    templatePolicy,
    repository,
    branch,
    expectedSourceSha,
    monitoringModeInput: monitoringMode,
    monitoringModePath,
    supportedProofReportPath,
    readOptionalJsonFn,
    writeJsonFn
  });
  let provingSelection = null;
  let provingSelectionStatus = 'missing';
  let provingSelectionError = null;

  if (repository && expectedSourceSha) {
    try {
      const hostedAuthority = await resolveHostedAuthorityReport({
        repoRoot,
        repository,
        branch,
        workflow,
        expectedSourceSha,
        destinationRoot: provingSelectionDestinationRoot,
        outputPath: provingSelectionOutputPath,
        env,
        runGhJsonFn,
        runResolveDownstreamProvingArtifactFn
      });
      provingSelection = hostedAuthority.selectionResult;
      provingSelectionStatus = hostedAuthority.selectionResult?.status ?? 'fail';
      hostedAuthorityReport = hostedAuthority.hostedAuthorityReport;
    } catch (error) {
      provingSelectionStatus = 'error';
      provingSelectionError = error?.message ?? String(error);
    }
  }

  const selection = selectAuthoritySource(authorityReport, hostedAuthorityReport, supportedProofAuthorityReport);
  let synchronizedAuthorityCache = false;
  if (selection.source === 'hosted-authority' && hostedAuthorityReport.valid) {
    copyFileFn(hostedAuthorityReport.path, authorityReportPath);
    authorityReport = describeReport(readOptionalJsonFn(authorityReportPath));
    synchronizedAuthorityCache = true;
  } else if (selection.source === 'supported-proof-authority' && supportedProofAuthorityReport.valid) {
    copyFileFn(supportedProofAuthorityReport.path, authorityReportPath);
    authorityReport = describeReport(readOptionalJsonFn(authorityReportPath));
    synchronizedAuthorityCache = true;
  }

  const effectiveAuthoritativeReport =
    selection.source === 'hosted-authority'
      ? hostedAuthorityReport
      : selection.source === 'supported-proof-authority'
        ? supportedProofAuthorityReport
        : authorityReport;
  let synchronizedLocalOverlay = false;
  if (effectiveAuthoritativeReport.valid && effectiveAuthoritativeReport.path) {
    copyFileFn(effectiveAuthoritativeReport.path, localOverlayReportPath);
    synchronizedLocalOverlay = true;
  } else {
    fs.rmSync(localOverlayReportPath, { force: true });
  }
  const localOverlayReport = describeReport(readOptionalJsonFn(localOverlayReportPath));

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repoRoot,
    repository,
    branch,
    workflow,
    expectedSourceSha,
    policyPath,
    localCanonicalReportPath: localReportPath,
    localOverlayReportPath,
    authoritativeReportPath: authorityReportPath,
    provingSelectionReportPath: provingSelectionOutputPath,
    authorityRootSelection,
    localReport,
    localOverlayReport,
    authorityReport,
    hostedAuthorityReport,
    supportedProofAuthorityReport,
    provingSelectionStatus,
    provingSelectionError,
    selection: {
      ...selection,
      synchronizedLocalOverlay,
      synchronizedAuthorityCache
    }
  };

  const outputPath = writeJsonFn(options.outputPath || DEFAULT_OUTPUT_PATH, report);
  return {
    report,
    outputPath,
    localReportPath,
    localOverlayReportPath,
    authorityReportPath
  };
}

function printHelp() {
  [
    'Usage: node tools/priority/sync-template-agent-verification-report.mjs [options]',
    '',
    'Options:',
    `  --policy <path>            Delivery policy path (default: ${DEFAULT_POLICY_PATH}).`,
    `  --local-report <path>      Checked-in local seed report path (default: ${DEFAULT_LOCAL_REPORT_PATH}).`,
    `  --local-overlay-report <path> Local authoritative overlay path (default: ${DEFAULT_LOCAL_OVERLAY_REPORT_PATH}).`,
    '  --authority-report <path>  Explicit shared authoritative report path override.',
    `  --template-policy <path>   Template dependency policy path (default: ${DEFAULT_TEMPLATE_POLICY_PATH}).`,
    `  --monitoring-mode <path>   Monitoring-mode handoff path (default: ${DEFAULT_MONITORING_MODE_PATH}).`,
    `  --supported-proof-report <path> Supported-proof authority report path (default: ${DEFAULT_SUPPORTED_PROOF_REPORT_PATH}).`,
    '  --repo <owner/repo>        Repository slug for downstream proving selection.',
    `  --branch <name>            Downstream proving workflow branch (default: ${DEFAULT_PROVING_BRANCH}).`,
    `  --workflow <file>          Downstream proving workflow file (default: ${DEFAULT_PROVING_WORKFLOW}).`,
    '  --expected-source-sha <sha> Exact develop source sha to prove.',
    `  --proving-selection-output <path> Selection report path (default: ${DEFAULT_PROVING_SELECTION_OUTPUT_PATH}).`,
    `  --proving-selection-destination-root <path> Artifact download root (default: ${DEFAULT_PROVING_SELECTION_DESTINATION_ROOT}).`,
    `  --output <path>            Sync report output path (default: ${DEFAULT_OUTPUT_PATH}).`,
    '  --repo-root <path>         Repository root override (default: cwd).',
    '  -h, --help                 Show help.'
  ].forEach((line) => console.log(line));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printHelp();
      process.exit(0);
    }
    const { report, outputPath } = await syncTemplateAgentVerificationReport(options);
    console.log(
      `[template-agent-verification-sync] wrote ${outputPath} (source=${report.selection.source}, overlay=${report.selection.synchronizedLocalOverlay}, authority=${report.selection.synchronizedAuthorityCache})`
    );
  } catch (error) {
    console.error(`[template-agent-verification-sync] ${error.message}`);
    process.exit(1);
  }
}
