#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'vi-history/cross-plane-performance-budget@v1';
export const DEFAULT_OUTPUT_PATH = path.join('tests', 'results', '_agent', 'vi-history', 'cross-plane-performance-budget.json');
export const DEFAULT_WINDOWS_THRESHOLD_RATIO = 1.2;
export const DEFAULT_SHADOW_ACCELERATOR_RATIO = 1.0;

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

function asOptional(value) {
  const text = normalizeText(value);
  return text || null;
}

function parsePositiveNumber(value, flag) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`Invalid value for ${flag}: ${value}`);
  }
  return parsed;
}

function parseBooleanFlag(options, key, argv, index) {
  if (argv[index + 1] && !argv[index + 1].startsWith('-')) {
    throw new Error(`${argv[index]} does not accept a value.`);
  }
  options[key] = true;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    linuxReceiptPath: null,
    windowsReceiptPath: null,
    shadowReceiptPath: null,
    hostPlaneReportPath: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    markdownPath: null,
    windowsThresholdRatio: DEFAULT_WINDOWS_THRESHOLD_RATIO,
    shadowAcceleratorRatio: DEFAULT_SHADOW_ACCELERATOR_RATIO,
    windowsOverBudgetJustification: null,
    failOnWarn: false,
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];

    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (token === '--fail-on-warn') {
      parseBooleanFlag(options, 'failOnWarn', args, index);
      continue;
    }

    if (
      token === '--linux-receipt' ||
      token === '--windows-receipt' ||
      token === '--shadow-receipt' ||
      token === '--host-plane-report' ||
      token === '--output' ||
      token === '--markdown' ||
      token === '--windows-threshold-ratio' ||
      token === '--shadow-accelerator-ratio' ||
      token === '--windows-over-budget-justification'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--linux-receipt') options.linuxReceiptPath = next;
      if (token === '--windows-receipt') options.windowsReceiptPath = next;
      if (token === '--shadow-receipt') options.shadowReceiptPath = next;
      if (token === '--host-plane-report') options.hostPlaneReportPath = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--markdown') options.markdownPath = next;
      if (token === '--windows-threshold-ratio') options.windowsThresholdRatio = parsePositiveNumber(next, token);
      if (token === '--shadow-accelerator-ratio') options.shadowAcceleratorRatio = parsePositiveNumber(next, token);
      if (token === '--windows-over-budget-justification') options.windowsOverBudgetJustification = normalizeText(next);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.linuxReceiptPath) {
      throw new Error('Missing required --linux-receipt.');
    }
    if (!options.windowsReceiptPath) {
      throw new Error('Missing required --windows-receipt.');
    }
  }

  return options;
}

function deriveMarkdownPath(outputPath, markdownPath) {
  if (markdownPath) {
    return markdownPath;
  }
  const ext = path.extname(outputPath);
  if (ext) {
    return `${outputPath.slice(0, -ext.length)}.md`;
  }
  return `${outputPath}.md`;
}

async function readJson(filePath) {
  const resolved = path.resolve(process.cwd(), filePath);
  const payload = JSON.parse(await fs.readFile(resolved, 'utf8'));
  return { resolvedPath: resolved, payload };
}

async function readJsonOptional(filePath) {
  if (!filePath) {
    return null;
  }
  return readJson(filePath);
}

async function resolveMeasurementInput(filePath) {
  const initial = await readJson(filePath);
  const sessionPayload = initial.payload;
  if (
    sessionPayload &&
    sessionPayload.schema === 'comparevi/local-operator-session@v1' &&
    sessionPayload.artifacts &&
    sessionPayload.artifacts.localRefinementPath
  ) {
    const refinementPath = path.resolve(path.dirname(initial.resolvedPath), sessionPayload.artifacts.localRefinementPath);
    const refinementPayload = JSON.parse(await fs.readFile(refinementPath, 'utf8'));
    return {
      sourcePath: initial.resolvedPath,
      sourceSchema: sessionPayload.schema,
      measurementPath: refinementPath,
      measurementSchema: refinementPayload?.schema ? String(refinementPayload.schema) : 'unknown',
      payload: refinementPayload,
    };
  }

  return {
    sourcePath: initial.resolvedPath,
    sourceSchema: initial.payload?.schema ? String(initial.payload.schema) : 'unknown',
    measurementPath: initial.resolvedPath,
    measurementSchema: initial.payload?.schema ? String(initial.payload.schema) : 'unknown',
    payload: initial.payload,
  };
}

function toFiniteMilliseconds(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`Missing or invalid ${fieldName}.`);
  }
  return Math.trunc(parsed);
}

function toFiniteSeconds(value, fieldName) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`Missing or invalid ${fieldName}.`);
  }
  return Number(parsed.toFixed(3));
}

function toComparablePath(targetPath, repoRoot) {
  const targetText = asOptional(targetPath);
  if (!targetText) {
    return null;
  }
  if (!repoRoot) {
    return targetText.replace(/\\/g, '/');
  }

  const resolvedRepoRoot = path.resolve(repoRoot);
  const resolvedTargetPath = path.resolve(targetText);
  const relative = path.relative(resolvedRepoRoot, resolvedTargetPath);
  if (relative && !relative.startsWith('..') && !path.isAbsolute(relative)) {
    return relative.replace(/\\/g, '/');
  }
  return resolvedTargetPath.replace(/\\/g, '/');
}

function normalizeHistory(history, repoRoot) {
  if (!history || typeof history !== 'object') {
    throw new Error('Missing history payload.');
  }

  return {
    targetPath: asOptional(history.targetPath),
    targetPathComparable: toComparablePath(history.targetPath, repoRoot),
    branchRef: asOptional(history.branchRef),
    baselineRef: asOptional(history.baselineRef),
    maxPairs: Number.isFinite(Number(history.maxPairs)) ? Math.trunc(Number(history.maxPairs)) : null,
    maxCommitCount: Number.isFinite(Number(history.maxCommitCount)) ? Math.trunc(Number(history.maxCommitCount)) : null,
  };
}

function normalizeMeasurement(role, measurementInput) {
  const payload = measurementInput.payload;
  if (!payload || typeof payload !== 'object') {
    throw new Error(`Unable to parse ${role} receipt payload.`);
  }

  const repoRoot = asOptional(payload.repoRoot);
  const history = normalizeHistory(payload.history, repoRoot);
  const timings = payload.timings && typeof payload.timings === 'object' ? payload.timings : null;
  if (!timings) {
    throw new Error(`Missing timings payload for ${role} receipt.`);
  }

  return {
    role,
    source: {
      path: measurementInput.sourcePath,
      schema: measurementInput.sourceSchema,
      measurementPath: measurementInput.measurementPath,
      measurementSchema: measurementInput.measurementSchema,
    },
    runtimeProfile: asOptional(payload.runtimeProfile),
    runtimePlane: asOptional(payload.runtimePlane),
    benchmarkSampleKind: asOptional(payload.benchmarkSampleKind),
    repoRoot,
    resultsRoot: asOptional(payload.resultsRoot),
    finalStatus: asOptional(payload.finalStatus) ?? 'unknown',
    history,
    timings: {
      elapsedMilliseconds: toFiniteMilliseconds(timings.elapsedMilliseconds, `${role}.timings.elapsedMilliseconds`),
      elapsedSeconds: toFiniteSeconds(timings.elapsedSeconds, `${role}.timings.elapsedSeconds`),
    },
  };
}

function compareWorkloads(referencePlane, candidatePlane) {
  const mismatches = [];
  const referenceHistory = referencePlane.history;
  const candidateHistory = candidatePlane.history;
  const fields = [
    ['targetPath', referenceHistory.targetPathComparable, candidateHistory.targetPathComparable],
    ['branchRef', referenceHistory.branchRef, candidateHistory.branchRef],
    ['baselineRef', referenceHistory.baselineRef, candidateHistory.baselineRef],
    ['maxPairs', referenceHistory.maxPairs, candidateHistory.maxPairs],
    ['maxCommitCount', referenceHistory.maxCommitCount, candidateHistory.maxCommitCount],
  ];

  for (const [field, left, right] of fields) {
    if (left !== right) {
      mismatches.push({
        field,
        reference: left,
        candidate: right,
      });
    }
  }

  return mismatches;
}

function buildBudgetComparison({
  key,
  baseline,
  candidate,
  thresholdRatio,
  justification = null,
}) {
  const ratio = Number((candidate.timings.elapsedMilliseconds / baseline.timings.elapsedMilliseconds).toFixed(4));
  const deltaMilliseconds = candidate.timings.elapsedMilliseconds - baseline.timings.elapsedMilliseconds;
  const withinBudget = ratio <= thresholdRatio;
  const status = withinBudget ? 'pass' : justification ? 'warn' : 'fail';

  return {
    key,
    kind: 'budget-max',
    baselinePlane: baseline.role,
    candidatePlane: candidate.role,
    baselineMilliseconds: baseline.timings.elapsedMilliseconds,
    candidateMilliseconds: candidate.timings.elapsedMilliseconds,
    deltaMilliseconds,
    candidateToBaselineRatio: ratio,
    thresholdRatio: Number(thresholdRatio.toFixed(4)),
    withinBudget,
    justification: justification || null,
    status,
    message: withinBudget
      ? `${candidate.role} stays within ${thresholdRatio.toFixed(2)}x of ${baseline.role}.`
      : justification
        ? `${candidate.role} exceeds ${thresholdRatio.toFixed(2)}x of ${baseline.role}, but justification was provided.`
        : `${candidate.role} exceeds ${thresholdRatio.toFixed(2)}x of ${baseline.role}.`,
  };
}

function buildAccelerationComparison({
  key,
  baseline,
  candidate,
  thresholdRatio,
}) {
  const ratio = Number((candidate.timings.elapsedMilliseconds / baseline.timings.elapsedMilliseconds).toFixed(4));
  const deltaMilliseconds = candidate.timings.elapsedMilliseconds - baseline.timings.elapsedMilliseconds;
  const isAccelerator = ratio < thresholdRatio;

  return {
    key,
    kind: 'accelerator',
    baselinePlane: baseline.role,
    candidatePlane: candidate.role,
    baselineMilliseconds: baseline.timings.elapsedMilliseconds,
    candidateMilliseconds: candidate.timings.elapsedMilliseconds,
    deltaMilliseconds,
    candidateToBaselineRatio: ratio,
    thresholdRatio: Number(thresholdRatio.toFixed(4)),
    withinBudget: isAccelerator,
    justification: null,
    status: isAccelerator ? 'pass' : 'warn',
    message: isAccelerator
      ? `${candidate.role} is acting as a throughput accelerator against ${baseline.role}.`
      : `${candidate.role} is not acting as a throughput accelerator against ${baseline.role}.`,
  };
}

function summarizeShadowAcceleration(shadowComparisons) {
  if (!shadowComparisons.length) {
    return {
      status: 'missing',
      message: 'Shadow 32-bit timing receipt was not provided.',
      fasterThan: [],
    };
  }

  const fasterThan = shadowComparisons.filter((entry) => entry.status === 'pass').map((entry) => entry.baselinePlane);
  if (fasterThan.length > 0) {
    return {
      status: 'pass',
      message: `Shadow 32-bit is faster than ${fasterThan.join(', ')}.`,
      fasterThan,
    };
  }

  return {
    status: 'warn',
    message: 'Shadow 32-bit is measured but not faster than the container planes that were compared.',
    fasterThan: [],
  };
}

function normalizeHostPlaneReport(reportInput) {
  if (!reportInput) {
    return null;
  }

  const payload = reportInput.payload;
  const native = payload && payload.native && typeof payload.native === 'object' ? payload.native : null;
  const planes = native && native.planes && typeof native.planes === 'object' ? native.planes : null;
  const x32 = planes && planes.x32 && typeof planes.x32 === 'object' ? planes.x32 : null;
  const x64 = planes && planes.x64 && typeof planes.x64 === 'object' ? planes.x64 : null;

  return {
    path: reportInput.resolvedPath,
    schema: payload?.schema ? String(payload.schema) : 'unknown',
    native32Status: asOptional(x32?.status),
    native64Status: asOptional(x64?.status),
    parallelLabVIEWSupported: native?.parallelLabVIEWSupported === true,
  };
}

function collectIssues(planes, windowsComparison, shadowComparisons, shadowSummary, hostPlaneReport) {
  const blockers = [];
  const warnings = [];

  for (const plane of [planes.linux, planes.windows]) {
    if (plane.finalStatus !== 'succeeded') {
      blockers.push({
        code: `${plane.role}-not-succeeded`,
        message: `${plane.role} receipt finalStatus is '${plane.finalStatus}'.`,
      });
    }
  }

  if (planes.windows.workloadMismatch.length > 0) {
    blockers.push({
      code: 'windows-workload-mismatch',
      message: 'Linux and Windows receipts do not describe the same certification workload.',
    });
  }

  if (planes.shadow32 && planes.shadow32.workloadMismatch.length > 0) {
    blockers.push({
      code: 'shadow-workload-mismatch',
      message: 'Shadow 32-bit receipt does not match the Linux certification workload.',
    });
  }

  if (windowsComparison.status === 'fail') {
    blockers.push({
      code: 'windows-over-budget',
      message: windowsComparison.message,
    });
  } else if (windowsComparison.status === 'warn') {
    warnings.push({
      code: 'windows-over-budget-justified',
      message: windowsComparison.message,
    });
  }

  if (!planes.shadow32) {
    warnings.push({
      code: 'shadow-measurement-missing',
      message: hostPlaneReport?.native32Status
        ? `Shadow 32-bit timing receipt missing; host native 32-bit readiness is '${hostPlaneReport.native32Status}'.`
        : 'Shadow 32-bit timing receipt missing.',
    });
  } else {
    for (const comparison of shadowComparisons) {
      if (comparison.status === 'warn') {
        warnings.push({
          code: `${comparison.key}-not-accelerating`,
          message: comparison.message,
        });
      }
    }
  }

  if (shadowSummary.status === 'warn') {
    warnings.push({
      code: 'shadow-not-accelerator',
      message: shadowSummary.message,
    });
  }

  return { blockers, warnings };
}

function buildMarkdown(report) {
  const lines = [];
  lines.push('### VI History Cross-Plane Performance Budget');
  lines.push('');
  lines.push(`- Overall: \`${report.overall.status}\``);
  lines.push(`- Workload: \`${report.workload.targetPathComparable || report.workload.targetPath || 'unknown'}\` @ \`${report.workload.branchRef || 'unknown'}\``);
  lines.push(`- Linux: \`${report.planes.linux.timings.elapsedSeconds}s\` (${report.planes.linux.benchmarkSampleKind || 'n/a'})`);
  lines.push(`- Windows: \`${report.planes.windows.timings.elapsedSeconds}s\` (${report.planes.windows.benchmarkSampleKind || 'n/a'})`);
  if (report.planes.shadow32) {
    lines.push(`- Shadow 32-bit: \`${report.planes.shadow32.timings.elapsedSeconds}s\` (${report.planes.shadow32.benchmarkSampleKind || 'n/a'})`);
  } else {
    lines.push(`- Shadow 32-bit: _not measured_${report.hostPlaneReport?.native32Status ? ` (host status: \`${report.hostPlaneReport.native32Status}\`)` : ''}`);
  }
  lines.push(`- Windows/Linux ratio: \`${report.comparisons.windowsVsLinux.candidateToBaselineRatio}x\` (budget <= \`${report.budget.windowsVsLinuxMaxRatio}x\`, status \`${report.comparisons.windowsVsLinux.status}\`)`);
  if (report.comparisons.shadowVsLinux) {
    lines.push(`- Shadow/Linux ratio: \`${report.comparisons.shadowVsLinux.candidateToBaselineRatio}x\` (status \`${report.comparisons.shadowVsLinux.status}\`)`);
  }
  if (report.comparisons.shadowVsWindows) {
    lines.push(`- Shadow/Windows ratio: \`${report.comparisons.shadowVsWindows.candidateToBaselineRatio}x\` (status \`${report.comparisons.shadowVsWindows.status}\`)`);
  }
  if (report.overall.blockers.length > 0) {
    lines.push(`- Blockers: ${report.overall.blockers.map((item) => `\`${item.code}\``).join(', ')}`);
  }
  if (report.overall.warnings.length > 0) {
    lines.push(`- Warnings: ${report.overall.warnings.map((item) => `\`${item.code}\``).join(', ')}`);
  }
  return `${lines.join('\n')}\n`;
}

export async function buildCrossPlaneBudgetReport({
  linuxReceiptPath,
  windowsReceiptPath,
  shadowReceiptPath = null,
  hostPlaneReportPath = null,
  windowsThresholdRatio = DEFAULT_WINDOWS_THRESHOLD_RATIO,
  shadowAcceleratorRatio = DEFAULT_SHADOW_ACCELERATOR_RATIO,
  windowsOverBudgetJustification = null,
  now = new Date(),
} = {}) {
  const linuxInput = await resolveMeasurementInput(linuxReceiptPath);
  const windowsInput = await resolveMeasurementInput(windowsReceiptPath);
  const shadowInput = shadowReceiptPath ? await resolveMeasurementInput(shadowReceiptPath) : null;
  const hostPlaneInput = await readJsonOptional(hostPlaneReportPath);

  const linux = normalizeMeasurement('linux', linuxInput);
  const windows = normalizeMeasurement('windows', windowsInput);
  const shadow32 = shadowInput ? normalizeMeasurement('shadow32', shadowInput) : null;

  linux.workloadMismatch = [];
  windows.workloadMismatch = compareWorkloads(linux, windows);
  if (shadow32) {
    shadow32.workloadMismatch = compareWorkloads(linux, shadow32);
  }

  const hostPlaneReport = normalizeHostPlaneReport(hostPlaneInput);
  const windowsComparison = buildBudgetComparison({
    key: 'windowsVsLinux',
    baseline: linux,
    candidate: windows,
    thresholdRatio: windowsThresholdRatio,
    justification: asOptional(windowsOverBudgetJustification),
  });

  const shadowComparisons = [];
  if (shadow32) {
    shadowComparisons.push(buildAccelerationComparison({
      key: 'shadowVsLinux',
      baseline: linux,
      candidate: shadow32,
      thresholdRatio: shadowAcceleratorRatio,
    }));
    shadowComparisons.push(buildAccelerationComparison({
      key: 'shadowVsWindows',
      baseline: windows,
      candidate: shadow32,
      thresholdRatio: shadowAcceleratorRatio,
    }));
  }

  const shadowSummary = summarizeShadowAcceleration(shadowComparisons);
  const issues = collectIssues(
    { linux, windows, shadow32 },
    windowsComparison,
    shadowComparisons,
    shadowSummary,
    hostPlaneReport,
  );

  const overallStatus = issues.blockers.length > 0 ? 'fail' : issues.warnings.length > 0 ? 'warn' : 'pass';
  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    budget: {
      windowsVsLinuxMaxRatio: Number(windowsThresholdRatio.toFixed(4)),
      shadowAccelerationMaxRatio: Number(shadowAcceleratorRatio.toFixed(4)),
      windowsOverBudgetJustification: asOptional(windowsOverBudgetJustification),
    },
    workload: {
      targetPath: linux.history.targetPath,
      targetPathComparable: linux.history.targetPathComparable,
      branchRef: linux.history.branchRef,
      baselineRef: linux.history.baselineRef,
      maxPairs: linux.history.maxPairs,
      maxCommitCount: linux.history.maxCommitCount,
      comparable: windows.workloadMismatch.length === 0 && (!shadow32 || shadow32.workloadMismatch.length === 0),
    },
    hostPlaneReport,
    planes: {
      linux,
      windows,
      shadow32,
    },
    comparisons: {
      windowsVsLinux: windowsComparison,
      shadowVsLinux: shadowComparisons.find((entry) => entry.key === 'shadowVsLinux') ?? null,
      shadowVsWindows: shadowComparisons.find((entry) => entry.key === 'shadowVsWindows') ?? null,
      shadowSummary,
    },
    overall: {
      status: overallStatus,
      blockers: issues.blockers,
      warnings: issues.warnings,
    },
  };

  return {
    report,
    markdown: buildMarkdown(report),
  };
}

async function writeOutputs(outputPath, markdownPath, report, markdown) {
  const resolvedOutputPath = path.resolve(process.cwd(), outputPath);
  const resolvedMarkdownPath = path.resolve(process.cwd(), markdownPath);
  await fs.mkdir(path.dirname(resolvedOutputPath), { recursive: true });
  await fs.mkdir(path.dirname(resolvedMarkdownPath), { recursive: true });
  await fs.writeFile(resolvedOutputPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  await fs.writeFile(resolvedMarkdownPath, markdown, 'utf8');
  return {
    outputPath: resolvedOutputPath,
    markdownPath: resolvedMarkdownPath,
  };
}

function printUsage() {
  console.log('Usage: node tools/priority/vi-history-cross-plane-budget.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --linux-receipt <path>                 Required Linux local-refinement receipt.');
  console.log('  --windows-receipt <path>               Required Windows mirror local-refinement receipt.');
  console.log('  --shadow-receipt <path>                Optional host-native 32-bit shadow timing receipt.');
  console.log('  --host-plane-report <path>             Optional LabVIEW 2026 host-plane diagnostics report.');
  console.log(`  --output <path>                        JSON report path (default: ${DEFAULT_OUTPUT_PATH})`);
  console.log('  --markdown <path>                      Markdown summary path (default: alongside JSON report).');
  console.log(`  --windows-threshold-ratio <n>          Windows/Linux budget threshold (default: ${DEFAULT_WINDOWS_THRESHOLD_RATIO}).`);
  console.log(`  --shadow-accelerator-ratio <n>         Shadow acceleration threshold (default: ${DEFAULT_SHADOW_ACCELERATOR_RATIO}).`);
  console.log('  --windows-over-budget-justification <text>');
  console.log('                                         Downgrades an over-budget Windows ratio to warn.');
  console.log('  --fail-on-warn                         Return non-zero when the report status is warn.');
  console.log('  -h, --help                             Show help.');
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const markdownPath = deriveMarkdownPath(options.outputPath, options.markdownPath);
  const { report, markdown } = await buildCrossPlaneBudgetReport({
    linuxReceiptPath: options.linuxReceiptPath,
    windowsReceiptPath: options.windowsReceiptPath,
    shadowReceiptPath: options.shadowReceiptPath,
    hostPlaneReportPath: options.hostPlaneReportPath,
    windowsThresholdRatio: options.windowsThresholdRatio,
    shadowAcceleratorRatio: options.shadowAcceleratorRatio,
    windowsOverBudgetJustification: options.windowsOverBudgetJustification,
  });
  const written = await writeOutputs(options.outputPath, markdownPath, report, markdown);

  console.log(`[vi-history-cross-plane-budget] report: ${written.outputPath}`);
  console.log(`[vi-history-cross-plane-budget] markdown: ${written.markdownPath}`);
  console.log(`[vi-history-cross-plane-budget] overall=${report.overall.status} windowsRatio=${report.comparisons.windowsVsLinux.candidateToBaselineRatio}x`);

  if (report.overall.status === 'fail') {
    return 1;
  }
  if (report.overall.status === 'warn' && options.failOnWarn) {
    return 1;
  }
  return 0;
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
const modulePath = path.resolve(fileURLToPath(import.meta.url));
if (invokedPath && invokedPath === modulePath) {
  main(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error) => {
      console.error(`[vi-history-cross-plane-budget] ${error.message}`);
      process.exit(1);
    },
  );
}
