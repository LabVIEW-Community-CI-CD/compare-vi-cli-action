import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

export const REPORT_SCHEMA = 'priority/run-artifact-download@v1';
export const DEFAULT_DESTINATION_ROOT = path.join('tests', 'results', '_agent', 'reviews', 'run-artifacts');
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'run-artifact-download.json',
);

const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeInteger(value) {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = Number.parseInt(normalized, 10);
  return Number.isInteger(parsed) ? parsed : null;
}

function normalizeIso(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.valueOf())) {
    return null;
  }
  return parsed.toISOString();
}

function uniqueStrings(values) {
  return [...new Set((Array.isArray(values) ? values : []).map((value) => normalizeText(value)).filter(Boolean))];
}

function writeJsonFile(filePath, payload) {
  if (!filePath) {
    return null;
  }
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function listRelativeFiles(rootPath) {
  if (!fs.existsSync(rootPath)) {
    return [];
  }
  const files = [];
  const walk = (currentPath) => {
    for (const entry of fs.readdirSync(currentPath, { withFileTypes: true })) {
      const fullPath = path.join(currentPath, entry.name);
      if (entry.isDirectory()) {
        walk(fullPath);
        continue;
      }
      if (entry.isFile()) {
        files.push(path.relative(rootPath, fullPath));
      }
    }
  };
  walk(rootPath);
  return files.sort((left, right) => left.localeCompare(right));
}

function formatGhCommand(args) {
  return ['gh', ...args].join(' ');
}

export function isPolicyWrapperRejection(message) {
  const normalized = normalizeText(message)?.toLowerCase();
  if (!normalized) {
    return false;
  }
  return (
    normalized.includes('policy wrapper') ||
    normalized.includes('blocked by local shell policy') ||
    normalized.includes('blocked by shell policy') ||
    normalized.includes('running scripts is disabled') ||
    normalized.includes('execution of scripts is disabled') ||
    normalized.includes('cannot be loaded because running scripts is disabled') ||
    normalized.includes('not digitally signed')
  );
}

export function classifyArtifactDownloadFailure(message, fallback = 'download-failed') {
  const normalized = normalizeText(message);
  if (!normalized) {
    return fallback;
  }
  const lower = normalized.toLowerCase();
  if (isPolicyWrapperRejection(lower)) {
    return 'policy-wrapper-rejected';
  }
  if (
    lower.includes('unauthorized') ||
    lower.includes('authentication') ||
    lower.includes('forbidden') ||
    lower.includes('http 401') ||
    lower.includes('http 403') ||
    lower.includes('gh auth')
  ) {
    return 'auth-failed';
  }
  if (lower.includes('expired')) {
    return 'artifact-expired';
  }
  if (lower.includes('not found') || lower.includes('404')) {
    return 'artifact-not-found';
  }
  return fallback;
}

function runProcess(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  });

  return {
    status: result.status ?? 0,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    error: result.error ?? null,
  };
}

function runGhJson(args) {
  const result = runProcess('gh', args);
  if (result.error || result.status !== 0) {
    const message =
      normalizeText(result.stderr) ??
      normalizeText(result.stdout) ??
      (result.error instanceof Error ? result.error.message : normalizeText(result.error));
    throw new Error(message ?? `gh ${args.join(' ')} failed.`);
  }
  try {
    return JSON.parse(result.stdout ?? '{}');
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse JSON from gh ${args.join(' ')}: ${message}`);
  }
}

export function listRunArtifacts({ repository, runId, runGhJsonFn = runGhJson }) {
  const commandArgs = ['api', `repos/${repository}/actions/runs/${runId}/artifacts?per_page=100`];
  const payload = runGhJsonFn(commandArgs);
  const artifacts = Array.isArray(payload?.artifacts) ? payload.artifacts : [];
  return {
    command: formatGhCommand(commandArgs),
    artifacts: artifacts.map((artifact) => ({
      id: normalizeInteger(artifact?.id),
      name: normalizeText(artifact?.name),
      sizeInBytes: normalizeInteger(artifact?.size_in_bytes ?? artifact?.sizeInBytes),
      expired: Boolean(artifact?.expired),
      createdAt: normalizeIso(artifact?.created_at ?? artifact?.createdAt),
      updatedAt: normalizeIso(artifact?.updated_at ?? artifact?.updatedAt),
      workflowRun: artifact?.workflow_run
        ? {
            id: normalizeInteger(artifact.workflow_run.id),
            headBranch: normalizeText(artifact.workflow_run.head_branch ?? artifact.workflow_run.headBranch),
            headSha: normalizeText(artifact.workflow_run.head_sha ?? artifact.workflow_run.headSha),
          }
        : null,
    })),
  };
}

export function downloadNamedArtifacts({
  repository,
  runId,
  artifactNames,
  destinationRoot = DEFAULT_DESTINATION_ROOT,
  reportPath = DEFAULT_REPORT_PATH,
  now = new Date(),
  runGhJsonFn = runGhJson,
  runProcessFn = runProcess,
}) {
  const requestedArtifacts = uniqueStrings(artifactNames);
  const normalizedRunId = String(runId);
  const report = {
    schema: REPORT_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: new Date(now).toISOString(),
    status: 'pass',
    repository,
    runId: normalizedRunId,
    destinationRoot,
    requestedArtifacts,
    discovery: {
      status: 'pass',
      failureClass: null,
      command: null,
      errorMessage: null,
      availableArtifacts: [],
    },
    downloads: [],
    summary: {
      availableArtifactCount: 0,
      requestedArtifactCount: requestedArtifacts.length,
      downloadedCount: 0,
      missingCount: 0,
      failedCount: 0,
    },
    errors: [],
  };

  let availableArtifacts = [];
  try {
    const discovery = listRunArtifacts({
      repository,
      runId: normalizedRunId,
      runGhJsonFn,
    });
    availableArtifacts = discovery.artifacts;
    report.discovery.command = discovery.command;
    report.discovery.availableArtifacts = discovery.artifacts;
    report.summary.availableArtifactCount = discovery.artifacts.length;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    report.status = 'fail';
    report.discovery.status = 'fail';
    report.discovery.failureClass = classifyArtifactDownloadFailure(message, 'discovery-failed');
    report.discovery.errorMessage = message;
    report.errors.push(message);
    const resolvedReportPath = writeJsonFile(reportPath, report);
    return { report, reportPath: resolvedReportPath };
  }

  const artifactsByName = new Map(availableArtifacts.map((artifact) => [artifact.name, artifact]));

  for (const artifactName of requestedArtifacts) {
    const artifact = artifactsByName.get(artifactName) ?? null;
    const destination = path.join(destinationRoot, artifactName);
    const commandArgs = [
      'run',
      'download',
      normalizedRunId,
      '--repo',
      repository,
      '-n',
      artifactName,
      '-D',
      destination,
    ];
    const entry = {
      name: artifactName,
      status: 'downloaded',
      failureClass: null,
      command: formatGhCommand(commandArgs),
      destination,
      artifact,
      files: [],
      stdout: null,
      stderr: null,
      errorMessage: null,
    };

    if (!artifact) {
      entry.status = 'missing';
      entry.failureClass = 'artifact-not-found';
      entry.errorMessage = `Artifact ${artifactName} was not found for run ${normalizedRunId}.`;
      report.downloads.push(entry);
      report.summary.missingCount += 1;
      report.status = 'fail';
      report.errors.push(entry.errorMessage);
      continue;
    }

    if (artifact.expired) {
      entry.status = 'failed';
      entry.failureClass = 'artifact-expired';
      entry.errorMessage = `Artifact ${artifactName} for run ${normalizedRunId} is expired.`;
      report.downloads.push(entry);
      report.summary.failedCount += 1;
      report.status = 'fail';
      report.errors.push(entry.errorMessage);
      continue;
    }

    fs.mkdirSync(destination, { recursive: true });
    const result = runProcessFn('gh', commandArgs);
    entry.stdout = normalizeText(result.stdout);
    entry.stderr = normalizeText(result.stderr);

    if (result.error || result.status !== 0) {
      const message =
        normalizeText(result.stderr) ??
        normalizeText(result.stdout) ??
        (result.error instanceof Error ? result.error.message : normalizeText(result.error)) ??
        `gh run download exited with code ${result.status ?? 'unknown'}`;
      entry.status = 'failed';
      entry.failureClass = classifyArtifactDownloadFailure(message);
      entry.errorMessage = message;
      report.summary.failedCount += 1;
      report.status = 'fail';
      report.errors.push(message);
    } else {
      entry.files = listRelativeFiles(destination);
      report.summary.downloadedCount += 1;
    }

    report.downloads.push(entry);
  }

  const resolvedReportPath = writeJsonFile(reportPath, report);
  return { report, reportPath: resolvedReportPath };
}
