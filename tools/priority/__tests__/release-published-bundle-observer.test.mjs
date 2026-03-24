import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  DEFAULT_RESULTS_DIR,
  parseArgs,
  runReleasePublishedBundleObserver
} from '../release-published-bundle-observer.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs keeps defaults and accepts overrides', () => {
  const parsed = parseArgs([
    'node',
    'release-published-bundle-observer.mjs',
    '--repo-root',
    'C:/repo',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--tag',
    'v0.6.4-rc.1',
    '--output',
    'custom/published-bundle.json',
    '--results-dir',
    'custom/results'
  ]);

  assert.equal(parsed.repoRoot, 'C:/repo');
  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.tag, 'v0.6.4-rc.1');
  assert.equal(parsed.outputPath, 'custom/published-bundle.json');
  assert.equal(parsed.resultsDir, 'custom/results');
  assert.equal(DEFAULT_OUTPUT_PATH, path.join('tests', 'results', '_agent', 'release', 'release-published-bundle-observer.json'));
  assert.equal(DEFAULT_RESULTS_DIR, path.join('tests', 'results', '_agent', 'release', 'published-bundle-observer'));
});

test('runReleasePublishedBundleObserver reports release-unobserved when no published releases exist', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'published-bundle-observer-empty-'));

  const result = await runReleasePublishedBundleObserver(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T19:15:00Z'),
      runGhJsonFn: () => []
    }
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.selection.status, 'release-unobserved');
  assert.equal(result.report.summary.status, 'release-unobserved');
});

test('runReleasePublishedBundleObserver reports asset-missing when the release lacks CompareVI.Tools bundle', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'published-bundle-observer-asset-missing-'));

  const result = await runReleasePublishedBundleObserver(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      tag: 'v0.6.4-rc.1'
    },
    {
      now: new Date('2026-03-23T19:16:00Z'),
      runGhJsonFn: () => [
        {
          tag_name: 'v0.6.4-rc.1',
          published_at: '2026-03-23T19:10:00Z',
          assets: [{ name: 'comparevi-cli-v0.6.4-rc.1.zip', id: 11 }]
        }
      ]
    }
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.selection.status, 'asset-missing');
  assert.equal(result.report.summary.status, 'asset-missing');
  assert.equal(result.report.selection.releaseTag, 'v0.6.4-rc.1');
});

test('runReleasePublishedBundleObserver certifies producer-native-ready bundle metadata from the published asset', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'published-bundle-observer-pass-'));
  const bundleRoot = path.join(repoRoot, 'tmp', 'bundle', 'CompareVI.Tools-v0.6.4-rc.1');
  const archivePath = path.join(repoRoot, 'tmp', 'download', 'CompareVI.Tools-v0.6.4-rc.1.zip');
  fs.mkdirSync(path.join(bundleRoot, 'tools', 'CompareVI.Tools'), { recursive: true });
  fs.mkdirSync(path.dirname(archivePath), { recursive: true });
  fs.writeFileSync(archivePath, 'zip-placeholder', 'utf8');
  fs.writeFileSync(path.join(bundleRoot, 'tools', 'CompareVI.Tools', 'CompareVI.Tools.psd1'), '@{}', 'utf8');
  writeJson(path.join(bundleRoot, 'comparevi-tools-release.json'), {
    schema: 'comparevi-tools-release-manifest@v1',
    versionContract: {
      authoritativeConsumerPin: '0.6.4-rc.1',
      authoritativeConsumerPinKind: 'release-version'
    },
    consumerContract: {
      historyFacade: { schema: 'comparevi-tools/history-facade@v1' },
      localRuntimeProfiles: { schema: 'comparevi-tools/runtime-profiles@v1' },
      localOperatorSession: { schema: 'comparevi-tools/local-operator-session@v1' },
      diagnosticsCommentRenderer: { schema: 'comparevi-tools/diagnostics-comment-renderer@v1' },
      hostedNiLinuxRunner: { schema: 'comparevi-tools/hosted-ni-linux-runner@v1' },
      dockerImageContract: {
        schema: 'comparevi-tools/docker-image-contract@v1',
        images: {
          hostedNiLinuxRunner: {
            imageRef: 'nationalinstruments/labview:2026q1-linux'
          }
        }
      },
      capabilities: {
        viHistory: {
          schema: 'comparevi-tools/vi-history-capability@v1',
          capabilityId: 'vi-history',
          distributionRole: 'upstream-producer',
          distributionModel: 'release-bundle',
          bundleImportPath: 'tools/CompareVI.Tools/CompareVI.Tools.psd1',
          releaseAssetPattern: 'CompareVI.Tools-v<release-version>.zip',
          contractPaths: {
            historyFacade: 'consumerContract.historyFacade',
            localRuntimeProfiles: 'consumerContract.localRuntimeProfiles',
            localOperatorSession: 'consumerContract.localOperatorSession',
            diagnosticsCommentRenderer: 'consumerContract.diagnosticsCommentRenderer',
            hostedNiLinuxRunner: 'consumerContract.hostedNiLinuxRunner'
          }
        },
        dockerProfile: {
          schema: 'comparevi-tools/docker-profile-capability@v1',
          capabilityId: 'docker-profile',
          distributionRole: 'upstream-producer',
          distributionModel: 'release-bundle',
          bundleImportPath: 'tools/CompareVI.Tools/CompareVI.Tools.psd1',
          releaseAssetPattern: 'CompareVI.Tools-v<release-version>.zip',
          authoritativeImageContractSource: 'consumerContract.dockerImageContract'
        }
      }
    }
  });

  const result = await runReleasePublishedBundleObserver(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T19:17:00Z'),
      runGhJsonFn: () => [
        {
          id: 55,
          tag_name: 'v0.6.4-rc.1',
          name: 'v0.6.4-rc.1',
          draft: false,
          prerelease: true,
          published_at: '2026-03-23T19:12:00Z',
          assets: [{ name: 'CompareVI.Tools-v0.6.4-rc.1.zip', id: 77 }]
        }
      ],
      downloadAssetFn: () => archivePath,
      extractArchiveFn: () => bundleRoot
    }
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.selection.status, 'selected');
  assert.equal(result.report.bundle.status, 'extracted');
  assert.equal(result.report.bundleContract.status, 'producer-native-ready');
  assert.equal(result.report.bundleContract.authoritativeConsumerPin, '0.6.4-rc.1');
  assert.equal(result.report.bundleContract.viHistoryCapabilityPresent, true);
  assert.equal(result.report.bundleContract.dockerProfileCapabilityPresent, true);
  assert.equal(result.report.bundleContract.authoritativeImageContractSource, 'consumerContract.dockerImageContract');
  assert.equal(result.report.bundleContract.authoritativeImageContractSourceResolved, true);
  assert.equal(result.report.bundleContract.dockerImageContractSchema, 'comparevi-tools/docker-image-contract@v1');
  assert.equal(result.report.summary.status, 'producer-native-ready');
});

test('runReleasePublishedBundleObserver reports producer-native-incomplete when vi-history capability is missing from published metadata', async () => {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'published-bundle-observer-incomplete-'));
  const bundleRoot = path.join(repoRoot, 'tmp', 'bundle', 'CompareVI.Tools-v0.6.3-tools.14');
  const archivePath = path.join(repoRoot, 'tmp', 'download', 'CompareVI.Tools-v0.6.3-tools.14.zip');
  fs.mkdirSync(bundleRoot, { recursive: true });
  fs.mkdirSync(path.dirname(archivePath), { recursive: true });
  fs.writeFileSync(archivePath, 'zip-placeholder', 'utf8');
  writeJson(path.join(bundleRoot, 'comparevi-tools-release.json'), {
    schema: 'comparevi-tools-release-manifest@v1',
    versionContract: {
      authoritativeConsumerPin: 'v0.6.3-tools.14',
      authoritativeConsumerPinKind: 'release-tag'
    },
    consumerContract: {
      historyFacade: { schema: 'comparevi-tools/history-facade@v1' },
      capabilities: {}
    }
  });

  const result = await runReleasePublishedBundleObserver(
    {
      repoRoot,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      now: new Date('2026-03-23T19:18:00Z'),
      runGhJsonFn: () => [
        {
          id: 56,
          tag_name: 'v0.6.3',
          draft: false,
          prerelease: false,
          published_at: '2026-03-21T19:12:00Z',
          assets: [{ name: 'CompareVI.Tools-v0.6.3-tools.14.zip', id: 88 }]
        }
      ],
      downloadAssetFn: () => archivePath,
      extractArchiveFn: () => bundleRoot
    }
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.bundleContract.status, 'producer-native-incomplete');
  assert.equal(result.report.bundleContract.viHistoryCapabilityPresent, false);
  assert.equal(result.report.summary.status, 'producer-native-incomplete');
});
