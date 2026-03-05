import test from 'node:test';
import assert from 'node:assert/strict';
import {
  sessionIndexSchema,
  runSchema,
  environmentSchema,
  branchProtectionSchema,
  testCaseSchema,
  testsSchema,
  artifactSchema,
  triggerSchema,
} from '../../../dist/src/session-index/schema.js';

// --- triggerSchema ---

test('triggerSchema accepts a complete trigger', () => {
  const result = triggerSchema.safeParse({
    kind: 'pull_request',
    number: 42,
    author: 'user1',
    commentId: 12345,
    commentUrl: 'https://github.com/org/repo/issues/42#issuecomment-12345',
  });
  assert.ok(result.success);
});

test('triggerSchema accepts empty object', () => {
  const result = triggerSchema.safeParse({});
  assert.ok(result.success);
});

test('triggerSchema rejects extra properties', () => {
  const result = triggerSchema.safeParse({ kind: 'push', extra: true });
  assert.ok(!result.success, 'should reject extra properties');
});

test('triggerSchema accepts string commentId', () => {
  const result = triggerSchema.safeParse({ commentId: 'abc-123' });
  assert.ok(result.success);
});

// --- runSchema ---

test('runSchema requires workflow field', () => {
  const result = runSchema.safeParse({});
  assert.ok(!result.success, 'should fail without workflow');
});

test('runSchema accepts minimal run with workflow', () => {
  const result = runSchema.safeParse({ workflow: 'ci.yml' });
  assert.ok(result.success);
});

test('runSchema accepts full run object', () => {
  const result = runSchema.safeParse({
    id: '123456',
    attempt: 1,
    workflow: 'ci-orchestrated',
    job: 'lint',
    branch: 'develop',
    commit: 'abc123def',
    repository: 'org/repo',
    trigger: { kind: 'push' },
  });
  assert.ok(result.success);
});

test('runSchema rejects negative attempt', () => {
  const result = runSchema.safeParse({ workflow: 'test', attempt: -1 });
  assert.ok(!result.success, 'should reject negative attempt');
});

// --- environmentSchema ---

test('environmentSchema accepts empty object', () => {
  const result = environmentSchema.safeParse({});
  assert.ok(result.success);
});

test('environmentSchema accepts custom key-value map', () => {
  const result = environmentSchema.safeParse({
    runner: 'ubuntu-latest',
    custom: { labview: '2024Q3', dotnet: '8.0' },
  });
  assert.ok(result.success);
  assert.equal(result.data?.custom?.labview, '2024Q3');
});

test('environmentSchema rejects non-string custom values', () => {
  const result = environmentSchema.safeParse({ custom: { num: 42 } });
  assert.ok(!result.success, 'should reject non-string values in custom');
});

// --- branchProtectionSchema ---

test('branchProtectionSchema requires status field', () => {
  const result = branchProtectionSchema.safeParse({});
  assert.ok(!result.success, 'should fail without status');
});

test('branchProtectionSchema accepts all valid statuses', () => {
  for (const status of ['ok', 'warn', 'error']) {
    const result = branchProtectionSchema.safeParse({ status });
    assert.ok(result.success, `should accept status '${status}'`);
  }
});

test('branchProtectionSchema accepts all valid reasons', () => {
  const reasons = [
    'aligned', 'missing_required', 'extra_required', 'mismatch',
    'mapping_missing', 'api_unavailable', 'api_error', 'api_forbidden',
  ];
  for (const reason of reasons) {
    const result = branchProtectionSchema.safeParse({ status: 'warn', reason });
    assert.ok(result.success, `should accept reason '${reason}'`);
  }
});

test('branchProtectionSchema rejects invalid reason', () => {
  const result = branchProtectionSchema.safeParse({ status: 'ok', reason: 'unknown_reason' });
  assert.ok(!result.success, 'should reject unknown reason');
});

// --- testCaseSchema ---

test('testCaseSchema requires id and outcome', () => {
  const result = testCaseSchema.safeParse({});
  assert.ok(!result.success, 'should fail without id and outcome');
});

test('testCaseSchema accepts minimal test case', () => {
  const result = testCaseSchema.safeParse({ id: 'test-1', outcome: 'passed' });
  assert.ok(result.success);
});

test('testCaseSchema accepts full test case', () => {
  const result = testCaseSchema.safeParse({
    id: 'smoke::check-exit',
    category: 'smoke',
    requirement: 'REQ-001',
    rationale: 'Exit code must be 0 on success.',
    expectedResult: 'Process exits cleanly.',
    outcome: 'passed',
    durationMs: 1234,
    retry: 0,
    artifacts: ['results/log.txt'],
    tags: ['smoke', 'ci'],
    diagnostics: ['No warnings.'],
  });
  assert.ok(result.success);
});

test('testCaseSchema rejects invalid outcome', () => {
  const result = testCaseSchema.safeParse({ id: 'test-1', outcome: 'aborted' });
  assert.ok(!result.success, 'should reject outcome "aborted"');
});

test('testCaseSchema validates all outcome values', () => {
  for (const outcome of ['passed', 'failed', 'skipped', 'error', 'unknown']) {
    const result = testCaseSchema.safeParse({ id: 'test-x', outcome });
    assert.ok(result.success, `should accept outcome '${outcome}'`);
  }
});

// --- testsSchema ---

test('testsSchema accepts empty object', () => {
  const result = testsSchema.safeParse({});
  assert.ok(result.success);
});

test('testsSchema accepts summary and cases', () => {
  const result = testsSchema.safeParse({
    summary: { total: 2, passed: 2, failed: 0, errors: 0, skipped: 0 },
    cases: [
      { id: 'a', outcome: 'passed' },
      { id: 'b', outcome: 'passed' },
    ],
  });
  assert.ok(result.success);
});

// --- artifactSchema ---

test('artifactSchema requires name and path', () => {
  const result = artifactSchema.safeParse({});
  assert.ok(!result.success);
});

test('artifactSchema accepts minimal artifact', () => {
  const result = artifactSchema.safeParse({ name: 'report', path: 'out/report.html' });
  assert.ok(result.success);
});

test('artifactSchema accepts full artifact with checksum', () => {
  const result = artifactSchema.safeParse({
    name: 'archive',
    path: 'out/archive.zip',
    kind: 'artifact',
    mimeType: 'application/zip',
    sizeBytes: 1024,
    checksum: { algorithm: 'sha256', value: 'deadbeef' },
  });
  assert.ok(result.success);
});

test('artifactSchema validates kind enum', () => {
  for (const kind of ['summary', 'report', 'log', 'artifact', 'traceability', 'custom']) {
    const result = artifactSchema.safeParse({ name: 'a', path: 'b', kind });
    assert.ok(result.success, `should accept kind '${kind}'`);
  }
});

test('artifactSchema rejects invalid kind', () => {
  const result = artifactSchema.safeParse({ name: 'a', path: 'b', kind: 'attachment' });
  assert.ok(!result.success, 'should reject kind "attachment"');
});

// --- sessionIndexSchema (full document) ---

test('sessionIndexSchema accepts minimal valid document', () => {
  const result = sessionIndexSchema.safeParse({
    schema: 'session-index/v2',
    schemaVersion: '2.0.0',
    generatedAtUtc: new Date().toISOString(),
    run: { workflow: 'ci.yml' },
  });
  assert.ok(result.success);
});

test('sessionIndexSchema rejects wrong schema literal', () => {
  const result = sessionIndexSchema.safeParse({
    schema: 'session-index/v1',
    schemaVersion: '2.0.0',
    generatedAtUtc: new Date().toISOString(),
    run: { workflow: 'ci.yml' },
  });
  assert.ok(!result.success, 'should reject v1 schema literal');
});

test('sessionIndexSchema rejects invalid semver format', () => {
  const result = sessionIndexSchema.safeParse({
    schema: 'session-index/v2',
    schemaVersion: '2.0',
    generatedAtUtc: new Date().toISOString(),
    run: { workflow: 'ci.yml' },
  });
  assert.ok(!result.success, 'should reject non-semver version');
});

test('sessionIndexSchema rejects extra top-level properties', () => {
  const result = sessionIndexSchema.safeParse({
    schema: 'session-index/v2',
    schemaVersion: '2.0.0',
    generatedAtUtc: new Date().toISOString(),
    run: { workflow: 'ci.yml' },
    unknownProp: true,
  });
  assert.ok(!result.success, 'should reject unknown top-level properties');
});

test('sessionIndexSchema accepts full document with all optional blocks', () => {
  const result = sessionIndexSchema.safeParse({
    schema: 'session-index/v2',
    schemaVersion: '2.0.0',
    generatedAtUtc: '2025-06-15T12:00:00.000Z',
    run: {
      id: '999',
      attempt: 2,
      workflow: 'ci-orchestrated',
      job: 'session-index',
      branch: 'develop',
      commit: 'abc123',
      repository: 'org/repo',
      trigger: { kind: 'push' },
    },
    environment: {
      runner: 'ubuntu-24.04',
      node: 'v20.11.0',
      pwsh: '7.5.3',
    },
    branchProtection: {
      status: 'ok',
      reason: 'aligned',
      expected: ['lint', 'fixtures'],
      actual: ['lint', 'fixtures'],
      mapping: { path: 'tools/policy/branch-required-checks.json', digest: 'abc123' },
      notes: ['All aligned.'],
    },
    tests: {
      summary: { total: 3, passed: 3, failed: 0, errors: 0, skipped: 0, durationSeconds: 12.5 },
      cases: [
        { id: 'test-1', outcome: 'passed', durationMs: 500, category: 'unit' },
        { id: 'test-2', outcome: 'passed', durationMs: 300, tags: ['smoke'] },
        { id: 'test-3', outcome: 'passed', durationMs: 200 },
      ],
    },
    artifacts: [
      { name: 'summary', path: 'results/summary.json', kind: 'summary' },
    ],
    notes: ['All checks green.'],
    extra: { lane: 'issue/664', debug: false },
  });
  assert.ok(result.success);
});
