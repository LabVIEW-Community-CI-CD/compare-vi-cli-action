import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH,
  DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH,
  parseArgs,
  REQUIRED_SIGNING_SECRET,
  OPTIONAL_SIGNING_SECRET,
  runReleaseSigningReadiness
} from '../release-signing-readiness.mjs';

function writeText(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, 'utf8');
}

function writeJson(filePath, payload) {
  writeText(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

function createPublishedBundleObserver(overrides = {}) {
  return {
    schema: 'priority/release-published-bundle-observer-report@v1',
    generatedAt: '2026-03-23T17:19:30Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    inputs: {
      requestedTag: null,
      resultsDir: 'tests/results/_agent/release/published-bundle-observer'
    },
    selection: {
      status: 'selected',
      releaseTag: 'v0.6.4-rc.1-tools.1',
      publishedAt: '2026-03-23T17:19:00Z',
      releaseName: 'v0.6.4-rc.1-tools.1',
      releaseId: 123,
      prerelease: true,
      draft: false,
      assetName: 'CompareVI.Tools-v0.6.4-rc.1-tools.1.zip',
      assetId: 456
    },
    bundle: {
      status: 'extracted',
      archivePath: 'tests/results/_agent/release/published-bundle-observer/download/CompareVI.Tools-v0.6.4-rc.1-tools.1.zip',
      extractionRoot: 'tests/results/_agent/release/published-bundle-observer/bundle/CompareVI.Tools-v0.6.4-rc.1-tools.1',
      downloadDirectory: 'tests/results/_agent/release/published-bundle-observer/download'
    },
    bundleContract: {
      status: 'producer-native-ready',
      metadataPath:
        'tests/results/_agent/release/published-bundle-observer/bundle/CompareVI.Tools-v0.6.4-rc.1-tools.1/comparevi-tools-release.json',
      schema: 'comparevi-tools-release-manifest@v1',
      authoritativeConsumerPin: 'v0.6.4-rc.1-tools.1',
      authoritativeConsumerPinKind: 'release-tag',
      capabilityId: 'vi-history',
      distributionRole: 'upstream-producer',
      distributionModel: 'release-bundle',
      bundleImportPath: '.github/workflows/vi-history.yml',
      bundleImportPathExists: true,
      releaseAssetPattern: 'CompareVI.Tools-v*.zip',
      contractPathResolutions: [],
      metadataPresent: true,
      metadataSchemaMatches: true,
      viHistoryCapabilityPresent: true,
      viHistoryCapabilityProducerNative: true,
      bundleContractPinResolved: true,
      bundleContractPathsResolved: true
    },
    summary: {
      status: 'producer-native-ready',
      releaseTag: 'v0.6.4-rc.1-tools.1',
      assetName: 'CompareVI.Tools-v0.6.4-rc.1-tools.1.zip',
      publishedAt: '2026-03-23T17:19:00Z',
      authoritativeConsumerPin: 'v0.6.4-rc.1-tools.1'
    },
    ...overrides
  };
}

function seedWorkflowContract(repoRoot) {
  writeText(
    path.join(repoRoot, '.github', 'workflows', 'release-conductor.yml'),
    [
      'name: release-conductor',
      'jobs:',
      '  release:',
      '    steps:',
      '      - name: Configure release tag signing material',
      '        run: |',
      '          echo RELEASE_TAG_SIGNING_PRIVATE_KEY',
      '          echo RELEASE_TAG_SIGNING_IDENTITY_NAME',
      '          echo RELEASE_TAG_SIGNING_IDENTITY_EMAIL',
      "          signing_login=\"$(gh api user --jq '.login')\"",
      '          git config gpg.format ssh',
      '          git config user.signingkey "$public_key_path"',
      '          git config user.name "$signing_name"',
      '          git config user.email "$signing_email"'
    ].join('\n')
  );
}

test('parseArgs keeps defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'release-signing-readiness.mjs',
    '--repo-root',
    'C:/repo',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--output',
    'custom/release-signing-readiness.json'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.outputPath, 'custom/release-signing-readiness.json');
  assert.equal(
    DEFAULT_OUTPUT_PATH,
    path.join('tests', 'results', '_agent', 'release', 'release-signing-readiness.json')
  );
  assert.equal(
    DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH,
    path.join('tests', 'results', '_agent', 'release', 'release-conductor-report.json')
  );
  assert.equal(
    DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH,
    path.join('tests', 'results', '_agent', 'release', 'release-published-bundle-observer.json')
  );
});

test('runReleaseSigningReadiness reports explicit external blocker when workflow secret is missing', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'release-signing-readiness-missing-'));
  seedWorkflowContract(repoRoot);
  writeJson(path.join(repoRoot, DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH), createPublishedBundleObserver({
    bundleContract: {
      ...createPublishedBundleObserver().bundleContract,
      status: 'producer-native-incomplete',
      authoritativeConsumerPin: null,
      authoritativeConsumerPinKind: null,
      capabilityId: null,
      distributionRole: null,
      distributionModel: null,
      bundleImportPath: null,
      bundleImportPathExists: false,
      releaseAssetPattern: null,
      viHistoryCapabilityPresent: false,
      viHistoryCapabilityProducerNative: false,
      bundleContractPinResolved: false
    },
    summary: {
      ...createPublishedBundleObserver().summary,
      status: 'producer-native-incomplete',
      authoritativeConsumerPin: null
    }
  }));

  const result = await runReleaseSigningReadiness(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T17:20:00Z'),
      runGhJsonFn: (args) => {
        const endpoint = args[1] ?? '';
        if (endpoint.includes('/actions/secrets')) {
          return { secrets: [{ name: 'GH_TOKEN' }] };
        }
        if (endpoint.includes('/actions/variables')) {
          return { variables: [] };
        }
        if (endpoint.startsWith('user/ssh_signing_keys')) {
          throw new Error('This API operation needs the "admin:ssh_signing_key" scope.');
        }
        throw new Error(`Unexpected endpoint: ${endpoint}`);
      }
    }
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.summary.status, 'warn');
  assert.equal(result.report.summary.codePathState, 'ready');
  assert.equal(result.report.summary.signingCapabilityState, 'missing');
  assert.equal(result.report.summary.signingAuthorityState, 'scope-missing');
  assert.equal(result.report.summary.releaseConductorApplyState, 'disabled');
  assert.equal(result.report.summary.publicationState, 'unobserved');
  assert.equal(result.report.summary.publishedBundleState, 'producer-native-incomplete');
  assert.equal(result.report.summary.publishedBundleReleaseTag, 'v0.6.4-rc.1-tools.1');
  assert.equal(result.report.summary.publishedBundleAuthoritativeConsumerPin, null);
  assert.equal(result.report.summary.externalBlocker, 'workflow-signing-secret-missing');
  assert.equal(result.report.secretInventory.requiredSecretPresent, false);
  assert.equal(result.report.releaseConductorApply.status, 'disabled');
  assert.equal(result.report.signingAuthority.status, 'scope-missing');
  assert.equal(result.report.publishedBundleObserver.status, 'producer-native-incomplete');
  assert.deepEqual(result.report.blockers.map((entry) => entry.code), [
    'workflow-signing-secret-missing',
    'release-conductor-apply-disabled',
    'workflow-signing-admin-scope-missing',
    'published-bundle-producer-native-incomplete'
  ]);
});

test('runReleaseSigningReadiness reports publication success when signing capability is configured', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'release-signing-readiness-pass-'));
  seedWorkflowContract(repoRoot);
  writeJson(path.join(repoRoot, DEFAULT_RELEASE_CONDUCTOR_REPORT_PATH), {
    release: {
      tagCreated: true,
      tagPushed: true,
      targetTag: 'v0.6.4-rc.1'
    }
  });
  writeJson(path.join(repoRoot, DEFAULT_RELEASE_PUBLISHED_BUNDLE_OBSERVER_PATH), createPublishedBundleObserver());

  const result = await runReleaseSigningReadiness(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T17:21:00Z'),
      runGhJsonFn: (args) => {
        const endpoint = args[1] ?? '';
        if (endpoint.includes('/actions/secrets')) {
          return { secrets: [{ name: REQUIRED_SIGNING_SECRET }, { name: OPTIONAL_SIGNING_SECRET }] };
        }
        if (endpoint.includes('/actions/variables')) {
          return { variables: [{ name: 'RELEASE_CONDUCTOR_ENABLED', value: '1' }] };
        }
        if (endpoint.startsWith('user/ssh_signing_keys')) {
          return [{ id: 1, title: 'compare-release-signing' }];
        }
        throw new Error(`Unexpected endpoint: ${endpoint}`);
      }
    }
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.summary.codePathState, 'ready');
  assert.equal(result.report.summary.signingCapabilityState, 'configured');
  assert.equal(result.report.summary.signingAuthorityState, 'ready');
  assert.equal(result.report.summary.releaseConductorApplyState, 'enabled');
  assert.equal(result.report.summary.publicationState, 'authoritative-publication-successful');
  assert.equal(result.report.summary.publishedBundleState, 'producer-native-ready');
  assert.equal(result.report.summary.publishedBundleReleaseTag, 'v0.6.4-rc.1-tools.1');
  assert.equal(result.report.summary.publishedBundleAuthoritativeConsumerPin, 'v0.6.4-rc.1-tools.1');
  assert.equal(result.report.summary.externalBlocker, null);
  assert.equal(result.report.secretInventory.requiredSecretPresent, true);
  assert.equal(result.report.releaseConductorApply.enabled, true);
  assert.equal(result.report.signingAuthority.listedKeyCount, 1);
  assert.equal(result.report.publication.targetTag, 'v0.6.4-rc.1');
  assert.equal(result.report.publishedBundleObserver.status, 'producer-native-ready');
  assert.deepEqual(result.report.blockers, []);
});
