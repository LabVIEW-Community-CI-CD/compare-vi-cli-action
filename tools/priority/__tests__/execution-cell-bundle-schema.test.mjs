#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('execution cell bundle report schema validates a premium Sagan kernel receipt', async () => {
  const executionCellStateSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'execution-cell-lease-v1.schema.json'), 'utf8')
  );
  const executionCellReportSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'execution-cell-lease-report-v1.schema.json'), 'utf8')
  );
  const dockerStateSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'docker-lane-handshake-v1.schema.json'), 'utf8')
  );
  const dockerReportSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'docker-lane-handshake-report-v1.schema.json'), 'utf8')
  );
  const bundleSchema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'execution-cell-bundle-report-v1.schema.json'), 'utf8')
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(executionCellStateSchema, executionCellStateSchema.$id);
  ajv.addSchema(executionCellReportSchema, executionCellReportSchema.$id);
  ajv.addSchema(dockerStateSchema, dockerStateSchema.$id);
  ajv.addSchema(dockerReportSchema, dockerReportSchema.$id);
  const validate = ajv.compile(bundleSchema);

  const report = {
    schema: 'priority/execution-cell-bundle-report@v1',
    generatedAt: '2026-03-24T02:10:00.000Z',
    action: 'grant',
    status: 'granted',
    cellId: 'exec-cell-sagan-kernel-02',
    laneId: 'docker-agent-sagan-kernel-02',
    outputPath: 'tests/results/_agent/runtime/execution-cell-bundle.json',
    executionCellReportPath: 'tests/results/_agent/runtime/execution-cell-lease.json',
    dockerLaneReportPath: 'tests/results/_agent/runtime/docker-lane-handshake.json',
    executionCell: {
      schema: 'priority/execution-cell-lease-report@v1',
      generatedAt: '2026-03-24T02:10:00.000Z',
      action: 'grant',
      status: 'granted',
      cellId: 'exec-cell-sagan-kernel-02',
      leasePath: 'C:/repo/.git/execution-cell-leases/exec-cell-sagan-kernel-02.json',
      policy: {
        operatorId: 'sergio',
        currency: 'USD',
        laborRateUsdPerHour: 250
      },
      lease: {
        schema: 'priority/execution-cell-lease@v1',
        generatedAt: '2026-03-24T02:10:00.000Z',
        cellId: 'exec-cell-sagan-kernel-02',
        resourceKind: 'execution-cell',
        state: 'granted',
        sequence: 2,
        heartbeatAt: '2026-03-24T02:10:00.000Z',
        host: {
          isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          platform: 'windows',
          computerName: 'canonical-builder',
          canonical: {
            version: '10.0.26200',
            buildNumber: '26200',
            ubr: 8037
          }
        },
        request: {
          requestId: 'request-123',
          requestedAt: '2026-03-24T02:09:00.000Z',
          agentId: 'sagan',
          agentClass: 'sagan',
          cellClass: 'kernel-coordinator',
          suiteClass: 'dual-plane-parity',
          planeBinding: 'dual-plane-parity',
          harnessKind: 'teststand-compare-harness',
          capabilities: ['teststand-harness', 'docker-lane', 'native-labview-2026-32'],
          premiumDualLaneRequested: true,
          operatorId: 'sergio',
          operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
          workingRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/work',
          artifactRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/artifacts'
        },
        grant: {
          grantedAt: '2026-03-24T02:10:00.000Z',
          grantor: 'execution-cell-governor',
          leaseId: 'lease-123',
          ttlSeconds: 1800,
          premiumDualLaneRequested: true,
          premiumSaganMode: true,
          policyDecision: 'sagan-premium-dual-lane',
          grantedCapabilities: ['teststand-harness', 'docker-lane', 'native-labview-2026-32'],
          billableRateMultiplier: 1.5,
          billableRateUsdPerHour: 375
        },
        commit: null,
        release: null
      },
      summary: {
        leaseState: 'granted',
        leaseId: 'lease-123',
        holder: 'sagan',
        agentClass: 'sagan',
        cellClass: 'kernel-coordinator',
        harnessKind: 'teststand-compare-harness',
        harnessInstanceId: null,
        suiteClass: 'dual-plane-parity',
        planeBinding: 'dual-plane-parity',
        premiumSaganMode: true,
        billableRateMultiplier: 1.5,
        billableRateUsdPerHour: 375,
        operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        linkedDockerLaneId: null,
        linkedDockerLaneLeaseId: null,
        workingRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/work',
        artifactRoot: 'E:/comparevi-lanes/cells/sagan-kernel-02/artifacts',
        isStale: false,
        ageSeconds: 0,
        ttlSeconds: 1800,
        denialReasons: [],
        observations: []
      }
    },
    dockerLane: {
      schema: 'priority/docker-lane-handshake-report@v1',
      generatedAt: '2026-03-24T02:10:00.000Z',
      action: 'grant',
      status: 'granted',
      laneId: 'docker-agent-sagan-kernel-02',
      handshakePath: 'C:/repo/.git/docker-lane-handshakes/docker-agent-sagan-kernel-02.json',
      policy: {
        operatorId: 'sergio',
        currency: 'USD',
        laborRateUsdPerHour: 250,
        premiumSaganRateMultiplier: 1.5
      },
      handshake: {
        schema: 'priority/docker-lane-handshake@v1',
        generatedAt: '2026-03-24T02:10:00.000Z',
        laneId: 'docker-agent-sagan-kernel-02',
        resourceKind: 'docker-lane',
        state: 'granted',
        sequence: 2,
        heartbeatAt: '2026-03-24T02:10:00.000Z',
        host: {
          isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          platform: 'windows',
          computerName: 'canonical-builder',
          canonical: {
            version: '10.0.26200',
            buildNumber: '26200',
            ubr: 8037
          }
        },
        request: {
          requestId: 'request-456',
          requestedAt: '2026-03-24T02:09:00.000Z',
          agentId: 'sagan',
          agentClass: 'sagan',
          capabilities: ['docker-lane', 'native-labview-2026-32', 'teststand-harness'],
          premiumDualLaneRequested: true,
          operatorId: 'sergio',
          operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24'
        },
        grant: {
          grantedAt: '2026-03-24T02:10:00.000Z',
          grantor: 'sagan-governor',
          leaseId: 'lease-456',
          ttlSeconds: 1800,
          grantedCapabilities: ['docker-lane', 'native-labview-2026-32', 'teststand-harness'],
          billableRateMultiplier: 1.5,
          billableRateUsdPerHour: 375,
          premiumSaganMode: true,
          policyDecision: 'sagan-premium-dual-lane',
          operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24'
        },
        commit: null,
        release: null
      },
      summary: {
        handshakeState: 'granted',
        leaseId: 'lease-456',
        holder: 'sagan',
        premiumSaganMode: true,
        billableRateMultiplier: 1.5,
        billableRateUsdPerHour: 375,
        operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        linkedExecutionCellId: null,
        linkedExecutionCellLeaseId: null,
        isStale: false,
        ageSeconds: 0,
        ttlSeconds: 1800,
        denialReasons: [],
        observations: []
      }
    },
    rollbacks: {
      executionCell: null,
      dockerLane: null
    },
    summary: {
      holder: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'dual-plane-parity',
      harnessKind: 'teststand-compare-harness',
      harnessInstanceId: null,
      executionCellLeaseId: 'lease-123',
      dockerLaneLeaseId: 'lease-456',
      linkedExecutionCellId: null,
      linkedExecutionCellLeaseId: null,
      linkedDockerLaneId: null,
      linkedDockerLaneLeaseId: null,
      reciprocalLinkReady: false,
      dockerRequested: true,
      windowsNativeTestStand: true,
      effectiveBillableRateMultiplier: 1.5,
      effectiveBillableRateUsdPerHour: 375,
      premiumSaganMode: true,
      operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-24',
      isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      capabilities: ['teststand-harness', 'docker-lane', 'native-labview-2026-32'],
      denialReasons: [],
      observations: ['agent-billed-once-at-effective-rate']
    }
  };

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});
