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
    'guard',
    'lint',
    'fixtures',
    'session-index',
    'issue-snapshot',
    'Workflows Lint / lint (pull_request)'
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
            { context: 'guard', integration_id: 15368 },
            { context: 'lint', integration_id: 15368 },
            { context: 'fixtures', integration_id: 15368 },
            { context: 'session-index', integration_id: 15368 }
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
            { context: 'lint', integration_id: 15368 },
            { context: 'pester', integration_id: 15368 },
            { context: 'vi-binary-check', integration_id: 15368 }
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
            { context: 'lint', integration_id: 15368 },
            { context: 'pester', integration_id: 15368 },
            { context: 'publish', integration_id: 15368 },
            { context: 'vi-binary-check', integration_id: 15368 },
            { context: 'vi-compare', integration_id: 15368 },
            { context: 'mock-cli', integration_id: 15368 }
          ]
        }
      }
    ]
  };

  const requests = [];
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    requests.push({ method, url, body: options.body });

    if (method === 'GET' && url === repoUrl) {
      return createResponse(repoState);
    }

    if (url === rulesetDevelopUrl) {
      if (method === 'GET') {
        return createResponse(rulesetDevelop);
      }
      if (method === 'PATCH') {
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
      if (method === 'PATCH') {
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
      if (method === 'PATCH') {
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
    developPullRule.parameters.allowed_merge_methods,
    ['squash']
  );

  const mergeQueueRule = rulesetMain.rules.find((rule) => rule.type === 'merge_queue');
  assert.equal(mergeQueueRule.parameters.min_entries_to_merge_wait_minutes, 5);

  const statusRule = rulesetMain.rules.find((rule) => rule.type === 'required_status_checks');
  assert.deepEqual(
    statusRule.parameters.required_status_checks.map((check) => check.context),
    ['lint', 'pester', 'vi-binary-check', 'vi-compare']
  );

  const pullRule = rulesetMain.rules.find((rule) => rule.type === 'pull_request');
  assert.equal(pullRule.parameters.required_approving_review_count, 1);
  assert.equal(pullRule.parameters.required_review_thread_resolution, true);

  assert.ok(
    requests.some((entry) => entry.method === 'PATCH' && entry.url === rulesetDevelopUrl),
    'develop ruleset patch call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PATCH' && entry.url === rulesetMainUrl),
    'ruleset patch call expected'
  );
  assert.deepEqual(errorMessages, []);
  assert.ok(
    logMessages.includes('Merge policy apply completed successfully.'),
    'apply success message expected'
  );
});
