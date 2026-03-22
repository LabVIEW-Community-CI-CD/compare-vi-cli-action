import test from 'node:test';
import assert from 'node:assert/strict';
import { run } from '../check-policy.mjs';

function createResponse(data, status = 200, statusText = 'OK') {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText,
    async json() {
      return data === null ? null : structuredClone(data);
    },
    async text() {
      if (data === null || data === undefined) {
        return '';
      }
      return typeof data === 'string' ? data : JSON.stringify(data);
    }
  };
}

const manifestOverride = {
  repo: {
    allow_squash_merge: true,
    allow_merge_commit: false,
    allow_rebase_merge: true,
    allow_auto_merge: true,
    delete_branch_on_merge: true
  },
  forkProfile: {
    branches: {
      develop: {
        allow_force_pushes: true,
        allow_fork_syncing: false
      }
    },
    rulesets: {
      '8614172': {
        enabled: false
      }
    }
  },
  branches: {
    develop: {
      required_status_checks_strict: true,
      required_status_checks: ['lint', 'commit-integrity'],
      required_linear_history: true,
      enforce_admins: false,
      required_pull_request_reviews: null,
      restrictions: null,
      allow_force_pushes: false,
      allow_deletions: false,
      block_creations: false,
      required_conversation_resolution: false,
      lock_branch: false,
      allow_fork_syncing: false
    },
    main: {
      required_status_checks_strict: true,
      required_status_checks: ['lint'],
      required_linear_history: true,
      enforce_admins: false,
      required_pull_request_reviews: null,
      restrictions: null,
      allow_force_pushes: false,
      allow_deletions: false,
      block_creations: false,
      required_conversation_resolution: false,
      lock_branch: false,
      allow_fork_syncing: false
    }
  },
  rulesets: {
    '8811898': {
      name: 'develop',
      includes: ['refs/heads/develop'],
      required_linear_history: true,
      required_status_checks: ['lint', 'commit-integrity'],
      merge_queue: null,
      pull_request: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ['squash', 'rebase']
      }
    },
    '8614140': {
      name: 'main',
      includes: ['refs/heads/main'],
      required_status_checks: ['lint'],
      merge_queue: null,
      pull_request: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ['squash', 'rebase']
      }
    },
    '8614172': {
      name: 'release',
      includes: ['refs/heads/release/*'],
      required_status_checks: ['lint', 'publish'],
      merge_queue: null,
      pull_request: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        allowed_merge_methods: ['rebase']
      }
    }
  }
};

const branchRequiredChecksOverride = {
  schema: 'branch-required-checks/v1',
  schemaVersion: '1.0.0',
  branchClassBindings: {
    develop: 'fork-mirror',
    main: 'upstream-release',
    'release/*': 'upstream-release-prep'
  },
  branchClassRequiredChecks: {
    'fork-mirror': ['lint', 'commit-integrity'],
    'upstream-release': ['lint'],
    'upstream-release-prep': ['lint', 'publish']
  },
  branches: {
    develop: ['lint', 'commit-integrity'],
    main: ['lint'],
    'release/*': ['lint', 'publish']
  },
  observed: {
    develop: [],
    main: []
  }
};

function createBranchProtection(requiredChecks, { allowForcePushes = false, allowForkSyncing = false } = {}) {
  return {
    required_status_checks: {
      strict: true,
      contexts: [...requiredChecks],
      checks: requiredChecks.map((context) => ({ context }))
    },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: { enabled: true },
    allow_force_pushes: { enabled: allowForcePushes },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: allowForkSyncing }
  };
}

function createRuleset({
  id,
  name,
  includes,
  enforcement = 'active',
  requiredLinearHistory = false,
  requiredStatusChecks,
  pullRequest
}) {
  const rules = [];
  if (requiredLinearHistory) {
    rules.push({ type: 'required_linear_history' });
  }
  if (requiredStatusChecks) {
    rules.push({
      type: 'required_status_checks',
      parameters: {
        strict_required_status_checks_policy: true,
        do_not_enforce_on_create: false,
        required_status_checks: requiredStatusChecks.map((context) => ({ context }))
      }
    });
  }
  if (pullRequest) {
    rules.push({
      type: 'pull_request',
      parameters: structuredClone(pullRequest)
    });
  }
  return {
    id,
    name,
    target: 'branch',
    enforcement,
    conditions: {
      ref_name: {
        include: [...includes],
        exclude: []
      }
    },
    bypass_actors: [],
    rules
  };
}

test('priority:policy verify passes when a fork release ruleset is already disabled', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-fork';
  const rulesets = {
    develop: createRuleset({
      id: 8811898,
      name: 'develop',
      includes: ['refs/heads/develop'],
      requiredLinearHistory: true,
      requiredStatusChecks: ['lint', 'commit-integrity'],
      pullRequest: manifestOverride.rulesets['8811898'].pull_request
    }),
    main: createRuleset({
      id: 8614140,
      name: 'main',
      includes: ['refs/heads/main'],
      requiredStatusChecks: ['lint'],
      pullRequest: manifestOverride.rulesets['8614140'].pull_request
    }),
    release: createRuleset({
      id: 8614172,
      name: 'release',
      includes: ['refs/heads/release/*'],
      enforcement: 'disabled',
      requiredStatusChecks: ['lint', 'publish'],
      pullRequest: manifestOverride.rulesets['8614172'].pull_request
    })
  };

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse({
        allow_squash_merge: true,
        allow_merge_commit: false,
        allow_rebase_merge: true,
        allow_auto_merge: true,
        delete_branch_on_merge: true,
        fork: true,
        owner: { type: 'Organization', login: 'test-org' },
        permissions: { admin: true }
      });
    }
    if (method === 'GET' && url === `${repoUrl}/branches/develop/protection`) {
      return createResponse(createBranchProtection(['lint', 'commit-integrity'], { allowForcePushes: true }));
    }
    if (method === 'GET' && url === `${repoUrl}/branches/main/protection`) {
      return createResponse(createBranchProtection(['lint']));
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8811898`) {
      return createResponse(rulesets.develop);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614140`) {
      return createResponse(rulesets.main);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614172`) {
      return createResponse(rulesets.release);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets`) {
      return createResponse(Object.values(rulesets).map((ruleset) => ({
        id: ruleset.id,
        name: ruleset.name,
        target: ruleset.target,
        enforcement: ruleset.enforcement
      })));
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const code = await run({
    argv: ['node', 'check-policy.mjs'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-fork',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    manifestOverride,
    branchRequiredChecksOverride,
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0);
});

test('priority:policy --apply disables an active fork release ruleset instead of recreating protection drift', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-fork';
  let releaseRuleset = createRuleset({
    id: 8614172,
    name: 'release',
    includes: ['refs/heads/release/*'],
    enforcement: 'active',
    requiredStatusChecks: ['lint', 'publish'],
    pullRequest: manifestOverride.rulesets['8614172'].pull_request
  });
  const rulesets = {
    develop: createRuleset({
      id: 8811898,
      name: 'develop',
      includes: ['refs/heads/develop'],
      requiredLinearHistory: true,
      requiredStatusChecks: ['lint', 'commit-integrity'],
      pullRequest: manifestOverride.rulesets['8811898'].pull_request
    }),
    main: createRuleset({
      id: 8614140,
      name: 'main',
      includes: ['refs/heads/main'],
      requiredStatusChecks: ['lint'],
      pullRequest: manifestOverride.rulesets['8614140'].pull_request
    })
  };
  const appliedPayloads = [];

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse({
        allow_squash_merge: true,
        allow_merge_commit: false,
        allow_rebase_merge: true,
        allow_auto_merge: true,
        delete_branch_on_merge: true,
        fork: true,
        owner: { type: 'Organization', login: 'test-org' },
        permissions: { admin: true }
      });
    }
    if (method === 'GET' && url === `${repoUrl}/branches/develop/protection`) {
      return createResponse(createBranchProtection(['lint', 'commit-integrity'], { allowForcePushes: true }));
    }
    if (method === 'GET' && url === `${repoUrl}/branches/main/protection`) {
      return createResponse(createBranchProtection(['lint']));
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8811898`) {
      return createResponse(rulesets.develop);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614140`) {
      return createResponse(rulesets.main);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614172`) {
      return createResponse(releaseRuleset);
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets`) {
      return createResponse([
        rulesets.develop,
        rulesets.main,
        releaseRuleset
      ].map((ruleset) => ({
        id: ruleset.id,
        name: ruleset.name,
        target: ruleset.target,
        enforcement: ruleset.enforcement
      })));
    }
    if (method === 'PUT' && url === `${repoUrl}/rulesets/8614172`) {
      const payload = typeof options.body === 'string' ? JSON.parse(options.body) : structuredClone(options.body);
      appliedPayloads.push(payload);
      releaseRuleset = {
        ...releaseRuleset,
        enforcement: payload.enforcement
      };
      return createResponse(releaseRuleset);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const code = await run({
    argv: ['node', 'check-policy.mjs', '--apply'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-fork',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    manifestOverride,
    branchRequiredChecksOverride,
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0);
  assert.equal(appliedPayloads.length, 1);
  assert.equal(appliedPayloads[0].enforcement, 'disabled');
});
