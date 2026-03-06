#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  buildSignalKey,
  evaluateCatalog,
  normalizeCatalog,
  parseArgs,
  runCanaryCatalog
} from '../canary-catalog.mjs';

function sampleCatalog(overrides = {}) {
  return {
    schema: 'canary-signal-catalog@v1',
    schemaVersion: '1.0.0',
    signals: [
      {
        id: 'signal-a',
        sourceType: 'workflow-run',
        incidentClass: 'workflow-run-failure',
        branch: 'develop',
        signaturePattern: 'validate:failure',
        severity: 'high',
        owner: 'release-platform',
        labels: ['ci'],
        expectedRoute: {
          actionType: 'open-issue',
          priority: 'P1',
          labels: ['ci']
        }
      },
      {
        id: 'signal-b',
        sourceType: 'deployment-state',
        incidentClass: 'deployment-state-anomaly',
        branch: 'develop',
        signaturePattern: 'validation:fail:no-active',
        severity: 'high',
        owner: 'release-platform',
        labels: ['ci', 'governance'],
        expectedRoute: {
          actionType: 'open-issue',
          priority: 'P1',
          labels: ['ci', 'governance']
        }
      }
    ],
    ...overrides
  };
}

test('parseArgs supports strict toggles and paths', () => {
  const parsed = parseArgs([
    'node',
    'canary-catalog.mjs',
    '--catalog',
    'catalog.json',
    '--report',
    'report.json',
    '--no-strict'
  ]);
  assert.equal(parsed.catalogPath, 'catalog.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.strict, false);
});

test('buildSignalKey is deterministic and normalized', () => {
  const key = buildSignalKey({
    sourceType: 'Workflow-Run',
    incidentClass: 'Workflow-Run-Failure',
    branch: 'Develop',
    signaturePattern: 'Validate:Failure'
  });
  assert.equal(key, 'workflow-run|workflow-run-failure|develop|validate:failure');
});

test('normalizeCatalog validates schema and sorts signals by id', () => {
  const normalized = normalizeCatalog(
    sampleCatalog({
      signals: [
        sampleCatalog().signals[1],
        sampleCatalog().signals[0]
      ]
    })
  );
  assert.deepEqual(
    normalized.signals.map((signal) => signal.id),
    ['signal-a', 'signal-b']
  );
});

test('evaluateCatalog flags duplicate keys and missing owner', () => {
  const normalized = normalizeCatalog(
    sampleCatalog({
      signals: [
        {
          ...sampleCatalog().signals[0],
          id: 'dup-a',
          owner: ''
        },
        {
          ...sampleCatalog().signals[0],
          id: 'dup-b'
        }
      ]
    })
  );
  const evaluation = evaluateCatalog(normalized);
  assert.ok(evaluation.issues.some((item) => item.startsWith('duplicate-key:')));
  assert.ok(evaluation.issues.some((item) => item === 'signal:dup-a:owner-missing'));
});

test('runCanaryCatalog writes pass report for valid catalog', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-catalog-'));
  const catalogPath = path.join(tmpDir, 'catalog.json');
  const reportPath = path.join(tmpDir, 'report.json');
  fs.writeFileSync(catalogPath, `${JSON.stringify(sampleCatalog(), null, 2)}\n`, 'utf8');

  const result = await runCanaryCatalog({
    argv: [
      'node',
      'canary-catalog.mjs',
      '--catalog',
      catalogPath,
      '--report',
      reportPath
    ],
    now: new Date('2026-03-06T22:00:00Z'),
    repoRoot: tmpDir
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.catalog.signalCount, 2);
  assert.equal(result.report.issues.length, 0);

  const persisted = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/canary-signal-catalog-report@v1');
});

test('runCanaryCatalog fails in strict mode when duplicate keys exist', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-catalog-fail-'));
  const catalogPath = path.join(tmpDir, 'catalog.json');
  const reportPath = path.join(tmpDir, 'report.json');
  fs.writeFileSync(
    catalogPath,
    `${JSON.stringify(
      sampleCatalog({
        signals: [
          {
            ...sampleCatalog().signals[0],
            id: 'dup-a'
          },
          {
            ...sampleCatalog().signals[0],
            id: 'dup-b'
          }
        ]
      }),
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runCanaryCatalog({
    argv: [
      'node',
      'canary-catalog.mjs',
      '--catalog',
      catalogPath,
      '--report',
      reportPath
    ],
    now: new Date('2026-03-06T22:01:00Z'),
    repoRoot: tmpDir
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, 'fail');
  assert.ok(result.report.issues.some((item) => item.startsWith('duplicate-key:')));
});
