#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'supply-chain',
  'release-trust-gate.json'
);

const FAILURE_HINTS = {
  'missing-artifacts-root': 'Verify Publish CLI output path and ensure artifacts are generated before trust verification.',
  'missing-required-file': 'Regenerate release artifacts and ensure required files are present in artifacts/cli.',
  'no-distribution-artifacts': 'No .zip/.tar.gz assets were found. Re-run publish and verify RID packaging outputs.',
  'checksum-invalid-line': 'Regenerate SHA256SUMS.txt to restore valid "<sha256>  <path>" formatting.',
  'checksum-empty': 'SHA256SUMS.txt parsed as empty. Re-run Publish-Cli and ensure checksums are written.',
  'checksum-entry-missing-file': 'Checksum manifest references a file that does not exist. Regenerate artifacts/checksums together.',
  'checksum-missing-artifact': 'A published archive is missing from SHA256SUMS.txt. Re-run checksum generation.',
  'checksum-mismatch': 'Artifact hash does not match SHA256SUMS entry. Rebuild artifacts from a clean workspace.',
  'sbom-parse-failed': 'SBOM JSON is unreadable. Re-run Generate-ReleaseSbom.ps1 and validate output.',
  'sbom-invalid': 'SBOM content is missing required SPDX fields or artifact references. Regenerate SBOM.',
  'provenance-parse-failed': 'Provenance JSON is unreadable. Re-run Generate-ReleaseProvenance.ps1 and validate output.',
  'provenance-invalid': 'Provenance payload failed contract checks (schema/asset hash/identity). Regenerate provenance.',
  'tag-ref-missing': 'Release tag ref is unavailable. Ensure trust gate runs from a tag-triggered release event.',
  'tag-signature-cli-unavailable': 'GitHub CLI is unavailable. Install/enable gh on runner before tag signature verification.',
  'tag-ref-lookup-failed': 'Unable to resolve release tag via GitHub API. Confirm tag exists and token has repo read access.',
  'tag-object-lookup-failed': 'Unable to resolve annotated tag object via GitHub API. Confirm tag object availability.',
  'tag-signature-parse-failed': 'Tag signature payload could not be parsed. Re-run and inspect gh api output.',
  'tag-not-annotated':
    'Release tag is lightweight/non-annotated. Run priority:release:signing:readiness first; if the target tag already backs an immutable published GitHub Release, do not rerun repair_existing_tag on the same tag. Use the protected-tag authority path or publish a new authoritative tag. Otherwise, rerun .github/workflows/release-conductor.yml with repair_existing_tag = true to recreate the same release tag as a signed annotated tag.',
  'tag-signature-unverified':
    'Release tag signature is not verified. Run priority:release:signing:readiness first; if the target tag already backs an immutable published GitHub Release, do not rerun repair_existing_tag on the same tag. Use the protected-tag authority path or publish a new authoritative tag. Otherwise, rerun .github/workflows/release-conductor.yml with repair_existing_tag = true to repair the same release tag before rerunning release.',
  'attestation-cli-unavailable': 'GitHub CLI is unavailable. Install/enable gh on runner before trust gate.',
  'attestation-output-parse-failed': 'Attestation verification output was not valid JSON. Re-run verification and inspect gh logs.',
  'attestation-unverified': 'Artifact attestation verification failed. Confirm attest-build-provenance step and signer workflow.',
  'attestation-empty-result': 'No attestation records were returned. Confirm attestation publication and retry.'
};

const TOOLS_TAG_PATTERN = /^v?\d+\.\d+\.\d+-tools\.\d+$/i;

export function printUsage() {
  console.log('Usage: node tools/priority/supply-chain-trust-gate.mjs [options]');
  console.log('');
  console.log('Options:');
  console.log('  --repo <owner/repo>               Target repository (default: env/remotes).');
  console.log('  --artifacts-root <path>           Release artifact root (default: artifacts/cli).');
  console.log('  --checksums <path>                SHA256SUMS path (default: artifacts/cli/SHA256SUMS.txt).');
  console.log('  --sbom <path>                     SBOM path (default: artifacts/cli/sbom.spdx.json).');
  console.log('  --provenance <path>               Provenance path (default: artifacts/cli/provenance.json).');
  console.log('  --tag-ref <name>                  Release tag ref name (default: GITHUB_REF_NAME).');
  console.log(`  --report <path>                   Report output path (default: ${DEFAULT_REPORT_PATH}).`);
  console.log('  --signer-workflow <value>         Attestation signer workflow identity.');
  console.log('  --attestation-attempts <n>        Retry attempts for attestation verify (default: 6).');
  console.log('  --attestation-retry-seconds <n>   Retry delay in seconds (default: 10).');
  console.log('  --skip-tag-signature              Skip release tag signature verification (local/debug only).');
  console.log('  --skip-attestations               Skip gh attestation verification (local/debug only).');
  console.log('  -h, --help                        Show this message and exit.');
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repo: null,
    artifactsRoot: path.join('artifacts', 'cli'),
    checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
    sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
    provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
    tagRef: process.env.GITHUB_REF_NAME || null,
    reportPath: DEFAULT_REPORT_PATH,
    signerWorkflow: null,
    attestationAttempts: 6,
    attestationRetrySeconds: 10,
    verifyTagSignature: true,
    verifyAttestations: true,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    const next = args[index + 1];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--skip-attestations') {
      options.verifyAttestations = false;
      continue;
    }
    if (token === '--skip-tag-signature') {
      options.verifyTagSignature = false;
      continue;
    }

    if (
      token === '--repo' ||
      token === '--artifacts-root' ||
      token === '--checksums' ||
      token === '--sbom' ||
      token === '--provenance' ||
      token === '--tag-ref' ||
      token === '--report' ||
      token === '--signer-workflow'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = next;
      if (token === '--artifacts-root') options.artifactsRoot = next;
      if (token === '--checksums') options.checksumsPath = next;
      if (token === '--sbom') options.sbomPath = next;
      if (token === '--provenance') options.provenancePath = next;
      if (token === '--tag-ref') options.tagRef = next;
      if (token === '--report') options.reportPath = next;
      if (token === '--signer-workflow') options.signerWorkflow = next;
      continue;
    }

    if (token === '--attestation-attempts' || token === '--attestation-retry-seconds') {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      const parsed = Number.parseInt(next, 10);
      if (!Number.isFinite(parsed) || parsed < 0) {
        throw new Error(`Invalid value for ${token}: ${next}`);
      }
      if (token === '--attestation-attempts') options.attestationAttempts = parsed;
      if (token === '--attestation-retry-seconds') options.attestationRetrySeconds = parsed;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function parseRemoteUrl(url) {
  if (!url) return null;
  const sshMatch = url.match(/:(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const httpsMatch = url.match(/github\.com\/(?<repoPath>[^/]+\/[^/]+)(?:\.git)?$/);
  const repoPath = sshMatch?.groups?.repoPath ?? httpsMatch?.groups?.repoPath;
  if (!repoPath) return null;
  const [owner, rawRepo] = repoPath.split('/');
  if (!owner || !rawRepo) return null;
  const repo = rawRepo.endsWith('.git') ? rawRepo.slice(0, -4) : rawRepo;
  return `${owner}/${repo}`;
}

export function resolveRepositorySlug(explicitRepo) {
  if (explicitRepo) return explicitRepo;
  const envRepo = process.env.GITHUB_REPOSITORY?.trim();
  if (envRepo && envRepo.includes('/')) return envRepo;
  for (const remoteName of ['upstream', 'origin']) {
    try {
      const raw = execSync(`git config --get remote.${remoteName}.url`, {
        stdio: ['ignore', 'pipe', 'ignore']
      })
        .toString()
        .trim();
      const parsed = parseRemoteUrl(raw);
      if (parsed) return parsed;
    } catch {
      // ignore missing remotes
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

function normalizePathValue(value) {
  if (!value) return '';
  return String(value).replace(/\\/g, '/').replace(/^\.\/+/, '').replace(/^\/+/, '');
}

function stripUtf8Bom(text) {
  return String(text ?? '').replace(/^\uFEFF/, '');
}

function parseJsonText(text) {
  return JSON.parse(stripUtf8Bom(text));
}

function isToolsReleaseTag(tagRef) {
  return TOOLS_TAG_PATTERN.test(String(tagRef || '').trim());
}

function hashFileSha256(filePath) {
  const data = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(data).digest('hex');
}

function walkFilesRecursive(rootPath) {
  const files = [];
  if (!fs.existsSync(rootPath)) return files;
  for (const entry of fs.readdirSync(rootPath, { withFileTypes: true })) {
    const fullPath = path.join(rootPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFilesRecursive(fullPath));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
}

function addFailure(failures, code, message, target = null) {
  const payload = {
    code,
    message,
    hint: FAILURE_HINTS[code] || null
  };
  if (target) payload.target = target;
  failures.push(payload);
}

export function parseChecksumManifest(text) {
  const entries = [];
  const invalidLines = [];
  const lines = String(text || '').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const match = trimmed.match(/^([0-9a-fA-F]{64})\s+(.+)$/);
    if (!match) {
      invalidLines.push(trimmed);
      continue;
    }
    entries.push({
      sha256: match[1].toLowerCase(),
      rawPath: match[2],
      normalizedPath: normalizePathValue(match[2]),
      name: path.basename(normalizePathValue(match[2]))
    });
  }
  return { entries, invalidLines };
}

function buildFileIndex(files, repoRoot, artifactsRoot) {
  const byNormalizedPath = new Map();
  const byName = new Map();
  for (const absolutePath of files) {
    const relRepo = normalizePathValue(path.relative(repoRoot, absolutePath));
    const relArtifacts = normalizePathValue(path.relative(artifactsRoot, absolutePath));
    if (relRepo) byNormalizedPath.set(relRepo, absolutePath);
    if (relArtifacts) byNormalizedPath.set(relArtifacts, absolutePath);
    const name = path.basename(absolutePath);
    if (!byName.has(name)) byName.set(name, []);
    byName.get(name).push(absolutePath);
  }
  return { byNormalizedPath, byName };
}

function resolveChecksumTarget(entry, index) {
  const direct = index.byNormalizedPath.get(entry.normalizedPath);
  if (direct) return direct;
  const sameName = index.byName.get(entry.name) || [];
  if (sameName.length === 1) return sameName[0];
  return null;
}

function validateSbomPayload(sbom, archiveFiles, failures) {
  if (!sbom || typeof sbom !== 'object') {
    addFailure(failures, 'sbom-invalid', 'SBOM payload is not an object.');
    return { valid: false, spdxVersion: null, fileCount: 0 };
  }
  const spdxVersion = String(sbom.spdxVersion || '');
  if (spdxVersion !== 'SPDX-2.3') {
    addFailure(failures, 'sbom-invalid', `Expected spdxVersion=SPDX-2.3. Received: ${spdxVersion || '<empty>'}.`);
  }
  const sbomFiles = Array.isArray(sbom.files) ? sbom.files : [];
  if (sbomFiles.length === 0) {
    addFailure(failures, 'sbom-invalid', 'SBOM files array is empty.');
  }
  const sbomNames = new Set(
    sbomFiles.map((entry) => path.basename(normalizePathValue(entry?.fileName || '')).toLowerCase()).filter(Boolean)
  );
  for (const archivePath of archiveFiles) {
    const name = path.basename(archivePath).toLowerCase();
    if (!sbomNames.has(name)) {
      addFailure(failures, 'sbom-invalid', `SBOM does not reference distribution artifact '${name}'.`, name);
    }
  }
  return {
    valid: failures.filter((failure) => failure.code === 'sbom-invalid' || failure.code === 'sbom-parse-failed').length === 0,
    spdxVersion,
    fileCount: sbomFiles.length
  };
}

function validateProvenancePayload(provenance, context, archiveFiles, failures) {
  if (!provenance || typeof provenance !== 'object') {
    addFailure(failures, 'provenance-invalid', 'Provenance payload is not an object.');
    return { valid: false, schema: null, releaseAssetCount: 0 };
  }
  const schema = String(provenance.schema || '');
  if (schema !== 'run-provenance/v1') {
    addFailure(failures, 'provenance-invalid', `Expected schema=run-provenance/v1. Received: ${schema || '<empty>'}.`);
  }
  if (context.expectedRepository && provenance.repository && provenance.repository !== context.expectedRepository) {
    addFailure(
      failures,
      'provenance-invalid',
      `Provenance repository mismatch. expected=${context.expectedRepository} actual=${provenance.repository}.`
    );
  }
  if (context.expectedRunId && provenance.runId && String(provenance.runId) !== String(context.expectedRunId)) {
    addFailure(
      failures,
      'provenance-invalid',
      `Provenance runId mismatch. expected=${context.expectedRunId} actual=${provenance.runId}.`
    );
  }
  if (context.expectedHeadSha && provenance.headSha && String(provenance.headSha) !== String(context.expectedHeadSha)) {
    addFailure(
      failures,
      'provenance-invalid',
      `Provenance headSha mismatch. expected=${context.expectedHeadSha} actual=${provenance.headSha}.`
    );
  }

  const releaseAssets = Array.isArray(provenance.releaseAssets) ? provenance.releaseAssets : [];
  if (releaseAssets.length === 0) {
    addFailure(failures, 'provenance-invalid', 'Provenance releaseAssets array is empty.');
  }

  const expectedNames = new Set([
    ...archiveFiles.map((filePath) => path.basename(filePath)),
    'SHA256SUMS.txt',
    'sbom.spdx.json'
  ]);
  const releaseByName = new Map();
  for (const entry of releaseAssets) {
    const name = String(entry?.name || '').trim();
    if (!name) continue;
    releaseByName.set(name, entry);
  }
  for (const expectedName of expectedNames) {
    if (!releaseByName.has(expectedName)) {
      addFailure(
        failures,
        'provenance-invalid',
        `Provenance releaseAssets does not include '${expectedName}'.`,
        expectedName
      );
    }
  }

  return {
    valid: failures.filter((failure) => failure.code === 'provenance-invalid' || failure.code === 'provenance-parse-failed').length === 0,
    schema,
    releaseAssetCount: releaseAssets.length
  };
}

export function evaluateLocalIntegrity({
  repoRoot,
  artifactsRoot,
  checksumsPath,
  sbomPath,
  provenancePath,
  expectedRepository = null,
  expectedRunId = null,
  expectedHeadSha = null
}) {
  const failures = [];
  const resolvedRoot = path.resolve(repoRoot, artifactsRoot);
  const resolvedChecksums = path.resolve(repoRoot, checksumsPath);
  const resolvedSbom = path.resolve(repoRoot, sbomPath);
  const resolvedProvenance = path.resolve(repoRoot, provenancePath);

  if (!fs.existsSync(resolvedRoot)) {
    addFailure(failures, 'missing-artifacts-root', `Artifacts root not found: ${resolvedRoot}`, resolvedRoot);
    return {
      failures,
      artifactRecords: [],
      archiveFiles: [],
      checksums: { path: resolvedChecksums, exists: false, entryCount: 0, invalidLineCount: 0 },
      sbom: { path: resolvedSbom, exists: false, valid: false, spdxVersion: null, fileCount: 0 },
      provenance: { path: resolvedProvenance, exists: false, valid: false, schema: null, releaseAssetCount: 0 }
    };
  }

  const files = walkFilesRecursive(resolvedRoot);
  const archiveFiles = files.filter((filePath) => /\.(zip|tar\.gz)$/i.test(filePath));
  if (archiveFiles.length === 0) {
    addFailure(failures, 'no-distribution-artifacts', `No distribution archives found under ${resolvedRoot}.`);
  }

  for (const required of [
    { key: 'checksums', path: resolvedChecksums },
    { key: 'sbom', path: resolvedSbom },
    { key: 'provenance', path: resolvedProvenance }
  ]) {
    if (!fs.existsSync(required.path)) {
      addFailure(failures, 'missing-required-file', `Required file missing: ${required.path}`, required.path);
    }
  }

  const index = buildFileIndex(files, repoRoot, resolvedRoot);

  let checksumEntries = [];
  let invalidChecksumLines = [];
  if (fs.existsSync(resolvedChecksums)) {
    const parsedChecksums = parseChecksumManifest(fs.readFileSync(resolvedChecksums, 'utf8'));
    checksumEntries = parsedChecksums.entries;
    invalidChecksumLines = parsedChecksums.invalidLines;
    for (const invalidLine of invalidChecksumLines) {
      addFailure(failures, 'checksum-invalid-line', `Invalid checksum line: ${invalidLine}`);
    }
    if (checksumEntries.length === 0) {
      addFailure(failures, 'checksum-empty', 'No checksum entries parsed from SHA256SUMS.txt.');
    }
  }

  const checksumByFile = new Map();
  for (const entry of checksumEntries) {
    const target = resolveChecksumTarget(entry, index);
    if (!target) {
      addFailure(
        failures,
        'checksum-entry-missing-file',
        `Checksum entry references missing/ambiguous file: ${entry.rawPath}`,
        entry.rawPath
      );
      continue;
    }
    const actual = hashFileSha256(target);
    const match = actual === entry.sha256;
    checksumByFile.set(target, {
      expected: entry.sha256,
      actual,
      match,
      source: entry.rawPath
    });
    if (!match) {
      addFailure(
        failures,
        'checksum-mismatch',
        `Checksum mismatch for ${path.basename(target)} expected=${entry.sha256} actual=${actual}.`,
        target
      );
    }
  }

  for (const archivePath of archiveFiles) {
    if (!checksumByFile.has(archivePath)) {
      addFailure(
        failures,
        'checksum-missing-artifact',
        `Distribution artifact missing from checksum manifest: ${path.basename(archivePath)}.`,
        archivePath
      );
    }
  }

  const artifactRecords = archiveFiles
    .map((archivePath) => {
      const checksum = checksumByFile.get(archivePath) || null;
      return {
        name: path.basename(archivePath),
        path: archivePath,
        sizeBytes: fs.statSync(archivePath).size,
        sha256: hashFileSha256(archivePath),
        checksum: {
          present: Boolean(checksum),
          match: checksum ? Boolean(checksum.match) : false,
          expected: checksum?.expected ?? null,
          actual: checksum?.actual ?? null
        }
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));

  let sbomStatus = { path: resolvedSbom, exists: fs.existsSync(resolvedSbom), valid: false, spdxVersion: null, fileCount: 0 };
  if (fs.existsSync(resolvedSbom)) {
    try {
      const payload = parseJsonText(fs.readFileSync(resolvedSbom, 'utf8'));
      const validation = validateSbomPayload(payload, archiveFiles, failures);
      sbomStatus = {
        path: resolvedSbom,
        exists: true,
        valid: validation.valid,
        spdxVersion: validation.spdxVersion,
        fileCount: validation.fileCount
      };
    } catch (error) {
      addFailure(failures, 'sbom-parse-failed', `Failed to parse SBOM: ${error.message}`);
    }
  }

  let provenanceStatus = {
    path: resolvedProvenance,
    exists: fs.existsSync(resolvedProvenance),
    valid: false,
    schema: null,
    releaseAssetCount: 0
  };
  if (fs.existsSync(resolvedProvenance)) {
    try {
      const payload = parseJsonText(fs.readFileSync(resolvedProvenance, 'utf8'));
      const validation = validateProvenancePayload(
        payload,
        {
          expectedRepository,
          expectedRunId,
          expectedHeadSha
        },
        archiveFiles,
        failures
      );
      provenanceStatus = {
        path: resolvedProvenance,
        exists: true,
        valid: validation.valid,
        schema: validation.schema,
        releaseAssetCount: validation.releaseAssetCount
      };
    } catch (error) {
      addFailure(failures, 'provenance-parse-failed', `Failed to parse provenance payload: ${error.message}`);
    }
  }

  return {
    failures,
    artifactRecords,
    archiveFiles,
    checksums: {
      path: resolvedChecksums,
      exists: fs.existsSync(resolvedChecksums),
      entryCount: checksumEntries.length,
      invalidLineCount: invalidChecksumLines.length
    },
    sbom: sbomStatus,
    provenance: provenanceStatus
  };
}

function defaultCommandRunner(command, args) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  return {
    status: Number.isInteger(result.status) ? result.status : 1,
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
}

function parseJsonFromCommandPayload(raw, description, failures) {
  try {
    return parseJsonText(String(raw || '').trim() || '{}');
  } catch (error) {
    addFailure(failures, 'tag-signature-parse-failed', `Failed to parse ${description}: ${error.message}`);
    return null;
  }
}

function formatCommandError(result) {
  return String(result?.stderr || result?.stdout || `exit code ${result?.status ?? 1}`).trim();
}

export function createDefaultTagSignatureStatus(tagRef = null, reason = null) {
  return {
    refName: tagRef || null,
    checked: false,
    exists: false,
    annotated: false,
    objectType: null,
    objectSha: null,
    verified: false,
    reason: reason || null,
    verifiedAt: null
  };
}

export async function verifyReleaseTagSignature({ repository, tagRef, runner = defaultCommandRunner }) {
  const failures = [];
  const normalizedTagRef = String(tagRef || '').trim();
  const status = createDefaultTagSignatureStatus(normalizedTagRef || null);

  if (!normalizedTagRef) {
    addFailure(failures, 'tag-ref-missing', 'Release tag ref is unavailable (GITHUB_REF_NAME/--tag-ref missing).');
    return { failures, status };
  }

  const cliCheck = await Promise.resolve(runner('gh', ['--version']));
  if (cliCheck.status !== 0) {
    addFailure(failures, 'tag-signature-cli-unavailable', 'Unable to execute gh api for tag signature verification.');
    return { failures, status };
  }

  const refPath = `repos/${repository}/git/ref/tags/${encodeURIComponent(normalizedTagRef)}`;
  const refResult = await Promise.resolve(runner('gh', ['api', refPath]));
  if (refResult.status !== 0) {
    addFailure(
      failures,
      'tag-ref-lookup-failed',
      `Failed to query release tag ref '${normalizedTagRef}': ${formatCommandError(refResult)}.`,
      normalizedTagRef
    );
    return { failures, status };
  }

  const refPayload = parseJsonFromCommandPayload(refResult.stdout, 'tag ref payload', failures);
  if (!refPayload) {
    return { failures, status };
  }

  status.checked = true;
  status.exists = true;
  status.objectType = typeof refPayload?.object?.type === 'string' ? refPayload.object.type : null;
  status.objectSha = typeof refPayload?.object?.sha === 'string' ? refPayload.object.sha : null;
  if (status.objectType !== 'tag' || !status.objectSha) {
    status.reason = 'not-annotated';
    addFailure(
      failures,
      'tag-not-annotated',
      `Release tag '${normalizedTagRef}' is not an annotated tag (object.type=${status.objectType || '<empty>'}).`,
      normalizedTagRef
    );
    return { failures, status };
  }
  status.annotated = true;

  const tagPath = `repos/${repository}/git/tags/${status.objectSha}`;
  const tagResult = await Promise.resolve(runner('gh', ['api', tagPath]));
  if (tagResult.status !== 0) {
    addFailure(
      failures,
      'tag-object-lookup-failed',
      `Failed to query tag object for '${normalizedTagRef}': ${formatCommandError(tagResult)}.`,
      normalizedTagRef
    );
    return { failures, status };
  }

  const tagPayload = parseJsonFromCommandPayload(tagResult.stdout, 'tag object payload', failures);
  if (!tagPayload) {
    return { failures, status };
  }

  const verification = tagPayload?.verification || {};
  status.verified = verification?.verified === true;
  status.reason = typeof verification?.reason === 'string' ? verification.reason : null;
  status.verifiedAt = typeof verification?.verified_at === 'string' ? verification.verified_at : null;

  if (!status.verified) {
    addFailure(
      failures,
      'tag-signature-unverified',
      `Release tag '${normalizedTagRef}' signature not verified (reason=${status.reason || 'unknown'}).`,
      normalizedTagRef
    );
  }

  return { failures, status };
}

export function shouldRetryAttestationVerify(message) {
  const text = String(message || '').toLowerCase();
  return (
    text.includes('no attestations found') ||
    text.includes('not found') ||
    text.includes('429') ||
    text.includes('rate limit') ||
    text.includes('temporarily unavailable')
  );
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function verifyAttestationForArtifact({
  artifactPath,
  repository,
  signerWorkflow,
  maxAttempts,
  retrySeconds,
  runner = defaultCommandRunner,
  sleepFn = sleep
}) {
  let attempts = 0;
  let lastError = '';
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    attempts = attempt;
    const args = [
      'attestation',
      'verify',
      artifactPath,
      '--repo',
      repository,
      '--signer-workflow',
      signerWorkflow,
      '--format',
      'json'
    ];
    if (process.env.GITHUB_REF) {
      args.push('--source-ref', process.env.GITHUB_REF);
    }

    const result = await Promise.resolve(runner('gh', args));
    const stderr = String(result.stderr || '').trim();
    const stdout = String(result.stdout || '').trim();
    if (result.status === 0) {
      try {
        const parsed = stdout ? JSON.parse(stdout) : [];
        if (!Array.isArray(parsed) || parsed.length === 0) {
          lastError = 'attestation verify returned empty result array';
          if (attempt < maxAttempts) {
            await sleepFn(retrySeconds * 1000);
            continue;
          }
          return {
            artifactPath,
            verified: false,
            attempts,
            attestationCount: 0,
            error: lastError
          };
        }
        return {
          artifactPath,
          verified: true,
          attempts,
          attestationCount: parsed.length,
          error: null
        };
      } catch (error) {
        lastError = `attestation output parse failed: ${error.message}`;
      }
    } else {
      lastError = stderr || stdout || `gh exited with code ${result.status}`;
    }

    if (attempt < maxAttempts && shouldRetryAttestationVerify(lastError)) {
      await sleepFn(retrySeconds * 1000);
      continue;
    }
    break;
  }

  return {
    artifactPath,
    verified: false,
    attempts,
    attestationCount: 0,
    error: lastError
  };
}

export async function verifyAttestations({
  artifactPaths,
  repository,
  signerWorkflow,
  maxAttempts,
  retrySeconds,
  runner = defaultCommandRunner,
  sleepFn = sleep
}) {
  const failures = [];
  const check = await Promise.resolve(runner('gh', ['--version']));
  if (check.status !== 0) {
    addFailure(failures, 'attestation-cli-unavailable', 'Unable to execute gh attestation verify.');
    return {
      failures,
      results: artifactPaths.map((artifactPath) => ({
        artifactPath,
        verified: false,
        attempts: 0,
        attestationCount: 0,
        error: 'gh-not-available'
      }))
    };
  }

  const results = [];
  for (const artifactPath of artifactPaths) {
    const record = await verifyAttestationForArtifact({
      artifactPath,
      repository,
      signerWorkflow,
      maxAttempts,
      retrySeconds,
      runner,
      sleepFn
    });
    results.push(record);
    if (!record.verified) {
      const code =
        record.error && record.error.toLowerCase().includes('parse failed')
          ? 'attestation-output-parse-failed'
          : record.error && record.error.toLowerCase().includes('empty result')
            ? 'attestation-empty-result'
            : 'attestation-unverified';
      addFailure(
        failures,
        code,
        `Attestation verify failed for ${path.basename(record.artifactPath)} after ${record.attempts} attempt(s): ${record.error}`,
        record.artifactPath
      );
    }
  }
  return { failures, results };
}

function appendSummary(report, reportPath) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (!summaryPath) return;
  const lines = [
    '### Supply-Chain Trust Gate',
    `- Status: \`${report.summary.status}\``,
    `- Failures: \`${report.summary.failureCount}\``,
    `- Artifacts evaluated: \`${report.summary.artifactCount}\``,
    `- Tag signature: \`${report.tagSignature.verified ? 'verified' : report.tagSignature.reason || 'unverified'}\` (\`${report.tagSignature.refName || 'n/a'}\`)`,
    `- Attestations verified: \`${report.summary.attestationVerifiedCount}/${report.summary.attestationTotal}\``,
    `- Report: \`${reportPath}\``
  ];
  if (report.failures.length > 0) {
    lines.push('', '| Code | Target | Message |', '| --- | --- | --- |');
    for (const failure of report.failures) {
      lines.push(
        `| <code>${escapeSummaryTableCell(failure.code)}</code> | <code>${escapeSummaryTableCell(failure.target || 'n/a')}</code> | ${escapeSummaryTableCell(failure.message)} |`
      );
    }
  }
  fs.appendFileSync(summaryPath, `${lines.join('\n')}\n`, 'utf8');
}

export function escapeSummaryTableCell(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/`/g, '&#96;')
    .replace(/\|/g, '&#124;')
    .replace(/\r\n|\r|\n/g, '<br>');
}

function writeReport(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

export async function run(options, dependencies = {}) {
  const repository = resolveRepositorySlug(options.repo);
  const signerWorkflow = options.signerWorkflow || `${repository}/.github/workflows/release.yml`;
  const repoRoot = process.cwd();
  const tagRef = options.tagRef || process.env.GITHUB_REF_NAME || null;
  const effectiveVerifyTagSignature = options.verifyTagSignature && !isToolsReleaseTag(tagRef);
  const skippedTagSignatureReason = options.verifyTagSignature && isToolsReleaseTag(tagRef) ? 'skipped-tools-tag' : 'skipped';

  const tagSignature = effectiveVerifyTagSignature
    ? await verifyReleaseTagSignature({
        repository,
        tagRef,
        runner: dependencies.runner || defaultCommandRunner
      })
    : {
        failures: [],
        status: createDefaultTagSignatureStatus(tagRef, skippedTagSignatureReason)
      };

  const local = evaluateLocalIntegrity({
    repoRoot,
    artifactsRoot: options.artifactsRoot,
    checksumsPath: options.checksumsPath,
    sbomPath: options.sbomPath,
    provenancePath: options.provenancePath,
    expectedRepository: repository,
    expectedRunId: process.env.GITHUB_RUN_ID || null,
    expectedHeadSha: process.env.GITHUB_SHA || null
  });

  const attestationArtifactPaths = [
    ...local.archiveFiles,
    local.checksums.path,
    local.sbom.path,
    local.provenance.path
  ].filter((value, index, self) => self.indexOf(value) === index && fs.existsSync(value));

  let attestation = {
    failures: [],
    results: []
  };
  if (options.verifyAttestations) {
    attestation = await verifyAttestations({
      artifactPaths: attestationArtifactPaths,
      repository,
      signerWorkflow,
      maxAttempts: Math.max(1, options.attestationAttempts),
      retrySeconds: Math.max(0, options.attestationRetrySeconds),
      runner: dependencies.runner || defaultCommandRunner,
      sleepFn: dependencies.sleepFn || sleep
    });
  }

  const failures = [...tagSignature.failures, ...local.failures, ...attestation.failures];
  const summary = {
    status: failures.length === 0 ? 'pass' : 'fail',
    failureCount: failures.length,
    failureCodes: [...new Set(failures.map((failure) => failure.code))].sort(),
    artifactCount: local.artifactRecords.length,
    attestationVerifiedCount: attestation.results.filter((entry) => entry.verified).length,
    attestationTotal: attestation.results.length
  };

  return {
    schema: 'priority/supply-chain-trust-gate@v1',
    generatedAt: new Date().toISOString(),
    repository,
    channel: /-rc\./i.test(tagRef || '') ? 'rc' : 'stable',
    workflow: {
      name: process.env.GITHUB_WORKFLOW || null,
      runId: process.env.GITHUB_RUN_ID || null,
      runAttempt: process.env.GITHUB_RUN_ATTEMPT || null,
      event: process.env.GITHUB_EVENT_NAME || null,
      ref: process.env.GITHUB_REF || null,
      sha: process.env.GITHUB_SHA || null
    },
    policy: {
      verifyTagSignature: effectiveVerifyTagSignature,
      tagRef,
      signerWorkflow,
      verifyAttestations: options.verifyAttestations,
      attestationAttempts: options.attestationAttempts,
      attestationRetrySeconds: options.attestationRetrySeconds
    },
    tagSignature: tagSignature.status,
    artifacts: {
      root: path.resolve(options.artifactsRoot),
      distribution: local.artifactRecords,
      checksums: local.checksums,
      sbom: local.sbom,
      provenance: local.provenance
    },
    attestations: {
      enabled: options.verifyAttestations,
      results: attestation.results
    },
    failures,
    summary
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  const report = await run(options);
  const outputPath = writeReport(options.reportPath, report);
  appendSummary(report, options.reportPath);
  console.log(`[supply-chain-trust-gate] wrote ${outputPath} (status=${report.summary.status}, failures=${report.summary.failureCount})`);
  return report.summary.status === 'pass' ? 0 : 1;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  main(process.argv)
    .then((code) => {
      if (code !== 0) process.exitCode = code;
    })
    .catch((error) => {
      const fallback = {
        schema: 'priority/supply-chain-trust-gate@v1',
        generatedAt: new Date().toISOString(),
        summary: {
          status: 'fail',
          failureCount: 1,
          failureCodes: ['execution-error'],
          artifactCount: 0,
          attestationVerifiedCount: 0,
          attestationTotal: 0
        },
        tagSignature: createDefaultTagSignatureStatus(process.env.GITHUB_REF_NAME || null, 'execution-error'),
        failures: [
          {
            code: 'execution-error',
            message: error?.stack || error?.message || String(error),
            hint: 'Inspect script logs and rerun trust gate.'
          }
        ]
      };
      try {
        const options = parseArgs(process.argv);
        writeReport(options.reportPath, fallback);
      } catch {
        // no-op
      }
      console.error(error?.stack ?? error?.message ?? String(error));
      process.exitCode = 1;
    });
}
