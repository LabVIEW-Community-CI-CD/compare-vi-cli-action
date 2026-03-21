#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/downstream-promotion-scorecard@v1';
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'promotion',
  'downstream-develop-promotion-scorecard.json'
);

function printUsage() {
  console.log('Usage: node tools/priority/downstream-promotion-scorecard.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --success-report <path>         Downstream onboarding success report JSON path (required).');
  console.log('  --feedback-report <path>        Downstream onboarding feedback report JSON path (required).');
  console.log('  --manifest-report <path>        Downstream promotion manifest JSON path (optional).');
  console.log(`  --output <path>                 Output path (default: ${DEFAULT_OUTPUT_PATH}).`);
  console.log('  --repo <owner/repo>             Repository slug override.');
  console.log('  --fail-on-blockers              Exit non-zero when blockers exist (default true).');
  console.log('  --no-fail-on-blockers           Emit scorecard without failing process exit.');
  console.log('  -h, --help                      Show this message and exit.');
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
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

function loadInputFile(filePath) {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    return { exists: false, path: resolvedPath, payload: null, error: null };
  }
  try {
    return {
      exists: true,
      path: resolvedPath,
      payload: JSON.parse(fs.readFileSync(resolvedPath, 'utf8')),
      error: null
    };
  } catch (error) {
    return { exists: true, path: resolvedPath, payload: null, error: error.message || String(error) };
  }
}

function toNonNegativeInteger(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    successReportPath: null,
    feedbackReportPath: null,
    manifestReportPath: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    repo: null,
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
      token === '--success-report' ||
      token === '--feedback-report' ||
      token === '--manifest-report' ||
      token === '--output' ||
      token === '--repo'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--success-report') options.successReportPath = next;
      if (token === '--feedback-report') options.feedbackReportPath = next;
      if (token === '--manifest-report') options.manifestReportPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--repo') options.repo = next;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help && !normalizeText(options.successReportPath)) {
    throw new Error('Missing required option: --success-report <path>.');
  }
  if (!options.help && !normalizeText(options.feedbackReportPath)) {
    throw new Error('Missing required option: --feedback-report <path>.');
  }
  return options;
}

function statusFromSuccessReport(payload) {
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'missing',
      schema: null,
      summaryStatus: null,
      repositoriesEvaluated: null,
      totalBlockers: null,
      totalWarnings: null
    };
  }

  const schema = normalizeText(payload.schema) || null;
  const summaryStatus = normalizeText(payload?.summary?.status) || null;
  const totalBlockers = toNonNegativeInteger(payload?.summary?.totalBlockers);
  const totalWarnings = toNonNegativeInteger(payload?.summary?.totalWarnings);
  const repositoriesEvaluated = toNonNegativeInteger(payload?.summary?.repositoriesEvaluated);

  return {
    status:
      schema === 'priority/downstream-onboarding-success@v1' && Number.isFinite(totalBlockers) && totalBlockers === 0
        ? 'pass'
        : 'fail',
    schema,
    summaryStatus,
    repositoriesEvaluated,
    totalBlockers,
    totalWarnings
  };
}

function statusFromFeedbackReport(payload) {
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'missing',
      schema: null,
      executionStatus: null,
      evaluateExitCode: null,
      successExitCode: null,
      downstreamRepository: null
    };
  }

  const schema = normalizeText(payload.schema) || null;
  const executionStatus = normalizeText(payload?.execution?.status) || null;
  return {
    status: schema === 'priority/downstream-onboarding-feedback@v1' && executionStatus === 'pass' ? 'pass' : 'fail',
    schema,
    executionStatus,
    evaluateExitCode: toNonNegativeInteger(payload?.execution?.evaluateExitCode),
    successExitCode: toNonNegativeInteger(payload?.execution?.successExitCode),
    downstreamRepository: normalizeText(payload?.inputs?.downstreamRepository) || null
  };
}

function statusFromManifestReport(payload) {
  if (!payload || typeof payload !== 'object') {
    return {
      status: 'missing',
      schema: null,
      targetBranch: null,
      targetBranchClassId: null,
      sourceRef: null,
      sourceCommitSha: null,
      localSourceMatched: null,
      compareviToolsRelease: null,
      compareviHistoryRelease: null,
      scenarioPackIdentity: null,
      cookiecutterTemplateIdentity: null
    };
  }

  const schema = normalizeText(payload.schema) || null;
  const targetBranch = normalizeText(payload?.promotion?.targetBranch) || null;
  const targetBranchClassId = normalizeText(payload?.promotion?.targetBranchClassId) || null;
  const sourceRef = normalizeText(payload?.promotion?.sourceRef) || null;
  const sourceCommitSha = normalizeText(payload?.promotion?.sourceCommitSha) || null;
  const localSourceMatched =
    typeof payload?.promotion?.localSourceVerification?.matched === 'boolean'
      ? payload.promotion.localSourceVerification.matched
      : null;

  return {
    status:
      schema === 'priority/downstream-promotion-manifest@v1' &&
      targetBranch === 'downstream/develop' &&
      targetBranchClassId === 'downstream-consumer-proving-rail' &&
      localSourceMatched === true
        ? 'pass'
        : 'fail',
    schema,
    targetBranch,
    targetBranchClassId,
    sourceRef,
    sourceCommitSha,
    localSourceMatched,
    compareviToolsRelease: normalizeText(payload?.inputs?.compareviToolsRelease) || null,
    compareviHistoryRelease: normalizeText(payload?.inputs?.compareviHistoryRelease) || null,
    scenarioPackIdentity: normalizeText(payload?.inputs?.scenarioPackIdentity) || null,
    cookiecutterTemplateIdentity: normalizeText(payload?.inputs?.cookiecutterTemplateIdentity) || null
  };
}

export function evaluateDownstreamPromotionScorecard({
  successReport,
  feedbackReport,
  manifestReport,
  successGate,
  feedbackGate,
  manifestGate
}) {
  const blockers = [];
  const recordBlocker = (code, message) => blockers.push({ code, message });

  if (!successReport.exists || successReport.error) {
    recordBlocker('success-report-missing', 'Downstream onboarding success report is missing or unreadable.');
  }
  if (!feedbackReport.exists || feedbackReport.error) {
    recordBlocker('feedback-report-missing', 'Downstream onboarding feedback report is missing or unreadable.');
  }
  if (successGate.status !== 'pass') {
    recordBlocker(
      'downstream-blockers',
      `Downstream onboarding success report recorded ${successGate.totalBlockers ?? 'unknown'} blocking checklist gap(s).`
    );
  }
  if (feedbackGate.status !== 'pass') {
    recordBlocker('feedback-execution', `Downstream onboarding feedback execution status is ${feedbackGate.executionStatus ?? 'missing'}.`);
  }
  if (manifestReport?.error) {
    recordBlocker('manifest-report-unreadable', 'Downstream promotion manifest is unreadable.');
  }
  if (manifestReport?.exists && manifestGate.status !== 'pass') {
    recordBlocker(
      'manifest-contract',
      `Downstream promotion manifest did not verify immutable downstream/develop proving inputs (status=${manifestGate.status}).`
    );
  }

  return {
    status: blockers.length === 0 ? 'pass' : 'fail',
    blockerCount: blockers.length,
    blockers
  };
}

function writeJson(filePath, payload) {
  const resolvedPath = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.writeFileSync(resolvedPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolvedPath;
}

export function runDownstreamPromotionScorecard(rawOptions = {}) {
  const options = {
    ...rawOptions,
    outputPath: rawOptions.outputPath || DEFAULT_OUTPUT_PATH,
    failOnBlockers: rawOptions.failOnBlockers !== false
  };

  const successReport = loadInputFile(options.successReportPath);
  const feedbackReport = loadInputFile(options.feedbackReportPath);
  const manifestReport = options.manifestReportPath ? loadInputFile(options.manifestReportPath) : null;
  const successGate = statusFromSuccessReport(successReport.payload);
  const feedbackGate = statusFromFeedbackReport(feedbackReport.payload);
  const manifestGate = statusFromManifestReport(manifestReport?.payload);
  const summary = evaluateDownstreamPromotionScorecard({
    successReport,
    feedbackReport,
    manifestReport,
    successGate,
    feedbackGate,
    manifestGate
  });

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: new Date().toISOString(),
    repository: resolveRepoSlug(options.repo),
    inputs: {
      successReport: {
        path: successReport.path,
        exists: successReport.exists,
        error: successReport.error
      },
      feedbackReport: {
        path: feedbackReport.path,
        exists: feedbackReport.exists,
        error: feedbackReport.error
      },
      manifestReport: {
        path: manifestReport?.path ?? null,
        exists: manifestReport?.exists ?? false,
        error: manifestReport?.error ?? null
      }
    },
    gates: {
      successReport: successGate,
      feedbackReport: feedbackGate,
      manifestReport: manifestGate
    },
    summary: {
      ...summary,
      metrics: {
        repositoriesEvaluated: successGate.repositoriesEvaluated,
        totalBlockers: successGate.totalBlockers,
        totalWarnings: successGate.totalWarnings
      },
      provenance: {
        sourceRef: manifestGate.sourceRef,
        sourceCommitSha: manifestGate.sourceCommitSha,
        compareviToolsRelease: manifestGate.compareviToolsRelease,
        compareviHistoryRelease: manifestGate.compareviHistoryRelease,
        scenarioPackIdentity: manifestGate.scenarioPackIdentity,
        cookiecutterTemplateIdentity: manifestGate.cookiecutterTemplateIdentity
      }
    }
  };

  const reportPath = writeJson(options.outputPath, report);
  console.log(
    `[downstream-promotion-scorecard] report: ${reportPath} (status=${report.summary.status}, blockers=${report.summary.blockerCount})`
  );

  if (process.env.GITHUB_STEP_SUMMARY) {
    const lines = [
      '## Downstream Promotion Scorecard',
      `- status: \`${report.summary.status}\``,
      `- blockers: \`${report.summary.blockerCount}\``,
      `- repositories evaluated: \`${report.summary.metrics.repositoriesEvaluated ?? 'n/a'}\``,
      `- total blockers: \`${report.summary.metrics.totalBlockers ?? 'n/a'}\``,
      `- total warnings: \`${report.summary.metrics.totalWarnings ?? 'n/a'}\``,
      `- manifest status: \`${report.gates.manifestReport.status}\``,
      `- CompareVI.Tools: \`${report.summary.provenance.compareviToolsRelease ?? 'n/a'}\``,
      `- comparevi-history: \`${report.summary.provenance.compareviHistoryRelease ?? 'n/a'}\``,
      `- scenario/corpus: \`${report.summary.provenance.scenarioPackIdentity ?? 'n/a'}\``,
      `- cookiecutter template: \`${report.summary.provenance.cookiecutterTemplateIdentity ?? 'n/a'}\``
    ];
    for (const blocker of report.summary.blockers) {
      lines.push(`- ${blocker.code}: ${blocker.message}`);
    }
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`, 'utf8');
  }

  return {
    exitCode: report.summary.blockerCount > 0 && options.failOnBlockers ? 1 : 0,
    report,
    reportPath
  };
}

export function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  const result = runDownstreamPromotionScorecard(options);
  return result.exitCode;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    process.exitCode = main(process.argv);
  } catch (error) {
    console.error(error?.stack ?? error?.message ?? String(error));
    process.exitCode = 1;
  }
}
