#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_POLICY_PATH = path.join('tools', 'policy', 'template-pivot-gate.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-pivot-gate-report.json'
);
export const DEFAULT_QUEUE_EMPTY_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'issue',
  'no-standing-priority.json'
);
export const DEFAULT_RELEASE_SUMMARY_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'release-summary.json'
);
export const DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'handoff',
  'entrypoint-status.json'
);
export const DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'template-agent-verification-report.json'
);

const HELP = [
  'Usage: node tools/priority/template-pivot-gate.mjs [options]',
  '',
  'Options:',
  `  --policy <path>                  Policy path (default: ${DEFAULT_POLICY_PATH}).`,
  `  --queue-empty-report <path>      Queue-empty issue report (default: ${DEFAULT_QUEUE_EMPTY_REPORT_PATH}).`,
  `  --release-summary <path>         Release summary artifact (default: ${DEFAULT_RELEASE_SUMMARY_PATH}).`,
  `  --handoff-entrypoint <path>      Handoff entrypoint status (default: ${DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH}).`,
  `  --template-agent-verification-report <path>  Template-agent verification report (default: ${DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH}).`,
  `  --output <path>                  Report output path (default: ${DEFAULT_OUTPUT_PATH}).`,
  '  --repo <owner/repo>              Repository slug (default: env/remotes).',
  '  -h, --help                       Show help.'
];

function printHelp(log = console.log) {
  for (const line of HELP) {
    log(line);
  }
}

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
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

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
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

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function toRelative(targetPath) {
  return path.relative(process.cwd(), path.resolve(targetPath)).replace(/\\/g, '/');
}

function createBlocker(code, message) {
  return { code, message };
}

function normalizeTemplateDependency(value) {
  return {
    repository: asOptional(value?.repository),
    version: asOptional(value?.version),
    ref: asOptional(value?.ref),
    cookiecutterVersion: asOptional(value?.cookiecutterVersion)
  };
}

function allFieldsPresent(object, fields) {
  return fields.every((field) => asOptional(object?.[field]) != null);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    queueEmptyReportPath: DEFAULT_QUEUE_EMPTY_REPORT_PATH,
    releaseSummaryPath: DEFAULT_RELEASE_SUMMARY_PATH,
    handoffEntrypointStatusPath: DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH,
    templateAgentVerificationReportPath: DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
    help: false
  };

  const stringFlags = new Map([
    ['--policy', 'policyPath'],
    ['--queue-empty-report', 'queueEmptyReportPath'],
    ['--release-summary', 'releaseSummaryPath'],
    ['--handoff-entrypoint', 'handoffEntrypointStatusPath'],
    ['--template-agent-verification-report', 'templateAgentVerificationReportPath'],
    ['--output', 'outputPath'],
    ['--repo', 'repo']
  ]);

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (stringFlags.has(token)) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      options[stringFlags.get(token)] = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export async function runTemplatePivotGate(
  options,
  {
    now = new Date(),
    resolveRepoSlugFn = resolveRepoSlug,
    readJsonFn = readJson,
    readOptionalJsonFn = readOptionalJson,
    writeJsonFn = writeJson,
    sha256FileFn = sha256File
  } = {}
) {
  const repo = asOptional(resolveRepoSlugFn(options.repo));
  if (!repo) {
    throw new Error('Unable to determine repository slug.');
  }

  const policyPath = path.resolve(options.policyPath || DEFAULT_POLICY_PATH);
  const policy = readJsonFn(policyPath);
  if (policy?.schema !== 'priority/template-pivot-gate-policy@v1') {
    throw new Error('Template pivot gate policy schema mismatch.');
  }

  const queueEmptyReportPath = path.resolve(
    options.queueEmptyReportPath || policy.artifacts?.queueEmptyReportPath || DEFAULT_QUEUE_EMPTY_REPORT_PATH
  );
  const releaseSummaryPath = path.resolve(
    options.releaseSummaryPath || policy.artifacts?.releaseSummaryPath || DEFAULT_RELEASE_SUMMARY_PATH
  );
  const handoffEntrypointStatusPath = path.resolve(
    options.handoffEntrypointStatusPath ||
      policy.artifacts?.handoffEntrypointStatusPath ||
      DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH
  );
  const templateAgentVerificationReportPath = path.resolve(
    options.templateAgentVerificationReportPath ||
      policy.artifacts?.templateAgentVerificationReportPath ||
      DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH
  );

  const queueEmpty = readOptionalJsonFn(queueEmptyReportPath);
  const releaseSummary = readOptionalJsonFn(releaseSummaryPath);
  const handoffEntrypoint = readOptionalJsonFn(handoffEntrypointStatusPath);
  const templateAgentVerification = readOptionalJsonFn(templateAgentVerificationReportPath);

  const blockers = [];
  const releaseCandidateRegex = new RegExp(policy.releaseCandidate.versionPattern);
  const policyTemplateDependency = normalizeTemplateDependency(policy.templateDependency);
  const templateDependencyFields = ['repository', 'version', 'ref', 'cookiecutterVersion'];
  const templateDependencyPolicyReady = allFieldsPresent(policyTemplateDependency, templateDependencyFields);
  const templateAgentVerificationTemplateDependency = normalizeTemplateDependency(
    templateAgentVerification?.provenance?.templateDependency
  );
  const templateAgentVerificationExecution = {
    executionPlane: asOptional(templateAgentVerification?.provenance?.execution?.executionPlane),
    containerImage: asOptional(templateAgentVerification?.provenance?.execution?.containerImage),
    generatedConsumerWorkspaceRoot: asOptional(
      templateAgentVerification?.provenance?.execution?.generatedConsumerWorkspaceRoot
    ),
    laneId: asOptional(templateAgentVerification?.provenance?.execution?.laneId),
    agentId: asOptional(templateAgentVerification?.provenance?.execution?.agentId),
    fundingWindowId: asOptional(templateAgentVerification?.provenance?.execution?.fundingWindowId)
  };
  const templateAgentVerificationExecutionReady = allFieldsPresent(templateAgentVerificationExecution, [
    'executionPlane',
    'containerImage',
    'generatedConsumerWorkspaceRoot',
    'laneId',
    'agentId',
    'fundingWindowId'
  ]);
  const templateAgentVerificationTemplateDependencyReady =
    templateDependencyPolicyReady &&
    templateDependencyFields.every(
      (field) => templateAgentVerificationTemplateDependency[field] === policyTemplateDependency[field]
    );

  const queueEmptyReady =
    queueEmpty?.schema === policy.queueEmpty.requiredSchema &&
    queueEmpty?.reason === policy.queueEmpty.requiredReason &&
    queueEmpty?.openIssueCount === policy.queueEmpty.requiredOpenIssueCount;
  if (!queueEmpty) {
    blockers.push(
      createBlocker(
        'queue-empty-report-missing',
        'Queue-empty report is missing; the compare-vi-cli-action issue queue is not yet proven empty.'
      )
    );
  } else if (queueEmpty.schema !== policy.queueEmpty.requiredSchema) {
    blockers.push(
      createBlocker(
        'queue-empty-schema-mismatch',
        `Queue-empty report schema must remain ${policy.queueEmpty.requiredSchema}.`
      )
    );
  } else if (queueEmpty.reason !== policy.queueEmpty.requiredReason) {
    blockers.push(
      createBlocker(
        'queue-not-empty',
        `Queue-empty report reason must be ${policy.queueEmpty.requiredReason}; received ${queueEmpty.reason}.`
      )
    );
  } else if (queueEmpty.openIssueCount !== policy.queueEmpty.requiredOpenIssueCount) {
    blockers.push(
      createBlocker(
        'open-issues-remaining',
        `Queue-empty report openIssueCount must be ${policy.queueEmpty.requiredOpenIssueCount}; received ${queueEmpty.openIssueCount}.`
      )
    );
  }

  const releaseCandidateReady =
    releaseSummary?.schema === policy.releaseCandidate.requiredSchema &&
    (!policy.releaseCandidate.requireValid || releaseSummary?.valid === true) &&
    releaseCandidateRegex.test(releaseSummary?.version ?? '');
  if (!releaseSummary) {
    blockers.push(
      createBlocker(
        'release-summary-missing',
        'Release summary is missing; the release-candidate state is not proven.'
      )
    );
  } else if (releaseSummary.schema !== policy.releaseCandidate.requiredSchema) {
    blockers.push(
      createBlocker(
        'release-summary-schema-mismatch',
        `Release summary schema must remain ${policy.releaseCandidate.requiredSchema}.`
      )
    );
  } else if (policy.releaseCandidate.requireValid && releaseSummary.valid !== true) {
    blockers.push(
      createBlocker(
        'release-summary-invalid',
        'Release summary must be valid before the template pivot can be considered.'
      )
    );
  } else if (!releaseCandidateRegex.test(releaseSummary.version ?? '')) {
    blockers.push(
      createBlocker(
        'release-not-release-candidate',
        `Release summary version must match ${policy.releaseCandidate.versionPatternDescription}; received ${releaseSummary.version ?? 'null'}.`
      )
    );
  }

  const handoffReady =
    handoffEntrypoint?.schema === policy.handoffEntrypoint.requiredSchema &&
    handoffEntrypoint?.status === policy.handoffEntrypoint.requiredStatus;
  if (!handoffEntrypoint) {
    blockers.push(
      createBlocker(
        'handoff-entrypoint-missing',
        'Handoff entrypoint status is missing; future-agent pivot readiness cannot be trusted.'
      )
    );
  } else if (handoffEntrypoint.schema !== policy.handoffEntrypoint.requiredSchema) {
    blockers.push(
      createBlocker(
        'handoff-entrypoint-schema-mismatch',
        `Handoff entrypoint status schema must remain ${policy.handoffEntrypoint.requiredSchema}.`
      )
    );
  } else if (handoffEntrypoint.status !== policy.handoffEntrypoint.requiredStatus) {
    blockers.push(
      createBlocker(
        'handoff-entrypoint-not-pass',
        `Handoff entrypoint status must be ${policy.handoffEntrypoint.requiredStatus}; received ${handoffEntrypoint.status}.`
      )
    );
  }

  const targetRepository = asOptional(policy.targetRepository);
  const templateAgentVerificationReady =
    templateAgentVerification?.schema === 'priority/template-agent-verification-report@v1' &&
    templateAgentVerification?.summary?.status === 'pass' &&
    templateAgentVerification?.verification?.status === 'pass' &&
    asOptional(templateAgentVerification?.lane?.targetRepository) === targetRepository &&
    templateAgentVerificationTemplateDependencyReady &&
    templateAgentVerificationExecutionReady;
  if (!templateAgentVerification) {
    blockers.push(
      createBlocker(
        'template-agent-verification-report-missing',
        'Template-agent verification report is missing; consumer-proving health is not yet proven.'
      )
    );
  } else if (templateAgentVerification.schema !== 'priority/template-agent-verification-report@v1') {
    blockers.push(
      createBlocker(
        'template-agent-verification-schema-mismatch',
        'Template-agent verification report schema must remain priority/template-agent-verification-report@v1.'
      )
    );
  } else if (templateAgentVerification.summary?.status !== 'pass') {
    blockers.push(
      createBlocker(
        'template-agent-verification-not-pass',
        `Template-agent verification summary.status must be pass; received ${templateAgentVerification.summary?.status ?? 'null'}.`
      )
    );
  } else if (templateAgentVerification.verification?.status !== 'pass') {
    blockers.push(
      createBlocker(
        'template-agent-verification-status-not-pass',
        `Template-agent verification status must be pass; received ${templateAgentVerification.verification?.status ?? 'null'}.`
      )
    );
  } else if (asOptional(templateAgentVerification?.lane?.targetRepository) !== targetRepository) {
    blockers.push(
      createBlocker(
        'template-agent-target-repository-mismatch',
        `Template-agent verification lane target repository must be ${targetRepository ?? 'null'}; received ${
          asOptional(templateAgentVerification?.lane?.targetRepository) ?? 'null'
        }.`
      )
    );
  } else if (!templateDependencyPolicyReady) {
    blockers.push(
      createBlocker(
        'template-dependency-policy-missing',
        'Template pivot gate policy must pin the template dependency repository, version, ref, and cookiecutter version.'
      )
    );
  } else if (templateAgentVerificationTemplateDependency.repository !== policyTemplateDependency.repository) {
    blockers.push(
      createBlocker(
        'template-dependency-repository-mismatch',
        `Template dependency repository must be ${policyTemplateDependency.repository}; received ${
          templateAgentVerificationTemplateDependency.repository ?? 'null'
        }.`
      )
    );
  } else if (templateAgentVerificationTemplateDependency.version !== policyTemplateDependency.version) {
    blockers.push(
      createBlocker(
        'template-dependency-version-mismatch',
        `Template dependency version must be ${policyTemplateDependency.version}; received ${
          templateAgentVerificationTemplateDependency.version ?? 'null'
        }.`
      )
    );
  } else if (templateAgentVerificationTemplateDependency.ref !== policyTemplateDependency.ref) {
    blockers.push(
      createBlocker(
        'template-dependency-ref-mismatch',
        `Template dependency ref must be ${policyTemplateDependency.ref}; received ${
          templateAgentVerificationTemplateDependency.ref ?? 'null'
        }.`
      )
    );
  } else if (
    templateAgentVerificationTemplateDependency.cookiecutterVersion !== policyTemplateDependency.cookiecutterVersion
  ) {
    blockers.push(
      createBlocker(
        'template-dependency-cookiecutter-version-mismatch',
        `Template dependency cookiecutter version must be ${policyTemplateDependency.cookiecutterVersion}; received ${
          templateAgentVerificationTemplateDependency.cookiecutterVersion ?? 'null'
        }.`
      )
    );
  } else if (!templateAgentVerificationExecutionReady) {
    blockers.push(
      createBlocker(
        'template-agent-execution-provenance-incomplete',
        'Template-agent verification report must include execution-plane, container-image, consumer-workspace-root, lane-id, agent-id, and funding-window provenance.'
      )
    );
  }

  const ready = queueEmptyReady && releaseCandidateReady && handoffReady && templateAgentVerificationReady;
  const report = {
    schema: 'priority/template-pivot-gate@v1',
    generatedAt: now.toISOString(),
    repository: repo,
    targetRepository,
    policy: {
      path: toRelative(policyPath),
      sha256: sha256FileFn(policyPath),
      futureAgentOnly: policy.decision.futureAgentOnly,
      operatorSteeringAllowed: policy.decision.operatorSteeringAllowed,
      requirePreciseSessionFeedback: policy.decision.requirePreciseSessionFeedback,
      templateDependency: {
        repository: policyTemplateDependency.repository,
        version: policyTemplateDependency.version,
        ref: policyTemplateDependency.ref,
        cookiecutterVersion: policyTemplateDependency.cookiecutterVersion
      },
      releaseCandidateVersionPattern: policy.releaseCandidate.versionPattern,
      releaseCandidateVersionPatternDescription: policy.releaseCandidate.versionPatternDescription
    },
    inputs: {
      queueEmptyReportPath: toRelative(queueEmptyReportPath),
      releaseSummaryPath: toRelative(releaseSummaryPath),
      handoffEntrypointStatusPath: toRelative(handoffEntrypointStatusPath),
      templateAgentVerificationReportPath: toRelative(templateAgentVerificationReportPath)
    },
    evidence: {
      queueEmpty: {
        reportPath: toRelative(queueEmptyReportPath),
        exists: queueEmpty != null,
        schema: queueEmpty?.schema ?? null,
        reason: queueEmpty?.reason ?? null,
        openIssueCount: queueEmpty?.openIssueCount ?? null,
        ready: queueEmptyReady
      },
      releaseCandidate: {
        reportPath: toRelative(releaseSummaryPath),
        exists: releaseSummary != null,
        schema: releaseSummary?.schema ?? null,
        version: releaseSummary?.version ?? null,
        valid: releaseSummary?.valid ?? null,
        matchesVersionPattern: releaseCandidateRegex.test(releaseSummary?.version ?? ''),
        ready: releaseCandidateReady
      },
      handoffEntrypoint: {
        reportPath: toRelative(handoffEntrypointStatusPath),
        exists: handoffEntrypoint != null,
        schema: handoffEntrypoint?.schema ?? null,
        status: handoffEntrypoint?.status ?? null,
        ready: handoffReady
      },
      templateAgentVerification: {
        reportPath: toRelative(templateAgentVerificationReportPath),
        exists: templateAgentVerification != null,
        schema: templateAgentVerification?.schema ?? null,
        summaryStatus: templateAgentVerification?.summary?.status ?? null,
        verificationStatus: templateAgentVerification?.verification?.status ?? null,
        targetRepository: asOptional(templateAgentVerification?.lane?.targetRepository),
        consumerRailBranch: asOptional(templateAgentVerification?.lane?.consumerRailBranch),
        templateDependency: {
          repository: templateAgentVerificationTemplateDependency.repository,
          version: templateAgentVerificationTemplateDependency.version,
          ref: templateAgentVerificationTemplateDependency.ref,
          cookiecutterVersion: templateAgentVerificationTemplateDependency.cookiecutterVersion,
          matchesPolicy: templateAgentVerificationTemplateDependencyReady
        },
        execution: {
          executionPlane: templateAgentVerificationExecution.executionPlane,
          containerImage: templateAgentVerificationExecution.containerImage,
          generatedConsumerWorkspaceRoot: templateAgentVerificationExecution.generatedConsumerWorkspaceRoot,
          laneId: templateAgentVerificationExecution.laneId,
          agentId: templateAgentVerificationExecution.agentId,
          fundingWindowId: templateAgentVerificationExecution.fundingWindowId,
          complete: templateAgentVerificationExecutionReady
        },
        ready: templateAgentVerificationReady
      }
    },
    summary: {
      status: ready ? 'ready' : 'blocked',
      readyForFutureAgentPivot: ready,
      pivotDecision: ready ? 'future-agent-may-pivot' : 'stay-in-compare-vi-cli-action',
      blockerCount: blockers.length,
      blockers
    }
  };

  const outputPath = writeJsonFn(options.outputPath || policy.artifacts?.defaultOutputPath || DEFAULT_OUTPUT_PATH, report);
  return { report, outputPath };
}

export async function main(argv = process.argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    console.error(`[template-pivot-gate] ${error.message}`);
    printHelp(console.error);
    return 1;
  }

  if (args.help) {
    printHelp();
    return 0;
  }

  try {
    const { report, outputPath } = await runTemplatePivotGate(args);
    console.log(
      `[template-pivot-gate] wrote ${outputPath} (${report.summary.status}, blockers=${report.summary.blockerCount})`
    );
    return report.summary.status === 'ready' ? 0 : 1;
  } catch (error) {
    console.error(`[template-pivot-gate] ${error.message}`);
    return 1;
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  const exitCode = await main(process.argv);
  if (exitCode !== 0) {
    process.exit(exitCode);
  }
}
