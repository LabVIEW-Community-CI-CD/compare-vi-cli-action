import test from 'node:test';
import assert from 'node:assert/strict';
import {
  resolveProjectedBranchClassId,
  resolveProjectedRequiredStatusChecks,
  projectManifestRequiredStatusChecks
} from '../lib/branch-required-check-projection.mjs';

const branchPolicy = {
  branchClassBindings: {
    develop: 'upstream-integration',
    main: 'upstream-release',
    'release/*': 'upstream-release-prep'
  },
  branchClassRequiredChecks: {
    'upstream-integration': ['lint', 'session-index'],
    'upstream-release': ['lint', 'pester'],
    'upstream-release-prep': ['publish', 'mock-cli']
  },
  branches: {
    develop: ['lint', 'session-index'],
    main: ['lint', 'pester']
  }
};

test('resolveProjectedBranchClassId honors branch-policy bindings and explicit matching class ids', () => {
  assert.equal(resolveProjectedBranchClassId(branchPolicy, 'develop', null), 'upstream-integration');
  assert.equal(resolveProjectedBranchClassId(branchPolicy, 'release/*', 'upstream-release-prep'), 'upstream-release-prep');
});

test('resolveProjectedRequiredStatusChecks falls back from explicit branch entries to branch-class projections', () => {
  assert.deepEqual(resolveProjectedRequiredStatusChecks(branchPolicy, 'develop'), ['lint', 'session-index']);
  assert.deepEqual(resolveProjectedRequiredStatusChecks(branchPolicy, 'release/*'), ['publish', 'mock-cli']);
});

test('projectManifestRequiredStatusChecks projects branch and ruleset required checks from branch policy', () => {
  const manifest = {
    branches: {
      develop: {
        branch_class_id: 'upstream-integration',
        required_status_checks_strict: true
      },
      'release/*': {
        branch_class_id: 'upstream-release-prep'
      }
    },
    rulesets: {
      develop: {
        branch_class_id: 'upstream-integration',
        includes: ['refs/heads/develop']
      },
      '8614172': {
        branch_class_id: 'upstream-release-prep',
        includes: ['refs/heads/release/*']
      }
    }
  };

  const projected = projectManifestRequiredStatusChecks(manifest, branchPolicy);
  assert.deepEqual(projected.branches.develop.required_status_checks, ['lint', 'session-index']);
  assert.deepEqual(projected.branches['release/*'].required_status_checks, ['publish', 'mock-cli']);
  assert.deepEqual(projected.rulesets.develop.required_status_checks, ['lint', 'session-index']);
  assert.deepEqual(projected.rulesets['8614172'].required_status_checks, ['publish', 'mock-cli']);
});

test('projectManifestRequiredStatusChecks fails closed when explicit checks drift from the branch-policy projection', () => {
  assert.throws(
    () => projectManifestRequiredStatusChecks(
      {
        branches: {
          develop: {
            branch_class_id: 'upstream-integration',
            required_status_checks: ['lint']
          }
        },
        rulesets: {}
      },
      branchPolicy
    ),
    /required_status_checks drift/
  );
});
