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

test('priority:policy --apply updates rulesets for develop/main/release', async () => {
  const expectedDevelopChecks = [
    'Validate / lint',
    'Validate / fixtures',
    'Validate / session-index',
    'Validate / issue-snapshot',
    'Policy Guard (Upstream) / policy-guard'
  ];
  const expectedMainChecks = [
    'pester',
    'vi-binary-check',
    'vi-compare',
    'Policy Guard (Upstream) / policy-guard'
  ];
  const expectedReleaseChecks = [
    'pester',
    'publish',
    'vi-binary-check',
    'vi-compare',
    'mock-cli',
    'Policy Guard (Upstream) / policy-guard'
  ];

  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;

  const repoState = {
    allow_squash_merge: true,
    allow_merge_commit: false,
    allow_rebase_merge: true,
    allow_auto_merge: true,
    delete_branch_on_merge: true
  };

  const rulesetDevelop = {
    id: 8811898,
    name: 'develop',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/develop'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: [
      {
        type: 'required_status_checks',
        parameters: {
          strict_required_status_checks_policy: true,
          do_not_enforce_on_create: true,
          required_status_checks: [
            { context: 'Validate / lint', integration_id: 15368 },
            { context: 'Validate / fixtures', integration_id: 15368 },
            { context: 'Validate / session-index', integration_id: 15368 },
            { context: 'Validate / issue-snapshot', integration_id: 15368 },
            { context: 'Policy Guard (Upstream) / policy-guard' }
          ]
        }
      },
      {
        type: 'pull_request',
        parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false,
          allowed_merge_methods: ['merge']
        }
      }
    ]
  };

  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/main'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: [
      {
        type: 'merge_queue',
        parameters: {
          merge_method: 'SQUASH',
          grouping_strategy: 'ALLGREEN',
          max_entries_to_build: 5,
          min_entries_to_merge: 1,
          max_entries_to_merge: 5,
          min_entries_to_merge_wait_minutes: 1,
          check_response_timeout_minutes: 60
        }
      },
      {
        type: 'pull_request',
        parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false,
          allowed_merge_methods: ['merge']
        }
      },
      {
        type: 'required_status_checks',
        parameters: {
          strict_required_status_checks_policy: true,
          do_not_enforce_on_create: false,
          required_status_checks: [
            { context: 'pester', integration_id: 15368 },
            { context: 'vi-binary-check', integration_id: 15368 },
            { context: 'vi-compare', integration_id: 15368 },
            { context: 'Policy Guard (Upstream) / policy-guard' }
          ]
        }
      }
    ]
  };

  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/release/*'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: [
      { type: 'deletion' },
      { type: 'non_fast_forward' },
      {
        type: 'pull_request',
        parameters: {
          required_approving_review_count: 1,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: true,
          allowed_merge_methods: ['merge']
        }
      },
      {
        type: 'required_status_checks',
        parameters: {
          strict_required_status_checks_policy: true,
          do_not_enforce_on_create: false,
          required_status_checks: [
            { context: 'pester', integration_id: 15368 },
            { context: 'publish', integration_id: 15368 },
            { context: 'vi-binary-check', integration_id: 15368 },
            { context: 'vi-compare', integration_id: 15368 },
            { context: 'mock-cli', integration_id: 15368 },
            { context: 'Policy Guard (Upstream) / policy-guard' }
          ]
        }
      }
    ]
  };

  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const branchReleaseUrl = `${repoUrl}/branches/release%2Fv0.5.2/protection`;

  let branchDevelopProtection = {
    required_status_checks: {
      strict: true,
      contexts: [
        'Validate / lint',
        'Validate / fixtures',
        'Validate / session-index',
        'Validate / issue-snapshot'
      ],
      checks: [
        { context: 'Validate / lint', app_id: 15368 },
        { context: 'Validate / fixtures', app_id: 15368 },
        { context: 'Validate / session-index', app_id: 15368 },
        { context: 'Validate / issue-snapshot', app_id: 15368 }
      ]
    },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: { enabled: false },
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  let branchMainProtection = {
    required_status_checks: {
      strict: true,
      contexts: ['pester', 'vi-binary-check', 'vi-compare'],
      checks: [
        { context: 'pester', app_id: 15368 },
        { context: 'vi-binary-check', app_id: 15368 },
        { context: 'vi-compare', app_id: 15368 }
      ]
    },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: { enabled: false },
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  let branchReleaseProtection = {
    required_status_checks: {
      strict: true,
      contexts: ['pester', 'publish', 'vi-binary-check', 'vi-compare', 'mock-cli'],
      checks: [
        { context: 'pester', app_id: 15368 },
        { context: 'publish', app_id: 15368 },
        { context: 'vi-binary-check', app_id: 15368 },
        { context: 'vi-compare', app_id: 15368 },
        { context: 'mock-cli', app_id: 15368 }
      ]
    },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: { enabled: false },
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  const wrapEnabled = (value) => ({ enabled: Boolean(value) });
  const requests = [];
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    requests.push({ method, url, body: options.body });

    if (method === 'GET' && url === repoUrl) {
      return createResponse(repoState);
    }

    if (url === branchDevelopUrl) {
      if (method === 'GET') {
        return createResponse(branchDevelopProtection);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        const contexts = payload.required_status_checks?.contexts ?? [];
        branchDevelopProtection = {
          enforce_admins: wrapEnabled(payload.enforce_admins),
          required_pull_request_reviews: payload.required_pull_request_reviews,
          restrictions: payload.restrictions,
          required_status_checks: {
            strict: payload.required_status_checks?.strict ?? true,
            contexts,
            checks: contexts.map((context) => ({ context }))
          },
          required_linear_history: wrapEnabled(payload.required_linear_history),
          allow_force_pushes: wrapEnabled(payload.allow_force_pushes),
          allow_deletions: wrapEnabled(payload.allow_deletions),
          block_creations: wrapEnabled(payload.block_creations),
          required_conversation_resolution: wrapEnabled(payload.required_conversation_resolution),
          lock_branch: wrapEnabled(payload.lock_branch),
          allow_fork_syncing: wrapEnabled(payload.allow_fork_syncing)
        };
        return createResponse(branchDevelopProtection);
      }
    }

    if (url === branchMainUrl) {
      if (method === 'GET') {
        return createResponse(branchMainProtection);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        const contexts = payload.required_status_checks?.contexts ?? [];
        branchMainProtection = {
          enforce_admins: wrapEnabled(payload.enforce_admins),
          required_pull_request_reviews: payload.required_pull_request_reviews,
          restrictions: payload.restrictions,
          required_status_checks: {
            strict: payload.required_status_checks?.strict ?? true,
            contexts,
            checks: contexts.map((context) => ({ context }))
          },
          required_linear_history: wrapEnabled(payload.required_linear_history),
          allow_force_pushes: wrapEnabled(payload.allow_force_pushes),
          allow_deletions: wrapEnabled(payload.allow_deletions),
          block_creations: wrapEnabled(payload.block_creations),
          required_conversation_resolution: wrapEnabled(payload.required_conversation_resolution),
          lock_branch: wrapEnabled(payload.lock_branch),
          allow_fork_syncing: wrapEnabled(payload.allow_fork_syncing)
        };
        return createResponse(branchMainProtection);
      }
    }

    if (url === branchReleaseUrl) {
      if (method === 'GET') {
        return createResponse(branchReleaseProtection);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        const contexts = payload.required_status_checks?.contexts ?? [];
        branchReleaseProtection = {
          enforce_admins: wrapEnabled(payload.enforce_admins),
          required_pull_request_reviews: payload.required_pull_request_reviews,
          restrictions: payload.restrictions,
          required_status_checks: {
            strict: payload.required_status_checks?.strict ?? true,
            contexts,
            checks: contexts.map((context) => ({ context }))
          },
          required_linear_history: wrapEnabled(payload.required_linear_history),
          allow_force_pushes: wrapEnabled(payload.allow_force_pushes),
          allow_deletions: wrapEnabled(payload.allow_deletions),
          block_creations: wrapEnabled(payload.block_creations),
          required_conversation_resolution: wrapEnabled(payload.required_conversation_resolution),
          lock_branch: wrapEnabled(payload.lock_branch),
          allow_fork_syncing: wrapEnabled(payload.allow_fork_syncing)
        };
        return createResponse(branchReleaseProtection);
      }
    }

    if (url === rulesetDevelopUrl) {
      if (method === 'GET') {
        return createResponse(rulesetDevelop);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        rulesetDevelop.conditions = structuredClone(payload.conditions);
        rulesetDevelop.rules = structuredClone(payload.rules);
        return createResponse(rulesetDevelop);
      }
    }
    if (url === rulesetMainUrl) {
      if (method === 'GET') {
        return createResponse(rulesetMain);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        rulesetMain.conditions = structuredClone(payload.conditions);
        rulesetMain.rules = structuredClone(payload.rules);
        return createResponse(rulesetMain);
      }
    }

    if (url === rulesetReleaseUrl) {
      if (method === 'GET') {
        return createResponse(rulesetRelease);
      }
      if (method === 'PUT') {
        const payload = JSON.parse(options.body);
        rulesetRelease.conditions = structuredClone(payload.conditions);
        rulesetRelease.rules = structuredClone(payload.rules);
        return createResponse(rulesetRelease);
      }
    }

    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const logMessages = [];
  const errorMessages = [];
  const code = await run({
    argv: ['node', 'check-policy.mjs', '--apply'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'run should exit cleanly');
  assert.deepEqual(
    rulesetDevelop.rules
      .find((rule) => rule.type === 'required_status_checks')
      .parameters.required_status_checks.map((item) => item.context),
    expectedDevelopChecks
  );
  assert.ok(
    rulesetDevelop.rules.some((rule) => rule.type === 'required_linear_history'),
    'required_linear_history rule expected on develop'
  );
  const developPullRule = rulesetDevelop.rules.find((rule) => rule.type === 'pull_request');
  assert.deepEqual(
    developPullRule.parameters.allowed_merge_methods.sort(),
    ['rebase', 'squash']
  );

  const mergeQueueRule = rulesetMain.rules.find((rule) => rule.type === 'merge_queue');
  assert.equal(mergeQueueRule.parameters.min_entries_to_merge_wait_minutes, 5);

  const statusRule = rulesetMain.rules.find((rule) => rule.type === 'required_status_checks');
  assert.deepEqual(
    statusRule.parameters.required_status_checks.map((check) => check.context).sort(),
    ['pester', 'vi-binary-check', 'vi-compare', 'Policy Guard (Upstream) / policy-guard'].sort()
  );

  const pullRule = rulesetMain.rules.find((rule) => rule.type === 'pull_request');
  assert.equal(pullRule.parameters.required_approving_review_count, 1);
  assert.equal(pullRule.parameters.required_review_thread_resolution, true);

  const statusRuleRelease = rulesetRelease.rules.find((rule) => rule.type === 'required_status_checks');
  assert.deepEqual(
    statusRuleRelease.parameters.required_status_checks.map((check) => check.context).sort(),
    ['Policy Guard (Upstream) / policy-guard', 'mock-cli', 'pester', 'publish', 'vi-binary-check', 'vi-compare'].sort()
  );

  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === rulesetDevelopUrl),
    'develop ruleset put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === rulesetMainUrl),
    'ruleset put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === branchDevelopUrl),
    'develop branch protection put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === branchMainUrl),
    'main branch protection put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === branchReleaseUrl),
    'release branch protection put call expected'
  );

  const developApplied = branchDevelopProtection.required_status_checks.checks.map((check) => check.context).sort();
  assert.deepEqual(
    developApplied,
    expectedDevelopChecks.slice().sort(),
    'develop branch contexts should match expectations'
  );

  const mainApplied = branchMainProtection.required_status_checks.checks.map((check) => check.context).sort();
  assert.deepEqual(
    mainApplied,
    expectedMainChecks.slice().sort(),
    'main branch contexts should match expectations'
  );

  const releaseApplied = branchReleaseProtection.required_status_checks.checks.map((check) => check.context).sort();
  assert.deepEqual(
    releaseApplied,
    expectedReleaseChecks.slice().sort(),
    'release branch contexts should match expectations'
  );
  assert.deepEqual(errorMessages, []);
  assert.ok(
    logMessages.includes('Merge policy apply completed successfully.'),
    'apply success message expected'
  );
});

test('priority:policy skips when repository settings require admin access', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const repoState = {
    permissions: {
      admin: false
    }
  };
  const rulesetDevelop = {
    id: 8811898,
    name: 'develop',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/develop'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: [
      {
        type: 'pull_request',
        parameters: {
          allowed_merge_methods: ['merge']
        }
      }
    ]
  };
  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/main'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: []
  };
  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    enforcement: 'active',
    conditions: {
      ref_name: {
        include: ['refs/heads/release/*'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: []
  };

  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse(repoState);
    }
    if (method === 'GET' && url === rulesetDevelopUrl) {
      return createResponse(rulesetDevelop);
    }
    if (method === 'GET' && url === rulesetMainUrl) {
      return createResponse(rulesetMain);
    }
    if (method === 'GET' && url === rulesetReleaseUrl) {
      return createResponse(rulesetRelease);
    }

    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const logMessages = [];
  const errorMessages = [];
  const code = await run({
    argv: ['node', 'check-policy.mjs'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'run should exit cleanly with skip');
  assert.ok(
    logMessages.some((msg) => msg.includes('skipping policy check')),
    'skip message expected when admin permissions unavailable'
  );
  assert.deepEqual(errorMessages, []);
});
