import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runReleasePublishedBundleObserver } from '../release-published-bundle-observer.mjs';

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
}

function resolveValidatorRepoRoot(repoRoot) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRoot, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRoot;
  }
  const candidates = [
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1843-wake-lifecycle-state-machine')
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json'))
    ) || repoRoot
  );
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRoot);
  execFileSync('node', ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPath), '--data', toGlobPath(dataPath)], {
    cwd: validatorRepoRoot,
    stdio: 'pipe'
  });
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('release published bundle observer report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-published-bundle-observer-schema-'));
  const bundleRoot = path.join(tmpDir, 'bundle', 'CompareVI.Tools-v0.6.4-rc.1');
  const archivePath = path.join(tmpDir, 'download', 'CompareVI.Tools-v0.6.4-rc.1.zip');

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

  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'release', 'release-published-bundle-observer.json');
  const { report } = await runReleasePublishedBundleObserver(
    {
      repoRoot: tmpDir,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      outputPath
    },
    {
      now: new Date('2026-03-23T19:19:00Z'),
      runGhJsonFn: () => [
        {
          id: 70,
          tag_name: 'v0.6.4-rc.1',
          name: 'v0.6.4-rc.1',
          draft: false,
          prerelease: true,
          published_at: '2026-03-23T19:12:00Z',
          assets: [{ name: 'CompareVI.Tools-v0.6.4-rc.1.zip', id: 71 }]
        }
      ],
      downloadAssetFn: () => archivePath,
      extractArchiveFn: () => bundleRoot
    }
  );

  runSchemaValidate(
    repoRoot,
    path.join(repoRoot, 'docs', 'schemas', 'release-published-bundle-observer-report-v1.schema.json'),
    outputPath
  );
  assert.equal(report.schema, 'priority/release-published-bundle-observer-report@v1');
});
