#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('docker lane handshake report schema validates a premium Sagan dual-lane grant receipt', async () => {
  const stateSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'docker-lane-handshake-v1.schema.json');
  const reportSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'docker-lane-handshake-report-v1.schema.json');
  const stateSchema = JSON.parse(await readFile(stateSchemaPath, 'utf8'));
  const reportSchema = JSON.parse(await readFile(reportSchemaPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(stateSchema, stateSchema.$id);
  const validate = ajv.compile(reportSchema);

  const report = {
    schema: 'priority/docker-lane-handshake-report@v1',
    generatedAt: '2026-03-23T23:55:00.000Z',
    action: 'grant',
    status: 'granted',
    laneId: 'docker-agent-sagan-dual-01',
    handshakePath: 'C:/repo/.git/docker-lane-handshakes/docker-agent-sagan-dual-01.json',
    policy: {
      operatorId: 'sergio',
      currency: 'USD',
      laborRateUsdPerHour: 250,
      premiumSaganRateMultiplier: 1.5
    },
    handshake: {
      schema: 'priority/docker-lane-handshake@v1',
      generatedAt: '2026-03-23T23:55:00.000Z',
      laneId: 'docker-agent-sagan-dual-01',
      resourceKind: 'docker-lane',
      state: 'granted',
      sequence: 2,
      heartbeatAt: '2026-03-23T23:55:00.000Z',
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
        requestedAt: '2026-03-23T23:54:00.000Z',
        agentId: 'sagan',
        agentClass: 'sagan',
        capabilities: ['docker-lane', 'native-labview-2026-32'],
        premiumDualLaneRequested: true,
        operatorId: 'sergio',
        operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-23'
      },
      grant: {
        grantedAt: '2026-03-23T23:55:00.000Z',
        grantor: 'sagan-governor',
        leaseId: 'lease-123',
        ttlSeconds: 1800,
        grantedCapabilities: ['docker-lane', 'native-labview-2026-32'],
        billableRateMultiplier: 1.5,
        billableRateUsdPerHour: 375,
        premiumSaganMode: true,
        policyDecision: 'sagan-premium-dual-lane',
        operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-23'
      },
      commit: null,
      release: null
    },
    summary: {
      handshakeState: 'granted',
      leaseId: 'lease-123',
      holder: 'sagan',
      premiumSaganMode: true,
      billableRateMultiplier: 1.5,
      billableRateUsdPerHour: 375,
      operatorAuthorizationRef: 'budget-auth://operator/session-2026-03-23',
      isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      isStale: false,
      ageSeconds: 0,
      ttlSeconds: 1800,
      denialReasons: [],
      observations: []
    }
  };

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});
