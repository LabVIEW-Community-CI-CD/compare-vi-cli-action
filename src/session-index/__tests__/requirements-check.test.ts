import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  evaluateRequirements,
  formatViolationMessage,
  hasErrorViolations
} from '../requirements-check.js';
import type { SessionIndexRequirement } from '../requirements.js';
import type { SessionIndexV2 } from '../schema.js';

const baseIndex: SessionIndexV2 = {
  schema: 'session-index/v2',
  schemaVersion: '2.0.0',
  generatedAtUtc: '2025-01-01T00:00:00Z',
  run: {
    workflow: 'Validate'
  }
};

function cloneIndex(): SessionIndexV2 {
  return JSON.parse(JSON.stringify(baseIndex)) as SessionIndexV2;
}

describe('requirements-check', () => {
  it('reports missing required fields', () => {
    const requirements: SessionIndexRequirement[] = [
      {
        id: 'session-index.v2.workflow',
        description: 'Run workflow must be present',
        path: 'run.workflow',
        rule: 'required',
        severity: 'error'
      }
    ];

    const index = cloneIndex();
    const record = index as unknown as Record<string, unknown>;
    delete (record.run as Record<string, unknown>).workflow;

    const violations = evaluateRequirements(index as unknown as Record<string, unknown>, requirements);
    assert.equal(violations.length, 1);
    assert.ok(hasErrorViolations(violations));

    const message = formatViolationMessage(violations[0]);
    assert.match(message, /ERROR: \[session-index\.v2\.workflow]/);
  });

  it('reports non-empty array requirements with warning severity', () => {
    const requirements: SessionIndexRequirement[] = [
      {
        id: 'session-index.v2.tests.cases',
        description: 'Test cases should be emitted',
        path: 'tests.cases',
        rule: 'nonEmptyArray',
        severity: 'warning'
      }
    ];

    const index = cloneIndex();

    const violations = evaluateRequirements(index as unknown as Record<string, unknown>, requirements);
    assert.equal(violations.length, 1);
    assert.equal(hasErrorViolations(violations), false);

    const message = formatViolationMessage(violations[0]);
    assert.match(message, /WARN: \[session-index\.v2\.tests\.cases]/);
  });

  it('ensures every case has the required field', () => {
    const requirements: SessionIndexRequirement[] = [
      {
        id: 'session-index.v2.tests.cases.requirement',
        description: 'Each test case requires a requirement id',
        path: 'tests.cases',
        rule: 'everyCaseHas',
        severity: 'error',
        field: 'requirement'
      }
    ];

    const index = cloneIndex();
    index.tests = {
      cases: [
        {
          id: 'case-1',
          outcome: 'passed',
          requirement: 'REQ-100'
        },
        {
          id: 'case-2',
          outcome: 'passed'
        }
      ]
    };

    const violations = evaluateRequirements(index as unknown as Record<string, unknown>, requirements);
    assert.equal(violations.length, 1);
    assert.ok(hasErrorViolations(violations));
  });

  it('passes when all requirements are satisfied', () => {
    const requirements: SessionIndexRequirement[] = [
      {
        id: 'session-index.v2.branchProtection.expected',
        description: 'branch protection expected contexts recorded',
        path: 'branchProtection.expected',
        rule: 'nonEmptyArray',
        severity: 'error'
      },
      {
        id: 'session-index.v2.tests.cases.requirement',
        description: 'cases provide requirements',
        path: 'tests.cases',
        rule: 'everyCaseHas',
        severity: 'error',
        field: 'requirement'
      }
    ];

    const index: Record<string, unknown> = {
      branchProtection: {
        expected: ['Validate / lint']
      },
      tests: {
        cases: [
          {
            id: 'Mini.passes',
            requirement: 'Mini.passes'
          }
        ]
      }
    };

    const violations = evaluateRequirements(index, requirements);
    assert.equal(violations.length, 0);
  });
});
