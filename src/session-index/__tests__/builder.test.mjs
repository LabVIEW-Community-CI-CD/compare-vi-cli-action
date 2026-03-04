import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionIndexBuilder, createSessionIndexBuilder } from '../../../dist/src/session-index/builder.js';

test('SessionIndexBuilder.create() returns a builder instance', () => {
  const builder = SessionIndexBuilder.create();
  assert.ok(builder, 'builder should be truthy');
  assert.equal(typeof builder.build, 'function');
});

test('createSessionIndexBuilder() factory returns a builder instance', () => {
  const builder = createSessionIndexBuilder();
  assert.ok(builder, 'builder should be truthy');
  assert.equal(typeof builder.build, 'function');
});

test('build() produces a valid session-index/v2 document with defaults', () => {
  const index = SessionIndexBuilder.create().build();
  assert.equal(index.schema, 'session-index/v2');
  assert.equal(index.schemaVersion, '2.0.0');
  assert.ok(index.generatedAtUtc, 'should have generatedAtUtc');
  assert.equal(index.run.workflow, 'unknown');
});

test('withGeneratedAt() sets the timestamp', () => {
  const date = new Date('2025-06-15T12:00:00Z');
  const index = SessionIndexBuilder.create().withGeneratedAt(date).build();
  assert.equal(index.generatedAtUtc, '2025-06-15T12:00:00.000Z');
});

test('setRun() merges run metadata', () => {
  const index = SessionIndexBuilder.create()
    .setRun({
      workflow: 'ci-orchestrated',
      job: 'lint',
      branch: 'develop',
      commit: 'abc123',
      repository: 'org/repo',
    })
    .build();

  assert.equal(index.run.workflow, 'ci-orchestrated');
  assert.equal(index.run.job, 'lint');
  assert.equal(index.run.branch, 'develop');
  assert.equal(index.run.commit, 'abc123');
  assert.equal(index.run.repository, 'org/repo');
});

test('setRun() with trigger populates trigger fields', () => {
  const index = SessionIndexBuilder.create()
    .setRun({
      workflow: 'test',
      trigger: { kind: 'pull_request', number: 42, author: 'user1' },
    })
    .build();

  assert.equal(index.run.trigger?.kind, 'pull_request');
  assert.equal(index.run.trigger?.number, 42);
  assert.equal(index.run.trigger?.author, 'user1');
});

test('setEnvironment() populates environment block', () => {
  const index = SessionIndexBuilder.create()
    .setEnvironment({
      runner: 'ubuntu-24.04',
      node: 'v20.0.0',
      os: 'Linux',
    })
    .build();

  assert.equal(index.environment?.runner, 'ubuntu-24.04');
  assert.equal(index.environment?.node, 'v20.0.0');
  assert.equal(index.environment?.os, 'Linux');
});

test('setEnvironment() with custom key-value pairs', () => {
  const index = SessionIndexBuilder.create()
    .setEnvironment({ custom: { labview: '2024Q3' } })
    .build();

  assert.equal(index.environment?.custom?.labview, '2024Q3');
});

test('setBranchProtection() sets branch protection status', () => {
  const index = SessionIndexBuilder.create()
    .setBranchProtection({ status: 'ok', reason: 'aligned' })
    .build();

  assert.equal(index.branchProtection?.status, 'ok');
  assert.equal(index.branchProtection?.reason, 'aligned');
});

test('setBranchProtection(undefined) clears the block', () => {
  const index = SessionIndexBuilder.create()
    .setBranchProtection({ status: 'warn' })
    .setBranchProtection(undefined)
    .build();

  assert.equal(index.branchProtection, undefined);
});

test('setBranchProtection() merges with existing data', () => {
  const index = SessionIndexBuilder.create()
    .setBranchProtection({ status: 'warn', reason: 'api_forbidden' })
    .setBranchProtection({ status: 'ok', reason: 'aligned' })
    .build();

  assert.equal(index.branchProtection?.status, 'ok');
  assert.equal(index.branchProtection?.reason, 'aligned');
});

test('addBranchProtectionNotes() appends notes', () => {
  const index = SessionIndexBuilder.create()
    .addBranchProtectionNotes('Note 1', 'Note 2')
    .build();

  assert.equal(index.branchProtection?.status, 'warn');
  assert.deepEqual(index.branchProtection?.notes, ['Note 1', 'Note 2']);
});

test('addBranchProtectionNotes() filters falsy values', () => {
  const index = SessionIndexBuilder.create()
    .addBranchProtectionNotes('Note 1', '', 'Note 2')
    .build();

  assert.deepEqual(index.branchProtection?.notes, ['Note 1', 'Note 2']);
});

test('setTestsSummary() sets the summary block', () => {
  const index = SessionIndexBuilder.create()
    .setTestsSummary({
      total: 10,
      passed: 8,
      failed: 1,
      errors: 0,
      skipped: 1,
      durationSeconds: 30.5,
    })
    .build();

  assert.equal(index.tests?.summary?.total, 10);
  assert.equal(index.tests?.summary?.passed, 8);
  assert.equal(index.tests?.summary?.failed, 1);
  assert.equal(index.tests?.summary?.durationSeconds, 30.5);
});

test('addTestCase() appends test cases', () => {
  const index = SessionIndexBuilder.create()
    .addTestCase({ id: 'test-1', outcome: 'passed', durationMs: 100 })
    .addTestCase({ id: 'test-2', outcome: 'failed', tags: ['regression'] })
    .build();

  assert.equal(index.tests?.cases?.length, 2);
  assert.equal(index.tests?.cases?.[0]?.id, 'test-1');
  assert.equal(index.tests?.cases?.[0]?.outcome, 'passed');
  assert.equal(index.tests?.cases?.[1]?.id, 'test-2');
  assert.equal(index.tests?.cases?.[1]?.outcome, 'failed');
  assert.deepEqual(index.tests?.cases?.[1]?.tags, ['regression']);
});

test('addArtifact() appends artifacts', () => {
  const index = SessionIndexBuilder.create()
    .addArtifact({ name: 'summary', path: 'results/summary.json', kind: 'summary' })
    .addArtifact({ name: 'report', path: 'results/report.html', kind: 'report', mimeType: 'text/html' })
    .build();

  assert.equal(index.artifacts?.length, 2);
  assert.equal(index.artifacts?.[0]?.name, 'summary');
  assert.equal(index.artifacts?.[0]?.kind, 'summary');
  assert.equal(index.artifacts?.[1]?.mimeType, 'text/html');
});

test('addNote() appends notes to the top-level notes array', () => {
  const index = SessionIndexBuilder.create()
    .addNote('First note')
    .addNote('Second note')
    .build();

  assert.deepEqual(index.notes, ['First note', 'Second note']);
});

test('addNote() ignores empty strings', () => {
  const index = SessionIndexBuilder.create()
    .addNote('')
    .addNote('Valid note')
    .build();

  assert.deepEqual(index.notes, ['Valid note']);
});

test('setExtra() sets arbitrary key-value pairs', () => {
  const index = SessionIndexBuilder.create()
    .setExtra('customKey', { nested: true })
    .setExtra('anotherKey', 42)
    .build();

  assert.deepEqual(index.extra?.customKey, { nested: true });
  assert.equal(index.extra?.anotherKey, 42);
});

test('toJSON() returns a copy without validation', () => {
  const builder = SessionIndexBuilder.create();
  const json = builder.toJSON();

  assert.equal(json.schema, 'session-index/v2');
  assert.ok(json.generatedAtUtc);

  // Verify it's a copy (not the same reference)
  json.notes = ['mutated'];
  const json2 = builder.toJSON();
  assert.equal(json2.notes, undefined);
});

test('build() throws on invalid schema (negative test count)', () => {
  const builder = SessionIndexBuilder.create()
    .setTestsSummary({
      total: -1,
      passed: 0,
      failed: 0,
      errors: 0,
      skipped: 0,
    });

  assert.throws(() => builder.build(), /.*/, 'should throw for negative total');
});

test('fluent chaining produces expected composite document', () => {
  const index = SessionIndexBuilder.create()
    .withGeneratedAt(new Date('2025-01-01T00:00:00Z'))
    .setRun({
      workflow: 'ci-orchestrated',
      job: 'session-index',
      branch: 'develop',
      commit: 'deadbeef',
      repository: 'org/repo',
      trigger: { kind: 'push' },
    })
    .setEnvironment({ runner: 'ubuntu-latest', node: 'v20.11.0' })
    .setBranchProtection({ status: 'ok', reason: 'aligned' })
    .setTestsSummary({ total: 5, passed: 5, failed: 0, errors: 0, skipped: 0 })
    .addTestCase({ id: 'smoke-1', outcome: 'passed', durationMs: 250 })
    .addArtifact({ name: 'pester-xml', path: 'results/pester.xml', kind: 'report' })
    .addNote('All checks green.')
    .setExtra('lane', 'issue/664')
    .build();

  assert.equal(index.schema, 'session-index/v2');
  assert.equal(index.schemaVersion, '2.0.0');
  assert.equal(index.generatedAtUtc, '2025-01-01T00:00:00.000Z');
  assert.equal(index.run.workflow, 'ci-orchestrated');
  assert.equal(index.run.branch, 'develop');
  assert.equal(index.environment?.runner, 'ubuntu-latest');
  assert.equal(index.branchProtection?.status, 'ok');
  assert.equal(index.tests?.summary?.total, 5);
  assert.equal(index.tests?.cases?.length, 1);
  assert.equal(index.artifacts?.length, 1);
  assert.deepEqual(index.notes, ['All checks green.']);
  assert.equal(index.extra?.lane, 'issue/664');
});
