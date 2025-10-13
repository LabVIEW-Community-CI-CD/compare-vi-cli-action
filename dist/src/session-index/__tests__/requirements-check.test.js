import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { evaluateRequirements, formatViolationMessage, hasErrorViolations } from '../requirements-check.js';
const baseIndex = {
    schema: 'session-index/v2',
    schemaVersion: '2.0.0',
    generatedAtUtc: '2025-01-01T00:00:00Z',
    run: {
        workflow: 'Validate'
    }
};
function cloneIndex() {
    return JSON.parse(JSON.stringify(baseIndex));
}
describe('requirements-check', () => {
    it('reports missing required fields', () => {
        const requirements = [
            {
                id: 'session-index.v2.workflow',
                description: 'Run workflow must be present',
                path: 'run.workflow',
                rule: 'required',
                severity: 'error'
            }
        ];
        const index = cloneIndex();
        const record = index;
        delete record.run.workflow;
        const violations = evaluateRequirements(index, requirements);
        assert.equal(violations.length, 1);
        assert.ok(hasErrorViolations(violations));
        const message = formatViolationMessage(violations[0]);
        assert.match(message, /ERROR: \[session-index\.v2\.workflow]/);
    });
    it('reports non-empty array requirements with warning severity', () => {
        const requirements = [
            {
                id: 'session-index.v2.tests.cases',
                description: 'Test cases should be emitted',
                path: 'tests.cases',
                rule: 'nonEmptyArray',
                severity: 'warning'
            }
        ];
        const index = cloneIndex();
        const violations = evaluateRequirements(index, requirements);
        assert.equal(violations.length, 1);
        assert.equal(hasErrorViolations(violations), false);
        const message = formatViolationMessage(violations[0]);
        assert.match(message, /WARN: \[session-index\.v2\.tests\.cases]/);
    });
    it('ensures every case has the required field', () => {
        const requirements = [
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
        const violations = evaluateRequirements(index, requirements);
        assert.equal(violations.length, 1);
        assert.ok(hasErrorViolations(violations));
    });
    it('passes when all requirements are satisfied', () => {
        const requirements = [
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
        const index = {
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
