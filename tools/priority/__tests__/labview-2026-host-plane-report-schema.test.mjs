#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('labview-2026 host plane schema validates the shadow-plane policy contract', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'labview-2026-host-plane-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const report = {
    schema: 'labview-2026-host-plane-report@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    host: {
      os: 'windows',
      computerName: 'builder',
      osFingerprint: {
        role: 'canonical-host-baseline',
        comparisonScope: 'isolated-lane-group',
        platform: 'windows',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        canonical: {
          version: '10.0.26200',
          buildNumber: '26200',
          ubr: 8037,
          displayVersion: '25H2',
          editionId: 'Professional',
          installationType: 'Client',
          architecture: '64-bit',
          systemType: 'x64-based PC',
          buildLabEx: '26100.1.amd64fre.ge_release.240331-1435'
        },
        advisory: {
          caption: 'Microsoft Windows 11 Pro',
          productName: 'Windows 10 Pro',
          currentVersionCompatibility: '6.3',
          brandingMismatch: true,
          installDate: '2026-02-14T03:49:47.0000000-08:00',
          lastBootUpTime: '2026-03-20T09:06:51.0000000-07:00'
        },
        sources: {
          registryPath: 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion',
          cimClass: 'Win32_OperatingSystem',
          systemClass: 'Win32_ComputerSystem',
          comparisonFields: [
            'version',
            'buildNumber',
            'ubr',
            'displayVersion',
            'editionId',
            'installationType',
            'architecture',
            'systemType',
            'buildLabEx'
          ]
        }
      }
    },
    runner: { hostIsRunner: true, runnerName: 'builder', githubActions: false },
    docker: {
      operatorLabels: ['linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop']
    },
    policy: {
      authoritativePlanes: [
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      ],
      hostNativeShadowPlane: {
        plane: 'native-labview-2026-32',
        role: 'acceleration-surface',
        authoritative: false,
        executionMode: 'manual-opt-in',
        hostedCiAllowed: false,
        promotionPrerequisites: [
          'docker-desktop/linux-container-2026',
          'docker-desktop/windows-container-2026'
        ]
      }
    },
    native: {
      parallelLabVIEWSupported: true,
      sharedCliAcrossNativePlanes: true,
      recommendedParallelPlanes: ['native-labview-2026-64', 'native-labview-2026-32'],
      planes: {
        x64: {
          plane: 'native-labview-2026-64',
          operatorLabel: 'native-labview-2026-64',
          architecture: '64-bit',
          requestedLabVIEWPath: 'C:/lv64/LabVIEW.exe',
          requestedCliPath: 'C:/cli/LabVIEWCLI.exe',
          requestedComparePath: 'C:/compare/LVCompare.exe',
          labviewPath: 'C:/lv64/LabVIEW.exe',
          cliPath: 'C:/cli/LabVIEWCLI.exe',
          comparePath: 'C:/compare/LVCompare.exe',
          labviewPresent: true,
          cliPresent: true,
          comparePresent: true,
          status: 'ready',
          issues: []
        },
        x32: {
          plane: 'native-labview-2026-32',
          operatorLabel: 'native-labview-2026-32',
          architecture: '32-bit',
          requestedLabVIEWPath: 'C:/lv32/LabVIEW.exe',
          requestedCliPath: 'C:/cli/LabVIEWCLI.exe',
          requestedComparePath: 'C:/compare/LVCompare.exe',
          labviewPath: 'C:/lv32/LabVIEW.exe',
          cliPath: 'C:/cli/LabVIEWCLI.exe',
          comparePath: 'C:/compare/LVCompare.exe',
          labviewPresent: true,
          cliPresent: true,
          comparePresent: true,
          status: 'ready',
          issues: []
        }
      }
    },
    executionPolicy: {
      mutuallyExclusivePairs: {
        pairs: [{ left: 'docker-desktop/linux-container-2026', right: 'docker-desktop/windows-container-2026' }]
      },
      provenParallelPairs: {
        pairs: [
          { left: 'docker-desktop/windows-container-2026', right: 'native-labview-2026-64' },
          { left: 'native-labview-2026-64', right: 'native-labview-2026-32' }
        ]
      },
      candidateParallelPairs: {
        pairs: [
          { left: 'docker-desktop/windows-container-2026', right: 'native-labview-2026-64' },
          { left: 'native-labview-2026-64', right: 'native-labview-2026-32' }
        ]
      }
    }
  };

  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});
