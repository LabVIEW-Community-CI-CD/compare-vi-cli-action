import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_REPORT_PATH,
  escapeSummaryTableCell,
  evaluateLocalIntegrity,
  parseArgs,
  parseChecksumManifest,
  run,
  shouldRetryAttestationVerify,
  verifyReleaseTagSignature,
  verifyAttestationForArtifact,
  verifyAttestations
} from '../supply-chain-trust-gate.mjs';

function writeFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content);
}

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

function createValidReleasePayload(root, { useBom = false } = {}) {
  const artifactsRoot = path.join(root, 'artifacts', 'cli');
  fs.mkdirSync(artifactsRoot, { recursive: true });

  const linuxArchive = path.join(artifactsRoot, 'comparevi-cli-v1-linux-x64-selfcontained.tar.gz');
  const winArchive = path.join(artifactsRoot, 'comparevi-cli-v1-win-x64-selfcontained.zip');
  writeFile(linuxArchive, 'linux-archive-content');
  writeFile(winArchive, 'windows-archive-content');

  const linuxHash = sha256('linux-archive-content');
  const winHash = sha256('windows-archive-content');
  const checksumText =
    `${linuxHash}  ./comparevi-cli-v1-linux-x64-selfcontained.tar.gz\n` +
    `${winHash}  ./comparevi-cli-v1-win-x64-selfcontained.zip\n`;
  writeFile(path.join(artifactsRoot, 'SHA256SUMS.txt'), checksumText);

  const sbomPayload = {
    spdxVersion: 'SPDX-2.3',
    files: [
      { fileName: './comparevi-cli-v1-linux-x64-selfcontained.tar.gz' },
      { fileName: './comparevi-cli-v1-win-x64-selfcontained.zip' }
    ]
  };
  writeFile(
    path.join(artifactsRoot, 'sbom.spdx.json'),
    `${useBom ? '\uFEFF' : ''}${JSON.stringify(sbomPayload)}`
  );

  const checksumHash = sha256(checksumText);
  const sbomHash = sha256(`${useBom ? '\uFEFF' : ''}${JSON.stringify(sbomPayload)}`);
  const provenancePayload = {
    schema: 'run-provenance/v1',
    repository: 'owner/repo',
    runId: '123',
    headSha: 'abc123',
    releaseAssets: [
      { name: path.basename(linuxArchive), sha256: linuxHash },
      { name: path.basename(winArchive), sha256: winHash },
      { name: 'SHA256SUMS.txt', sha256: checksumHash },
      { name: 'sbom.spdx.json', sha256: sbomHash }
    ]
  };
  writeFile(
    path.join(artifactsRoot, 'provenance.json'),
    `${useBom ? '\uFEFF' : ''}${JSON.stringify(provenancePayload)}`
  );

  return { artifactsRoot };
}

test('parseArgs applies defaults and explicit overrides', () => {
  const defaults = parseArgs(['node', 'supply-chain-trust-gate.mjs']);
  assert.equal(defaults.artifactsRoot, path.join('artifacts', 'cli'));
  assert.equal(defaults.reportPath, DEFAULT_REPORT_PATH);
  assert.equal(defaults.tagRef, process.env.GITHUB_REF_NAME || null);
  assert.equal(defaults.verifyTagSignature, true);
  assert.equal(defaults.verifyAttestations, true);
  assert.equal(defaults.attestationAttempts, 6);

  const parsed = parseArgs([
    'node',
    'supply-chain-trust-gate.mjs',
    '--repo',
    'owner/repo',
    '--artifacts-root',
    'out/release',
    '--checksums',
    'out/release/SHA256SUMS.txt',
    '--sbom',
    'out/release/sbom.json',
    '--provenance',
    'out/release/prov.json',
    '--tag-ref',
    'v1.2.3',
    '--report',
    'out/report.json',
    '--signer-workflow',
    'owner/repo/.github/workflows/release.yml',
    '--attestation-attempts',
    '2',
    '--attestation-retry-seconds',
    '1',
    '--skip-tag-signature',
    '--skip-attestations'
  ]);
  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.artifactsRoot, 'out/release');
  assert.equal(parsed.tagRef, 'v1.2.3');
  assert.equal(parsed.reportPath, 'out/report.json');
  assert.equal(parsed.signerWorkflow, 'owner/repo/.github/workflows/release.yml');
  assert.equal(parsed.attestationAttempts, 2);
  assert.equal(parsed.attestationRetrySeconds, 1);
  assert.equal(parsed.verifyTagSignature, false);
  assert.equal(parsed.verifyAttestations, false);
});

test('parseChecksumManifest parses valid entries and invalid lines', () => {
  const a = 'a'.repeat(64);
  const b = 'b'.repeat(64);
  const parsed = parseChecksumManifest(
    `${a}  ./artifacts/cli/file-a.tar.gz\n` +
      `invalid-line\n` +
      `${b}  .\\artifacts\\cli\\file-b.zip\n`
  );
  assert.equal(parsed.entries.length, 2);
  assert.equal(parsed.invalidLines.length, 1);
  assert.equal(parsed.entries[0].name, 'file-a.tar.gz');
  assert.equal(parsed.entries[1].name, 'file-b.zip');
});

test('evaluateLocalIntegrity passes for valid release payload', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-gate-pass-'));
  createValidReleasePayload(root);

  const result = evaluateLocalIntegrity({
    repoRoot: root,
    artifactsRoot: path.join('artifacts', 'cli'),
    checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
    sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
    provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
    expectedRepository: 'owner/repo',
    expectedRunId: '123',
    expectedHeadSha: 'abc123'
  });

  assert.equal(result.failures.length, 0);
  assert.equal(result.artifactRecords.length, 2);
  assert.equal(result.sbom.valid, true);
  assert.equal(result.provenance.valid, true);
});

test('evaluateLocalIntegrity accepts BOM-prefixed SBOM and provenance JSON', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-gate-bom-'));
  createValidReleasePayload(root, { useBom: true });

  const result = evaluateLocalIntegrity({
    repoRoot: root,
    artifactsRoot: path.join('artifacts', 'cli'),
    checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
    sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
    provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
    expectedRepository: 'owner/repo',
    expectedRunId: '123',
    expectedHeadSha: 'abc123'
  });

  assert.equal(result.failures.length, 0);
  assert.equal(result.sbom.valid, true);
  assert.equal(result.provenance.valid, true);
});

test('evaluateLocalIntegrity reports checksum mismatch failures', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-gate-fail-'));
  const artifactsRoot = path.join(root, 'artifacts', 'cli');
  fs.mkdirSync(artifactsRoot, { recursive: true });

  const archive = path.join(artifactsRoot, 'comparevi-cli-v1-linux-x64-selfcontained.tar.gz');
  writeFile(archive, 'archive-content');
  writeFile(path.join(artifactsRoot, 'SHA256SUMS.txt'), `${'0'.repeat(64)}  ./comparevi-cli-v1-linux-x64-selfcontained.tar.gz\n`);
  writeFile(
    path.join(artifactsRoot, 'sbom.spdx.json'),
    JSON.stringify({ spdxVersion: 'SPDX-2.3', files: [{ fileName: './comparevi-cli-v1-linux-x64-selfcontained.tar.gz' }] })
  );
  writeFile(
    path.join(artifactsRoot, 'provenance.json'),
    JSON.stringify({
      schema: 'run-provenance/v1',
      repository: 'owner/repo',
      runId: '123',
      headSha: 'abc123',
      releaseAssets: [{ name: 'comparevi-cli-v1-linux-x64-selfcontained.tar.gz', sha256: sha256('archive-content') }]
    })
  );

  const result = evaluateLocalIntegrity({
    repoRoot: root,
    artifactsRoot: path.join('artifacts', 'cli'),
    checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
    sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
    provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
    expectedRepository: 'owner/repo',
    expectedRunId: '123',
    expectedHeadSha: 'abc123'
  });

  assert.ok(result.failures.some((failure) => failure.code === 'checksum-mismatch'));
});

test('verifyAttestationForArtifact retries on transient error and then succeeds', async () => {
  const calls = [];
  const runner = (_command, _args) => {
    calls.push(1);
    if (calls.length === 1) {
      return {
        status: 1,
        stdout: '',
        stderr: 'no attestations found for subject'
      };
    }
    return {
      status: 0,
      stdout: '[{"verificationResult":{"statement":{"subject":[]}}}]',
      stderr: ''
    };
  };
  const result = await verifyAttestationForArtifact({
    artifactPath: '/tmp/file.zip',
    repository: 'owner/repo',
    signerWorkflow: 'owner/repo/.github/workflows/release.yml',
    maxAttempts: 3,
    retrySeconds: 0,
    runner,
    sleepFn: async () => {}
  });
  assert.equal(result.verified, true);
  assert.equal(result.attempts, 2);
  assert.equal(result.attestationCount, 1);
});

test('verifyAttestations reports gh unavailable and retry classifier catches transient messages', async () => {
  assert.equal(shouldRetryAttestationVerify('no attestations found'), true);
  assert.equal(shouldRetryAttestationVerify('HTTP 429 rate limit exceeded'), true);
  assert.equal(shouldRetryAttestationVerify('permission denied'), false);

  const result = await verifyAttestations({
    artifactPaths: ['/tmp/a.zip'],
    repository: 'owner/repo',
    signerWorkflow: 'owner/repo/.github/workflows/release.yml',
    maxAttempts: 1,
    retrySeconds: 0,
    runner: () => ({ status: 1, stdout: '', stderr: 'gh missing' }),
    sleepFn: async () => {}
  });

  assert.ok(result.failures.some((failure) => failure.code === 'attestation-cli-unavailable'));
  assert.equal(result.results.length, 1);
  assert.equal(result.results[0].verified, false);
});

test('escapeSummaryTableCell neutralizes markdown and html control characters', () => {
  const escaped = escapeSummaryTableCell('line `one` | <tag> & detail\r\nline two');
  assert.equal(escaped, 'line &#96;one&#96; &#124; &lt;tag&gt; &amp; detail<br>line two');
});

test('verifyReleaseTagSignature passes for verified annotated tag', async () => {
  const runner = (_command, args) => {
    if (args[0] === '--version') {
      return { status: 0, stdout: 'gh version 2.x', stderr: '' };
    }
    if (args[0] === 'api' && String(args[1]).includes('/git/ref/tags/')) {
      return {
        status: 0,
        stdout: JSON.stringify({
          object: {
            type: 'tag',
            sha: 'abc123'
          }
        }),
        stderr: ''
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('/git/tags/')) {
      return {
        status: 0,
        stdout: JSON.stringify({
          verification: {
            verified: true,
            reason: 'valid',
            verified_at: '2026-03-06T00:00:00Z'
          }
        }),
        stderr: ''
      };
    }
    return { status: 1, stdout: '', stderr: 'unexpected' };
  };

  const result = await verifyReleaseTagSignature({
    repository: 'owner/repo',
    tagRef: 'v1.2.3',
    runner
  });

  assert.equal(result.failures.length, 0);
  assert.equal(result.status.checked, true);
  assert.equal(result.status.annotated, true);
  assert.equal(result.status.verified, true);
  assert.equal(result.status.reason, 'valid');
});

test('verifyReleaseTagSignature fails for unsigned tag', async () => {
  const runner = (_command, args) => {
    if (args[0] === '--version') {
      return { status: 0, stdout: 'gh version 2.x', stderr: '' };
    }
    if (args[0] === 'api' && String(args[1]).includes('/git/ref/tags/')) {
      return {
        status: 0,
        stdout: JSON.stringify({
          object: {
            type: 'tag',
            sha: 'abc123'
          }
        }),
        stderr: ''
      };
    }
    if (args[0] === 'api' && String(args[1]).includes('/git/tags/')) {
      return {
        status: 0,
        stdout: JSON.stringify({
          verification: {
            verified: false,
            reason: 'unsigned'
          }
        }),
        stderr: ''
      };
    }
    return { status: 1, stdout: '', stderr: 'unexpected' };
  };

  const result = await verifyReleaseTagSignature({
    repository: 'owner/repo',
    tagRef: 'v1.2.3',
    runner
  });

  assert.ok(result.failures.some((failure) => failure.code === 'tag-signature-unverified'));
  assert.ok(
    result.failures.some(
      (failure) =>
        failure.code === 'tag-signature-unverified' &&
        String(failure.hint).includes('priority:release:signing:readiness') &&
        String(failure.hint).includes('repair_existing_tag = true') &&
        String(failure.hint).includes('immutable published GitHub Release')
    )
  );
  assert.equal(result.status.verified, false);
  assert.equal(result.status.reason, 'unsigned');
});

test('verifyReleaseTagSignature fails for lightweight tag', async () => {
  const runner = (_command, args) => {
    if (args[0] === '--version') {
      return { status: 0, stdout: 'gh version 2.x', stderr: '' };
    }
    if (args[0] === 'api' && String(args[1]).includes('/git/ref/tags/')) {
      return {
        status: 0,
        stdout: JSON.stringify({
          object: {
            type: 'commit',
            sha: 'deadbeef'
          }
        }),
        stderr: ''
      };
    }
    return { status: 1, stdout: '', stderr: 'unexpected' };
  };

  const result = await verifyReleaseTagSignature({
    repository: 'owner/repo',
    tagRef: 'v1.2.3',
    runner
  });

  assert.ok(result.failures.some((failure) => failure.code === 'tag-not-annotated'));
  assert.ok(
    result.failures.some(
      (failure) =>
        failure.code === 'tag-not-annotated' &&
        String(failure.hint).includes('priority:release:signing:readiness') &&
        String(failure.hint).includes('repair_existing_tag = true') &&
        String(failure.hint).includes('immutable published GitHub Release')
    )
  );
  assert.equal(result.status.annotated, false);
  assert.equal(result.status.reason, 'not-annotated');
});

test('run skips tag signature verification for tools helper tags', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-gate-tools-tag-'));
  createValidReleasePayload(root);

  const originalCwd = process.cwd();
  process.chdir(root);
  try {
    const report = await run(
      {
        repo: 'owner/repo',
        artifactsRoot: path.join('artifacts', 'cli'),
        checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
        sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
        provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
        tagRef: 'v1.2.3-tools.6',
        reportPath: path.join(root, 'report.json'),
        signerWorkflow: 'owner/repo/.github/workflows/release.yml',
        attestationAttempts: 1,
        attestationRetrySeconds: 0,
        verifyTagSignature: true,
        verifyAttestations: false
      },
      {
        runner: () => {
          throw new Error('tag signature runner should not be called for tools helper tags');
        }
      }
    );

    assert.equal(report.summary.status, 'pass');
    assert.equal(report.policy.verifyTagSignature, false);
    assert.equal(report.tagSignature.reason, 'skipped-tools-tag');
    assert.equal(report.tagSignature.checked, false);
  } finally {
    process.chdir(originalCwd);
  }
});

test('run derives channel from resolved tagRef when environment is unset', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trust-gate-channel-'));
  createValidReleasePayload(root);

  const originalCwd = process.cwd();
  const originalRefName = process.env.GITHUB_REF_NAME;
  delete process.env.GITHUB_REF_NAME;
  process.chdir(root);
  try {
    const report = await run(
      {
        repo: 'owner/repo',
        artifactsRoot: path.join('artifacts', 'cli'),
        checksumsPath: path.join('artifacts', 'cli', 'SHA256SUMS.txt'),
        sbomPath: path.join('artifacts', 'cli', 'sbom.spdx.json'),
        provenancePath: path.join('artifacts', 'cli', 'provenance.json'),
        tagRef: 'v1.2.3-rc.1',
        reportPath: path.join(root, 'report.json'),
        signerWorkflow: 'owner/repo/.github/workflows/release.yml',
        attestationAttempts: 1,
        attestationRetrySeconds: 0,
        verifyTagSignature: false,
        verifyAttestations: false
      },
      {
        runner: () => {
          throw new Error('runner should not be called when trust verifiers are disabled');
        }
      }
    );

    assert.equal(report.channel, 'rc');
    assert.equal(report.policy.tagRef, 'v1.2.3-rc.1');
  } finally {
    process.chdir(originalCwd);
    if (originalRefName === undefined) {
      delete process.env.GITHUB_REF_NAME;
    } else {
      process.env.GITHUB_REF_NAME = originalRefName;
    }
  }
});
