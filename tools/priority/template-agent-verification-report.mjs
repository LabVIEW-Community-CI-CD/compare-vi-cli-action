#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/template-agent-verification-report@v1';
export const DEFAULT_POLICY_PATH = path.join('tools', 'priority', 'delivery-agent.policy.json');
export const DEFAULT_TEMPLATE_POLICY_PATH = path.join('tools', 'policy', 'template-dependency.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-report.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/template-agent-verification-report.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log(`  --policy <path>                 Policy path (default: ${DEFAULT_POLICY_PATH}).`);
  console.log(`  --template-policy <path>        Template dependency policy path (default: ${DEFAULT_TEMPLATE_POLICY_PATH}).`);
  console.log(`  --output <path>                 Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --repo <owner/repo>             Repository slug override.');
  console.log('  --iteration-label <value>       Human-readable iteration label (required).');
  console.log('  --iteration-ref <value>         Branch/PR/ref identifier.');
  console.log('  --iteration-head-sha <sha>      Iteration head commit SHA (required).');
  console.log('  --verification-status <status>  Verification status: pass|fail|blocked|pending (required).');
  console.log('  --duration-seconds <number>     Hosted verification duration in seconds.');
  console.log('  --provider <id>                 Verification provider id (default: hosted-github-workflow).');
  console.log('  --run-url <url>                 Hosted workflow or run URL.');
  console.log('  --template-repo <owner/repo>    Override target template repository.');
  console.log('  --template-version <value>      Template release/version provenance.');
  console.log('  --template-ref <value>          Template release/tag/ref provenance.');
  console.log('  --cookiecutter-version <value>  Cookiecutter runtime provenance.');
  console.log('  --execution-plane <value>       Execution plane provenance.');
  console.log('  --container-image <value>       Container image provenance.');
  console.log('  --generated-consumer-workspace-root <path>');
  console.log('                                  Generated consumer workspace root provenance.');
  console.log('  --lane-id <value>               Logical lane id provenance.');
  console.log('  --agent-id <value>              Agent id provenance.');
  console.log('  --funding-window-id <value>     Funding window provenance.');
  console.log('  --fail-on-blockers              Exit non-zero when blockers exist (default true).');
  console.log('  --no-fail-on-blockers           Emit report without failing process exit.');
  console.log('  -h, --help                      Show this message and exit.');
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function asOptional(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const httpsMatch = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, repo] = repoPath.split('/');
  if (!owner || !repo) return null;
  return `${owner}/${repo.replace(/\.git$/i, '')}`;
}

function resolveRepoSlug(explicitRepo) {
  if (normalizeText(explicitRepo).includes('/')) return normalizeText(explicitRepo);
  if (normalizeText(process.env.GITHUB_REPOSITORY).includes('/')) return normalizeText(process.env.GITHUB_REPOSITORY);
  for (const remote of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remote}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString('utf8')
        .trim();
      const slug = parseRemoteUrl(raw);
      if (slug) return slug;
    } catch {
      // ignore
    }
  }
  return null;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function toNonNegativeInteger(value) {
  if (value == null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function createBlocker(code, message) {
  return { code, message };
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    templatePolicyPath: DEFAULT_TEMPLATE_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    iterationLabel: null,
    iterationRef: null,
    iterationHeadSha: null,
    verificationStatus: null,
    durationSeconds: null,
    provider: 'hosted-github-workflow',
    runUrl: null,
    templateRepo: null,
    templateVersion: null,
    templateRef: null,
    cookiecutterVersion: null,
    executionPlane: null,
    containerImage: null,
    generatedConsumerWorkspaceRoot: null,
    laneId: null,
    agentId: null,
    fundingWindowId: null,
    failOnBlockers: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--fail-on-blockers') {
      options.failOnBlockers = true;
      continue;
    }
    if (token === '--no-fail-on-blockers') {
      options.failOnBlockers = false;
      continue;
    }
    if (
      [
        '--policy',
        '--template-policy',
        '--output',
        '--repo',
        '--iteration-label',
        '--iteration-ref',
        '--iteration-head-sha',
        '--verification-status',
        '--duration-seconds',
        '--provider',
        '--run-url',
        '--template-repo',
        '--template-version',
        '--template-ref',
        '--cookiecutter-version',
        '--execution-plane',
        '--container-image',
        '--generated-consumer-workspace-root',
        '--lane-id',
        '--agent-id',
        '--funding-window-id'
      ].includes(token)
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--policy') options.policyPath = next;
      if (token === '--template-policy') options.templatePolicyPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      if (token === '--iteration-label') options.iterationLabel = next;
      if (token === '--iteration-ref') options.iterationRef = next;
      if (token === '--iteration-head-sha') options.iterationHeadSha = next;
      if (token === '--verification-status') options.verificationStatus = next;
      if (token === '--duration-seconds') options.durationSeconds = next;
      if (token === '--provider') options.provider = next;
      if (token === '--run-url') options.runUrl = next;
      if (token === '--template-repo') options.templateRepo = next;
      if (token === '--template-version') options.templateVersion = next;
      if (token === '--template-ref') options.templateRef = next;
      if (token === '--cookiecutter-version') options.cookiecutterVersion = next;
      if (token === '--execution-plane') options.executionPlane = next;
      if (token === '--container-image') options.containerImage = next;
      if (token === '--generated-consumer-workspace-root') options.generatedConsumerWorkspaceRoot = next;
      if (token === '--lane-id') options.laneId = next;
      if (token === '--agent-id') options.agentId = next;
      if (token === '--funding-window-id') options.fundingWindowId = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !asOptional(options.iterationLabel)) {
    throw new Error('Missing required option: --iteration-label <value>.');
  }
  if (!options.help && !asOptional(options.iterationHeadSha)) {
    throw new Error('Missing required option: --iteration-head-sha <sha>.');
  }
  if (!options.help && !['pass', 'fail', 'blocked', 'pending'].includes(normalizeText(options.verificationStatus))) {
    throw new Error('Missing required option: --verification-status <pass|fail|blocked|pending>.');
  }

  const durationSeconds = toNonNegativeInteger(options.durationSeconds);
  if (options.durationSeconds != null && durationSeconds == null) {
    throw new Error('Duration must be a non-negative integer.');
  }
  options.durationSeconds = durationSeconds;
  return options;
}

export function evaluateTemplateAgentVerificationReport({
  policy,
  repo,
  iterationLabel,
  iterationRef,
  iterationHeadSha,
  verificationStatus,
  durationSeconds,
  provider,
  runUrl,
  templateRepo,
  templateVersion,
  templateRef,
  cookiecutterVersion,
  executionPlane,
  containerImage,
  generatedConsumerWorkspaceRoot,
  laneId,
  agentId,
  fundingWindowId
}) {
  const blockers = [];
  if (policy?.schema !== 'priority/delivery-agent-policy@v1') {
    blockers.push(createBlocker('policy-schema-mismatch', 'Delivery-agent policy schema mismatch.'));
  }

  const lane = policy?.templateAgentVerificationLane ?? {};
  const workerPool = policy?.workerPool ?? {};
  const targetSlotCount = toNonNegativeInteger(workerPool.targetSlotCount) ?? 0;
  const reservedSlotCount = toNonNegativeInteger(lane.reservedSlotCount) ?? 0;
  const minimumImplementationSlots = toNonNegativeInteger(lane.minimumImplementationSlots) ?? 0;
  const implementationSlotsRemaining = Math.max(targetSlotCount - reservedSlotCount, 0);
  const targetRepository = asOptional(templateRepo) ?? asOptional(lane.targetRepository);
  const durationGoalMinutes = toNonNegativeInteger(lane?.metrics?.maxHostedDurationMinutes);
  const durationGoalSeconds = durationGoalMinutes == null ? null : durationGoalMinutes * 60;
  const durationWithinGoal = durationGoalSeconds == null || durationSeconds == null ? null : durationSeconds <= durationGoalSeconds;
  const landedIterationHeadSha = asOptional(iterationHeadSha);

  if (lane.enabled !== true) {
    blockers.push(createBlocker('lane-disabled', 'Template-agent verification lane must remain enabled.'));
  }
  if (reservedSlotCount < 1) {
    blockers.push(createBlocker('lane-not-reserved', 'Template-agent verification lane must reserve at least one worker slot.'));
  }
  if (implementationSlotsRemaining < minimumImplementationSlots) {
    blockers.push(
      createBlocker(
        'implementation-capacity-too-low',
        `Reserved lane leaves ${implementationSlotsRemaining} implementation slots; policy requires at least ${minimumImplementationSlots}.`
      )
    );
  }
  if (!targetRepository) {
    blockers.push(createBlocker('target-repository-missing', 'Template-agent verification target repository is missing.'));
  }
  if (!landedIterationHeadSha) {
    blockers.push(createBlocker('iteration-head-sha-missing', 'Template-agent verification report requires the landed iteration head SHA.'));
  }
  if (verificationStatus === 'fail') {
    blockers.push(createBlocker('verification-failed', 'Template-agent verification reported a failure.'));
  }
  if (verificationStatus === 'blocked') {
    blockers.push(createBlocker('verification-blocked', 'Template-agent verification is blocked and needs follow-up.'));
  }
  if (durationWithinGoal === false && durationGoalMinutes != null) {
    blockers.push(
      createBlocker(
        'duration-goal-breached',
        `Hosted verification took ${durationSeconds} seconds; goal is <= ${durationGoalSeconds} seconds.`
      )
    );
  }

  const status = blockers.length > 0 ? 'blocked' : verificationStatus === 'pending' ? 'pending' : 'pass';
  const recommendation =
    blockers.length > 0
      ? 'investigate-template-agent-lane'
      : verificationStatus === 'pending'
        ? 'wait-for-template-verification'
        : 'continue-template-agent-loop';

  return {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repo,
    summary: {
      status,
      blockerCount: blockers.length,
      recommendation
    },
    iteration: {
      label: iterationLabel,
      ref: asOptional(iterationRef),
      headSha: landedIterationHeadSha
    },
    lane: {
      enabled: lane.enabled === true,
      reservedSlotCount,
      minimumImplementationSlots,
      implementationSlotsRemaining,
      executionMode: asOptional(lane.executionMode),
      targetRepository,
      consumerRailBranch: asOptional(lane.consumerRailBranch)
    },
    verification: {
      provider: asOptional(provider) ?? 'hosted-github-workflow',
      status: verificationStatus,
      durationSeconds,
      runUrl: asOptional(runUrl)
    },
    provenance: {
      templateDependency: {
        repository: asOptional(templateRepo) ?? asOptional(lane.targetRepository),
        version: asOptional(templateVersion),
        ref: asOptional(templateRef),
        cookiecutterVersion: asOptional(cookiecutterVersion)
      },
      execution: {
        executionPlane: asOptional(executionPlane),
        containerImage: asOptional(containerImage),
        generatedConsumerWorkspaceRoot: asOptional(generatedConsumerWorkspaceRoot),
        laneId: asOptional(laneId),
        agentId: asOptional(agentId),
        fundingWindowId: asOptional(fundingWindowId)
      }
    },
    goals: {
      maxVerificationLagIterations: toNonNegativeInteger(lane?.metrics?.maxVerificationLagIterations),
      maxHostedDurationMinutes: durationGoalMinutes,
      requireMachineReadableRecommendation: lane?.metrics?.requireMachineReadableRecommendation === true
    },
    metrics: {
      targetSlotCount,
      reservedSlotCount,
      implementationSlotsRemaining,
      durationWithinGoal,
      recommendationPresent: recommendation.length > 0
    },
    blockers
  };
}

export function runTemplateAgentVerificationReport(
  options,
  { resolveRepoSlugFn = resolveRepoSlug, readJsonFn = readJson, writeJsonFn = writeJson } = {}
) {
  const repo = asOptional(resolveRepoSlugFn(options.repo));
  if (!repo) {
    throw new Error('Unable to determine repository slug.');
  }

  const templatePolicy = readJsonFn(options.templatePolicyPath || DEFAULT_TEMPLATE_POLICY_PATH);
  const templateRepository = asOptional(options.templateRepo) ?? asOptional(templatePolicy?.templateRepositorySlug);
  const templateVersion = asOptional(options.templateVersion) ?? asOptional(templatePolicy?.templateReleaseRef);
  const templateRef = asOptional(options.templateRef) ?? asOptional(templatePolicy?.rendering?.checkout);
  const cookiecutterVersion = asOptional(options.cookiecutterVersion) ?? asOptional(templatePolicy?.cookiecutterVersion);
  const executionPlane = asOptional(options.executionPlane) ?? asOptional(templatePolicy?.container?.executionPlane);
  const containerImage = asOptional(options.containerImage) ?? asOptional(templatePolicy?.container?.image);

  const report = evaluateTemplateAgentVerificationReport({
    policy: readJsonFn(options.policyPath || DEFAULT_POLICY_PATH),
    repo,
    iterationLabel: normalizeText(options.iterationLabel),
    iterationRef: options.iterationRef,
    iterationHeadSha: options.iterationHeadSha,
    verificationStatus: normalizeText(options.verificationStatus),
    durationSeconds: options.durationSeconds,
    provider: options.provider,
    runUrl: options.runUrl,
    templateRepo: templateRepository,
    templateVersion,
    templateRef,
    cookiecutterVersion,
    executionPlane,
    containerImage,
    generatedConsumerWorkspaceRoot: options.generatedConsumerWorkspaceRoot,
    laneId: options.laneId,
    agentId: options.agentId,
    fundingWindowId: options.fundingWindowId
  });

  const outputPath = writeJsonFn(options.outputPath || DEFAULT_OUTPUT_PATH, report);
  return { report, outputPath };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      printUsage();
      process.exit(0);
    }
    const { report, outputPath } = runTemplateAgentVerificationReport(options);
    console.log(
      `[template-agent-verification-report] wrote ${outputPath} (status=${report.summary.status}, blockers=${report.summary.blockerCount})`
    );
    if (options.failOnBlockers && report.summary.blockerCount > 0) {
      process.exit(1);
    }
  } catch (error) {
    console.error(`[template-agent-verification-report] ${error.message}`);
    process.exit(1);
  }
}
