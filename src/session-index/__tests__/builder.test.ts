import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createSessionIndexBuilder } from '../builder.js';
import type { SessionIndexToggleValues } from '../schema.js';

function createTogglePayload(): SessionIndexToggleValues {
  return {
    schema: 'agent-toggle-values/v1',
    schemaVersion: '1.0.0',
    generatedAtUtc: '2025-01-01T00:00:00Z',
    manifestDigest: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    manifestGeneratedAtUtc: '2025-01-01T00:00:00Z',
    profiles: ['dev-workstation', 'ci-orchestrated'],
    context: {
      tags: ['zeta', 'alpha']
    },
    values: {
      Z_TOGGLE: {
        value: true,
        valueType: 'boolean',
        source: 'profile',
        profile: 'dev-workstation',
        description: 'Z toggle'
      },
      A_TOGGLE: {
        value: 'enabled',
        valueType: 'string',
        source: 'default',
        description: 'A toggle'
      }
    }
  };
}

function createBuilderWithData() {
  const builder = createSessionIndexBuilder();
  builder.setRun({
    workflow: 'Validate',
    job: 'session-index',
    branch: 'feature/in-flight',
    branchState: {
      branch: ' feature/in-flight ',
      upstream: ' origin/develop ',
      summary: ' Branch feature/in-flight: ahead 1 of origin/develop ',
      ahead: 1,
      behind: 0,
      hasUpstream: true,
      isClean: false,
      hasUntracked: true,
      timestampUtc: ' 2025-01-01T12:00:00Z '
    }
  });

  builder.setEnvironment({
    runner: 'ubuntu-24.04',
    node: '20.12.0',
    pwsh: '7.5.3',
    custom: {
      zKey: 'zeta',
      aKey: 'alpha'
    }
  });
  builder.setEnvironmentToggles(createTogglePayload());

  builder.setBranchProtection({
    status: 'warn',
    expected: ['Validate / session-index', 'Validate / lint'],
    produced: ['Validate / lint', 'Validate / fixtures', 'Validate / session-index'],
    notes: ['second note', 'first note'],
    actual: {
      status: 'available',
      contexts: ['Workflows Lint', 'Validate']
    }
  });
  builder.addBranchProtectionNotes('delta', 'beta', '');

  builder.setTestsSummary({
    total: 2,
    passed: 2,
    failed: 0,
    errors: 0,
    skipped: 0,
    durationSeconds: 10
  });
  builder.addTestCase({
    id: 'test-b',
    outcome: 'passed'
  });
  builder.addTestCase({
    id: 'test-a',
    outcome: 'passed'
  });
  builder.addTestCase({
    id: 'test-c',
    outcome: 'passed',
    requirement: ''
  });

  builder.addArtifact({
    name: 'z-artifact',
    path: 'reports/z.json'
  });
  builder.addArtifact({
    name: 'a-artifact',
    path: 'reports/b.json'
  });
  builder.addArtifact({
    name: 'a-artifact',
    path: 'reports/a.json'
  });

  builder.addNote('note-b');
  builder.addNote('note-a');
  builder.addNote('');

  builder.setExtra('zeta', 2);
  builder.setExtra('alpha', 1);

  return builder;
}

function select<T>(value: T | undefined | null): T {
  assert.ok(value !== undefined && value !== null, 'expected value to be present');
  return value;
}

describe('SessionIndexBuilder', () => {
  it('normalizes and sorts session index data consistently', () => {
    const builder = createBuilderWithData();
    const index = builder.build();

    const toggles = select(index.environment?.toggles);
    assert.equal(toggles.schema, 'agent-toggle-values/v1');
    assert.equal(toggles.schemaVersion, '1.0.0');
    assert.equal(toggles.generatedAtUtc, '2025-01-01T00:00:00Z');
    assert.deepStrictEqual(toggles.profiles, ['ci-orchestrated', 'dev-workstation']);
    assert.deepStrictEqual(toggles.context?.tags, ['alpha', 'zeta']);
    assert.deepStrictEqual(Object.keys(toggles.values), ['A_TOGGLE', 'Z_TOGGLE']);

    const custom = select(index.environment?.custom);
    assert.deepStrictEqual(custom, {
      aKey: 'alpha',
      zKey: 'zeta'
    });

    const branchProtection = select(index.branchProtection);
    assert.deepStrictEqual(branchProtection.expected, [
      'Validate / lint',
      'Validate / session-index'
    ]);
    assert.deepStrictEqual(branchProtection.produced, [
      'Validate / fixtures',
      'Validate / lint',
      'Validate / session-index'
    ]);
    assert.deepStrictEqual(branchProtection.notes, [
      'beta',
      'delta',
      'first note',
      'second note'
    ]);
    assert.deepStrictEqual(branchProtection.actual?.contexts, ['Validate', 'Workflows Lint']);

    assert.deepStrictEqual(index.notes, ['note-a', 'note-b']);

    const cases = index.tests?.cases ?? [];
    assert.deepStrictEqual(
      cases.map((testCase) => testCase.id),
      ['test-a', 'test-b', 'test-c']
    );
    const fallbackCase = cases.find((testCase) => testCase.id === 'test-c');
    assert.ok(fallbackCase);
    assert.equal(fallbackCase?.requirement, 'test-c');

    assert.deepStrictEqual(
      index.artifacts?.map((artifact) => `${artifact.name}:${artifact.path}`),
      ['a-artifact:reports/a.json', 'a-artifact:reports/b.json', 'z-artifact:reports/z.json']
    );

    assert.deepStrictEqual(index.extra, {
      alpha: 1,
      zeta: 2
    });

    const branchState = select(index.run.branchState);
    assert.equal(branchState.summary, 'Branch feature/in-flight: ahead 1 of origin/develop');
    assert.equal(branchState.timestampUtc, '2025-01-01T12:00:00Z');
    assert.equal(branchState.branch, 'feature/in-flight');
    assert.equal(branchState.upstream, 'origin/develop');
    assert.equal(branchState.ahead, 1);
    assert.equal(branchState.behind, 0);
    assert.equal(branchState.hasUpstream, true);
    assert.equal(branchState.isClean, false);
    assert.equal(branchState.hasUntracked, true);
  });

  it('returns deterministic output when build() is called multiple times', () => {
    const builder = createBuilderWithData();
    const first = builder.build();
    const firstJson = JSON.stringify(first);

    const second = builder.build();
    assert.deepStrictEqual(second, first);
    assert.equal(JSON.stringify(second), firstJson);
  });
});
