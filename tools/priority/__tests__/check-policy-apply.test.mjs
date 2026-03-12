import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { run, __test } from '../check-policy.mjs';

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

const EXPECTED_DEVELOP_CHECKS = [
  'lint',
  'fixtures',
  'session-index',
  'issue-snapshot',
  'semver',
  'Policy Guard (Upstream) / policy-guard',
  'vi-history-scenarios-linux',
  'agent-review-policy',
  'commit-integrity'
];

const EXPECTED_MAIN_CHECKS = [
  'lint',
  'pester',
  'vi-binary-check',
  'vi-compare',
  'Policy Guard (Upstream) / policy-guard',
  'commit-integrity'
];

const EXPECTED_RELEASE_CHECKS = [
  'lint',
  'pester',
  'publish',
  'vi-binary-check',
  'vi-compare',
  'mock-cli',
  'Policy Guard (Upstream) / policy-guard'
];

const EXPECTED_MERGE_QUEUE_PARAMS = {
  merge_method: 'SQUASH',
  grouping_strategy: 'ALLGREEN',
  max_entries_to_build: 5,
  min_entries_to_merge: 1,
  max_entries_to_merge: 5,
  min_entries_to_merge_wait_minutes: 1,
  check_response_timeout_minutes: 60
};

function createAlignedRepoState(overrides = {}) {
  return {
    allow_squash_merge: true,
    allow_merge_commit: false,
    allow_rebase_merge: true,
    allow_auto_merge: true,
    delete_branch_on_merge: true,
    ...overrides
  };
}

function createAlignedBranchProtection(requiredChecks) {
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
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };
}

function createPullRequestRule({
  dismissStaleReviewsOnPush = false,
  requiredReviewThreadResolution = false,
  allowedMergeMethods = ['squash', 'rebase']
} = {}) {
  return {
    required_approving_review_count: 0,
    dismiss_stale_reviews_on_push: dismissStaleReviewsOnPush,
    require_code_owner_review: false,
    require_last_push_approval: false,
    required_review_thread_resolution: requiredReviewThreadResolution,
    allowed_merge_methods: [...allowedMergeMethods]
  };
}

function createRuleset({
  id,
  name,
  includes,
  requiredStatusChecks,
  mergeQueue = null,
  requiredLinearHistory = false,
  pullRequestRule,
  codeQuality = null,
  copilotCodeReview = null
}) {
  const rules = [];
  if (requiredLinearHistory) {
    rules.push({ type: 'required_linear_history' });
  }
  if (mergeQueue) {
    rules.push({ type: 'merge_queue', parameters: structuredClone(mergeQueue) });
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
  if (pullRequestRule) {
    rules.push({
      type: 'pull_request',
      parameters: structuredClone(pullRequestRule)
    });
  }
  if (codeQuality) {
    rules.push({
      type: 'code_quality',
      parameters: structuredClone(codeQuality)
    });
  }
  if (copilotCodeReview) {
    rules.push({
      type: 'copilot_code_review',
      parameters: structuredClone(copilotCodeReview)
    });
  }

  return {
    id,
    name,
    target: 'branch',
    enforcement: 'active',
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

function createAlignedRulesets(ids = { develop: 8811898, main: 8614140, release: 8614172 }) {
  return {
    develop: createRuleset({
      id: ids.develop,
      name: 'develop',
      includes: ['refs/heads/develop'],
      requiredStatusChecks: EXPECTED_DEVELOP_CHECKS,
      mergeQueue: EXPECTED_MERGE_QUEUE_PARAMS,
      requiredLinearHistory: true,
      pullRequestRule: createPullRequestRule(),
      codeQuality: { severity: 'warnings' },
      copilotCodeReview: {
        review_on_push: true,
        review_draft_pull_requests: false
      }
    }),
    main: createRuleset({
      id: ids.main,
      name: 'main',
      includes: ['refs/heads/main'],
      requiredStatusChecks: EXPECTED_MAIN_CHECKS,
      mergeQueue: EXPECTED_MERGE_QUEUE_PARAMS,
      pullRequestRule: createPullRequestRule()
    }),
    release: createRuleset({
      id: ids.release,
      name: 'release',
      includes: ['refs/heads/release/*'],
      requiredStatusChecks: EXPECTED_RELEASE_CHECKS,
      pullRequestRule: createPullRequestRule({
        dismissStaleReviewsOnPush: true,
        allowedMergeMethods: ['rebase']
      })
    })
  };
}

function toRulesetSummary(ruleset) {
  return {
    id: ruleset.id,
    name: ruleset.name,
    target: ruleset.target,
    enforcement: ruleset.enforcement
  };
}

test('priority:policy --apply updates rulesets for develop/main/release', async () => {
  const expectedDevelopChecks = [...EXPECTED_DEVELOP_CHECKS];
  const expectedMainChecks = [
    'lint',
    'pester',
    'vi-binary-check',
    'vi-compare',
    'Policy Guard (Upstream) / policy-guard',
    'commit-integrity'
  ];
  const expectedReleaseChecks = [
    'lint',
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
      },
      {
        type: 'copilot_code_review',
        parameters: {
          review_on_push: false,
          review_draft_pull_requests: true
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
            { context: 'lint', integration_id: 15368 },
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
      contexts: ['pester', 'vi-binary-check', 'vi-compare', 'Policy Guard (Upstream) / policy-guard'],
      checks: [
        { context: 'pester', app_id: 15368 },
        { context: 'vi-binary-check', app_id: 15368 },
        { context: 'vi-compare', app_id: 15368 },
        { context: 'Policy Guard (Upstream) / policy-guard' }
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
  const developMergeQueueRule = rulesetDevelop.rules.find((rule) => rule.type === 'merge_queue');
  assert.ok(developMergeQueueRule, 'merge_queue rule expected on develop');
  assert.equal(developMergeQueueRule.parameters.min_entries_to_merge_wait_minutes, 1);
  const developPullRule = rulesetDevelop.rules.find((rule) => rule.type === 'pull_request');
  assert.deepEqual(
    developPullRule.parameters.allowed_merge_methods.sort(),
    ['rebase', 'squash']
  );
  const developCodeQualityRule = rulesetDevelop.rules.find((rule) => rule.type === 'code_quality');
  assert.ok(developCodeQualityRule, 'code_quality rule expected on develop');
  assert.equal(developCodeQualityRule.parameters.severity, 'warnings');
  const developCopilotRule = rulesetDevelop.rules.find((rule) => rule.type === 'copilot_code_review');
  assert.ok(developCopilotRule, 'copilot_code_review rule expected on develop');
  assert.equal(developCopilotRule.parameters.review_on_push, true);
  assert.equal(developCopilotRule.parameters.review_draft_pull_requests, false);

  const mergeQueueRule = rulesetMain.rules.find((rule) => rule.type === 'merge_queue');
  assert.equal(mergeQueueRule.parameters.min_entries_to_merge_wait_minutes, 1);

  const statusRule = rulesetMain.rules.find((rule) => rule.type === 'required_status_checks');
  assert.deepEqual(
    statusRule.parameters.required_status_checks.map((check) => check.context).sort(),
    expectedMainChecks.slice().sort()
  );

  const pullRule = rulesetMain.rules.find((rule) => rule.type === 'pull_request');
  assert.equal(pullRule.parameters.required_approving_review_count, 0);
  assert.equal(pullRule.parameters.required_review_thread_resolution, false);

  const statusRuleRelease = rulesetRelease.rules.find((rule) => rule.type === 'required_status_checks');
  assert.deepEqual(
    statusRuleRelease.parameters.required_status_checks.map((check) => check.context).sort(),
    expectedReleaseChecks.slice().sort()
  );
  assert.ok(
    !statusRuleRelease.parameters.required_status_checks.some(
      (check) => check.context === 'Requirements Verification / requirements-verification'
    ),
    'release ruleset should not include requirements-verification check'
  );

  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === rulesetDevelopUrl),
    'develop ruleset put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === rulesetMainUrl),
    'ruleset put call expected'
  );
  const developRulesetPut = requests.find((entry) => entry.method === 'PUT' && entry.url === rulesetDevelopUrl);
  const mainRulesetPut = requests.find((entry) => entry.method === 'PUT' && entry.url === rulesetMainUrl);
  assert.ok(developRulesetPut?.body, 'develop ruleset payload should be captured');
  assert.ok(mainRulesetPut?.body, 'main ruleset payload should be captured');

  const developRulesetPayload = JSON.parse(developRulesetPut.body);
  const mainRulesetPayload = JSON.parse(mainRulesetPut.body);
  const developCommitIntegrityCheck = developRulesetPayload.rules
    .find((rule) => rule.type === 'required_status_checks')
    .parameters.required_status_checks.find((check) => check.context === 'commit-integrity');
  const developPayloadCodeQualityRule = developRulesetPayload.rules.find((rule) => rule.type === 'code_quality');
  const developPayloadCopilotRule = developRulesetPayload.rules.find((rule) => rule.type === 'copilot_code_review');
  const mainCommitIntegrityCheck = mainRulesetPayload.rules
    .find((rule) => rule.type === 'required_status_checks')
    .parameters.required_status_checks.find((check) => check.context === 'commit-integrity');
  assert.ok(developPayloadCodeQualityRule, 'develop payload should include code_quality rule');
  assert.equal(developPayloadCodeQualityRule.parameters.severity, 'warnings');
  assert.ok(developPayloadCopilotRule, 'develop payload should include copilot_code_review rule');
  assert.equal(developPayloadCopilotRule.parameters.review_on_push, true);
  assert.equal(developPayloadCopilotRule.parameters.review_draft_pull_requests, false);
  assert.ok(developCommitIntegrityCheck, 'develop ruleset should include commit-integrity required check');
  assert.ok(mainCommitIntegrityCheck, 'main ruleset should include commit-integrity required check');
  assert.equal(
    Object.prototype.hasOwnProperty.call(developCommitIntegrityCheck, 'integration_id'),
    false,
    'new commit-integrity context should omit integration_id in develop ruleset payload'
  );
  assert.equal(
    Object.prototype.hasOwnProperty.call(mainCommitIntegrityCheck, 'integration_id'),
    false,
    'new commit-integrity context should omit integration_id in main ruleset payload'
  );

  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === branchDevelopUrl),
    'develop branch protection put call expected'
  );
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === branchMainUrl),
    'main branch protection put call expected'
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

  assert.deepEqual(errorMessages, []);
  assert.ok(
    logMessages.includes('Merge policy apply completed successfully.'),
    'apply success message expected'
  );
});

test('priority:policy verifies fork-local rulesets by stable identity when manifest ids are missing', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const expectedRulesetUrls = {
    develop: `${repoUrl}/rulesets/8811898`,
    main: `${repoUrl}/rulesets/8614140`,
    release: `${repoUrl}/rulesets/8614172`
  };
  const rulesets = createAlignedRulesets({
    develop: 99001,
    main: 99002,
    release: 99003
  });

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method !== 'GET') {
      throw new Error(`Unexpected request ${method} ${url}`);
    }
    if (url === repoUrl) {
      return createResponse(createAlignedRepoState());
    }
    if (url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (url === expectedRulesetUrls.develop || url === expectedRulesetUrls.main || url === expectedRulesetUrls.release) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (url === listUrl) {
      return createResponse([
        toRulesetSummary(rulesets.develop),
        toRulesetSummary(rulesets.main),
        toRulesetSummary(rulesets.release)
      ]);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.develop.id}`) {
      return createResponse(rulesets.develop);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.main.id}`) {
      return createResponse(rulesets.main);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.release.id}`) {
      return createResponse(rulesets.release);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const logMessages = [];
  const errorMessages = [];
  const code = await run({
    argv: ['node', 'check-policy.mjs'],
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

  assert.equal(code, 0, 'verify mode should pass with fork-local ruleset ids');
  assert.deepEqual(errorMessages, []);
  assert.ok(
    logMessages.some((msg) => msg.includes('ruleset 8811898: resolved by stable identity to 99001')),
    'develop ruleset should resolve by identity'
  );
  assert.ok(
    logMessages.some((msg) => msg.includes('ruleset 8614140: resolved by stable identity to 99002')),
    'main ruleset should resolve by identity'
  );
  assert.ok(
    logMessages.some((msg) => msg.includes('ruleset 8614172: resolved by stable identity to 99003')),
    'release ruleset should resolve by identity'
  );
});

test('priority:policy --apply updates fork-local rulesets resolved by stable identity', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const expectedRulesetUrls = {
    develop: `${repoUrl}/rulesets/8811898`,
    main: `${repoUrl}/rulesets/8614140`,
    release: `${repoUrl}/rulesets/8614172`
  };
  const rulesets = createAlignedRulesets({
    develop: 99101,
    main: 99102,
    release: 99103
  });
  rulesets.develop.conditions.ref_name.include = ['refs/heads/develop-drifted'];
  rulesets.develop.rules = rulesets.develop.rules.filter(
    (rule) => !['required_linear_history', 'merge_queue', 'code_quality', 'copilot_code_review'].includes(rule.type)
  );
  rulesets.develop.rules.find((rule) => rule.type === 'required_status_checks').parameters.required_status_checks =
    EXPECTED_DEVELOP_CHECKS.filter((context) => context !== 'commit-integrity').map((context) => ({ context }));
  rulesets.develop.rules.find((rule) => rule.type === 'pull_request').parameters.allowed_merge_methods = ['merge'];

  rulesets.main.rules.find((rule) => rule.type === 'required_status_checks').parameters.required_status_checks =
    EXPECTED_MAIN_CHECKS.filter((context) => context !== 'commit-integrity').map((context) => ({ context }));
  rulesets.main.rules.find((rule) => rule.type === 'pull_request').parameters.allowed_merge_methods = ['merge'];

  rulesets.release.rules.find((rule) => rule.type === 'required_status_checks').parameters.required_status_checks =
    EXPECTED_RELEASE_CHECKS.filter((context) => context !== 'mock-cli').map((context) => ({ context }));
  rulesets.release.rules.find((rule) => rule.type === 'pull_request').parameters.allowed_merge_methods = ['merge'];

  const requests = [];
  const updateRuleset = (current, payload) => ({
    ...current,
    name: payload.name,
    target: payload.target,
    enforcement: payload.enforcement,
    conditions: structuredClone(payload.conditions),
    bypass_actors: structuredClone(payload.bypass_actors),
    rules: structuredClone(payload.rules)
  });

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    requests.push({ method, url, body: options.body });
    if (method === 'GET' && url === repoUrl) {
      return createResponse(createAlignedRepoState());
    }
    if (method === 'GET' && url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (method === 'GET' && url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (method === 'GET' && (url === expectedRulesetUrls.develop || url === expectedRulesetUrls.main || url === expectedRulesetUrls.release)) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === listUrl) {
      return createResponse([
        toRulesetSummary(rulesets.develop),
        toRulesetSummary(rulesets.main),
        toRulesetSummary(rulesets.release)
      ]);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.develop.id}`) {
      if (method === 'GET') {
        return createResponse(rulesets.develop);
      }
      if (method === 'PUT') {
        rulesets.develop = updateRuleset(rulesets.develop, JSON.parse(options.body));
        return createResponse(rulesets.develop);
      }
    }
    if (url === `${repoUrl}/rulesets/${rulesets.main.id}`) {
      if (method === 'GET') {
        return createResponse(rulesets.main);
      }
      if (method === 'PUT') {
        rulesets.main = updateRuleset(rulesets.main, JSON.parse(options.body));
        return createResponse(rulesets.main);
      }
    }
    if (url === `${repoUrl}/rulesets/${rulesets.release.id}`) {
      if (method === 'GET') {
        return createResponse(rulesets.release);
      }
      if (method === 'PUT') {
        rulesets.release = updateRuleset(rulesets.release, JSON.parse(options.body));
        return createResponse(rulesets.release);
      }
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

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
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0, 'apply mode should update fork-local rulesets resolved by identity');
  assert.ok(
    requests.some((entry) => entry.method === 'PUT' && entry.url === `${repoUrl}/rulesets/${rulesets.develop.id}`),
    'develop ruleset should be updated using the fork-local id'
  );
  assert.ok(
    !requests.some((entry) => entry.method === 'PUT' && entry.url === expectedRulesetUrls.develop),
    'develop ruleset should not use the upstream manifest id once identity is resolved'
  );
  assert.deepEqual(
    rulesets.develop.conditions.ref_name.include,
    ['refs/heads/develop'],
    'develop ruleset should repair include drift on the existing fork-local ruleset'
  );
  assert.ok(
    rulesets.develop.rules.some((rule) => rule.type === 'required_linear_history'),
    'develop ruleset should restore required_linear_history'
  );
  assert.ok(
    rulesets.develop.rules.some((rule) => rule.type === 'merge_queue'),
    'develop ruleset should restore merge_queue'
  );
  assert.ok(
    rulesets.develop.rules.some((rule) => rule.type === 'code_quality'),
    'develop ruleset should restore code_quality'
  );
  assert.ok(
    rulesets.develop.rules.some((rule) => rule.type === 'copilot_code_review'),
    'develop ruleset should restore copilot_code_review'
  );
  assert.deepEqual(
    rulesets.main.rules
      .find((rule) => rule.type === 'required_status_checks')
      .parameters.required_status_checks.map((item) => item.context)
      .sort(),
    EXPECTED_MAIN_CHECKS.slice().sort(),
    'main ruleset should restore required checks'
  );
  assert.deepEqual(
    rulesets.release.rules
      .find((rule) => rule.type === 'required_status_checks')
      .parameters.required_status_checks.map((item) => item.context)
      .sort(),
    EXPECTED_RELEASE_CHECKS.slice().sort(),
    'release ruleset should restore required checks'
  );
});

test('priority:policy diagnostics use resolved fork-local ruleset ids after stable-identity resolution', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const expectedRulesetUrls = {
    develop: `${repoUrl}/rulesets/8811898`,
    main: `${repoUrl}/rulesets/8614140`,
    release: `${repoUrl}/rulesets/8614172`
  };
  const rulesets = createAlignedRulesets({
    develop: 99301,
    main: 99302,
    release: 99303
  });
  rulesets.develop.rules.find((rule) => rule.type === 'required_status_checks').parameters.required_status_checks =
    EXPECTED_DEVELOP_CHECKS.filter((context) => context !== 'commit-integrity').map((context) => ({ context }));

  const errorMessages = [];
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method !== 'GET') {
      throw new Error(`Unexpected request ${method} ${url}`);
    }
    if (url === repoUrl) {
      return createResponse(createAlignedRepoState());
    }
    if (url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (url === expectedRulesetUrls.develop || url === expectedRulesetUrls.main || url === expectedRulesetUrls.release) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (url === listUrl) {
      return createResponse([
        toRulesetSummary(rulesets.develop),
        toRulesetSummary(rulesets.main),
        toRulesetSummary(rulesets.release)
      ]);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.develop.id}`) {
      return createResponse(rulesets.develop);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.main.id}`) {
      return createResponse(rulesets.main);
    }
    if (url === `${repoUrl}/rulesets/${rulesets.release.id}`) {
      return createResponse(rulesets.release);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const code = await run({
    argv: ['node', 'check-policy.mjs'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: () => {},
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 1, 'verify mode should fail when the resolved fork-local ruleset still drifts');
  assert.ok(
    errorMessages.some((msg) => msg.includes('ruleset 99301: required_status_checks: missing [commit-integrity]')),
    'diff output should reference the resolved fork-local ruleset id'
  );
  assert.ok(
    !errorMessages.some((msg) => msg.includes('ruleset 8811898: required_status_checks: missing [commit-integrity]')),
    'diff output should not keep referring to the manifest id after identity resolution'
  );
});

test('priority:policy --apply creates missing fork-local rulesets when no identity match exists', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const createdRulesets = [];
  let nextRulesetId = 99200;

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse(createAlignedRepoState());
    }
    if (method === 'GET' && url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (method === 'GET' && url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8811898`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614140`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614172`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === listUrl) {
      return createResponse(createdRulesets.map((ruleset) => toRulesetSummary(ruleset)));
    }
    if (method === 'GET' && url.startsWith(`${repoUrl}/rulesets/`)) {
      const id = Number(url.split('/').at(-1));
      const match = createdRulesets.find((ruleset) => ruleset.id === id);
      if (!match) {
        return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
      }
      return createResponse(match);
    }
    if (method === 'POST' && url === listUrl) {
      const payload = JSON.parse(options.body);
      const created = {
        id: ++nextRulesetId,
        ...payload
      };
      createdRulesets.push(created);
      return createResponse(created);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

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
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0, 'apply mode should create missing fork-local rulesets');
  assert.equal(createdRulesets.length, 3, 'three fork-local rulesets should be created');
  assert.deepEqual(
    createdRulesets.map((ruleset) => ruleset.name).sort(),
    ['develop', 'main', 'release'],
    'created rulesets should cover develop/main/release identities'
  );
  const createdDevelopRuleset = createdRulesets.find((ruleset) => ruleset.name === 'develop');
  assert.ok(
    createdDevelopRuleset.rules.some((rule) => rule.type === 'merge_queue'),
    'created develop ruleset should include merge_queue'
  );
  assert.ok(
    createdDevelopRuleset.rules.some((rule) => rule.type === 'copilot_code_review'),
    'created develop ruleset should include copilot_code_review'
  );
});

test('priority:policy verify passes on user-owned throughput forks without queue-managed rulesets', async () => {
  const repoUrl = 'https://api.github.com/repos/test-user/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse({
        ...createAlignedRepoState(),
        fork: true,
        owner: { type: 'User', login: 'test-user' },
        permissions: { admin: true }
      });
    }
    if (method === 'GET' && url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (method === 'GET' && url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8811898`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614140`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614172`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === listUrl) {
      return createResponse([]);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const logMessages = [];
  const errorMessages = [];
  const code = await run({
    argv: ['node', 'check-policy.mjs'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-user/test-repo',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'verify mode should pass on user-owned throughput forks without rulesets');
  assert.ok(
    logMessages.some((msg) => msg.includes('User-owned throughput fork detected')),
    'expected throughput-fork relaxation log'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy --apply does not create queue-managed rulesets on user-owned throughput forks', async () => {
  const repoUrl = 'https://api.github.com/repos/test-user/test-repo';
  const listUrl = `${repoUrl}/rulesets`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const requests = [];

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    requests.push({ method, url });
    if (method === 'GET' && url === repoUrl) {
      return createResponse({
        ...createAlignedRepoState(),
        fork: true,
        owner: { type: 'User', login: 'test-user' },
        permissions: { admin: true }
      });
    }
    if (method === 'GET' && url === branchDevelopUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_DEVELOP_CHECKS));
    }
    if (method === 'GET' && url === branchMainUrl) {
      return createResponse(createAlignedBranchProtection(EXPECTED_MAIN_CHECKS));
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8811898`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614140`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === `${repoUrl}/rulesets/8614172`) {
      return createResponse({ message: 'Not Found', status: '404' }, 404, 'Not Found');
    }
    if (method === 'GET' && url === listUrl) {
      return createResponse([]);
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const code = await run({
    argv: ['node', 'check-policy.mjs', '--apply'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-user/test-repo',
      GITHUB_TOKEN: 'fake-token'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0, 'apply mode should succeed on user-owned throughput forks without rulesets');
  assert.equal(
    requests.some((entry) => entry.method === 'POST' && entry.url === listUrl),
    false,
    'apply mode should not create rulesets for user-owned throughput forks'
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

  assert.equal(code, 0, 'run should exit cleanly with skip');
  assert.ok(
    logMessages.some((msg) => msg.includes('skipping policy check')),
    'skip message expected when admin permissions unavailable'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy keeps GH_TOKEN when valid and does not fallback', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;
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
    conditions: { ref_name: { include: ['refs/heads/develop'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };
  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    enforcement: 'active',
    conditions: { ref_name: { include: ['refs/heads/main'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };
  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    enforcement: 'active',
    conditions: { ref_name: { include: ['refs/heads/release/*'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };

  const tokensSeen = [];
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const authHeader = options.headers?.Authorization ?? '';
    const token = String(authHeader).replace(/^Bearer\s+/i, '');
    tokensSeen.push(token);
    if (token !== 'gh-valid') {
      return createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
    }

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
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-valid',
      GITHUB_TOKEN: 'github-valid'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'run should exit cleanly with valid GH_TOKEN');
  assert.ok(tokensSeen.length > 0, 'expected at least one authenticated request');
  assert.ok(tokensSeen.every((token) => token === 'gh-valid'), 'requests should remain on GH_TOKEN');
  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GH_TOKEN')),
    'auth source log should report GH_TOKEN'
  );
  assert.ok(
    !logMessages.some((msg) => msg.includes('auth fallback:')),
    'fallback should not occur when GH_TOKEN is valid'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy falls back from GH_TOKEN to GITHUB_TOKEN on 401', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;
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
    conditions: { ref_name: { include: ['refs/heads/develop'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };
  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    enforcement: 'active',
    conditions: { ref_name: { include: ['refs/heads/main'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };
  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    enforcement: 'active',
    conditions: { ref_name: { include: ['refs/heads/release/*'], exclude: [] } },
    bypass_actors: [],
    rules: []
  };

  const tokensSeen = [];
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const authHeader = options.headers?.Authorization ?? '';
    const token = String(authHeader).replace(/^Bearer\s+/i, '');
    tokensSeen.push(token);

    if (token === 'gh-stale') {
      return createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
    }
    if (token !== 'github-valid') {
      return createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
    }

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
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-stale',
      GITHUB_TOKEN: 'github-valid'
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'run should succeed after auth fallback');
  assert.ok(tokensSeen.includes('gh-stale'), 'GH token should be attempted first');
  assert.ok(tokensSeen.includes('github-valid'), 'GITHUB token should be used as fallback');
  assert.ok(
    logMessages.some((msg) => msg.includes('auth fallback: GH_TOKEN -> GITHUB_TOKEN')),
    'fallback log should report GH_TOKEN -> GITHUB_TOKEN'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy skips non-apply validation when GH_TOKEN 401 has no fallback', async () => {
  const fetchMock = async () => createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
  const logMessages = [];
  const errorMessages = [];

  const code = await run({
    argv: ['node', 'check-policy.mjs'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-stale',
      GITHUB_TOKEN: ''
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 0, 'non-apply mode should skip on auth-unavailable path');
  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GH_TOKEN')),
    'auth source log should report GH_TOKEN'
  );
  assert.ok(
    logMessages.some((msg) => msg.includes('Authorization unavailable for policy check')),
    'skip log should report authorization-unavailable reason'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy --apply fails when GH_TOKEN 401 has no fallback', async () => {
  const fetchMock = async () => createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
  const logMessages = [];
  const errorMessages = [];

  await assert.rejects(
    () =>
      run({
        argv: ['node', 'check-policy.mjs', '--apply'],
        env: {
          ...process.env,
          GITHUB_REPOSITORY: 'test-org/test-repo',
          GH_TOKEN: 'gh-stale',
          GITHUB_TOKEN: ''
        },
        fetchFn: fetchMock,
        execSyncFn: () => {
          throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
        },
        log: (msg) => logMessages.push(msg),
        error: (msg) => errorMessages.push(msg)
      }),
    /authorization unavailable/i
  );

  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GH_TOKEN')),
    'auth source log should report GH_TOKEN'
  );
  assert.deepEqual(errorMessages, []);
});

test('priority:policy emits machine-readable report when --report is provided', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'priority-policy-report-'));
  const reportPath = path.join(tempDir, 'report.json');
  const fetchMock = async () => createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');

  const code = await run({
    argv: ['node', 'check-policy.mjs', '--report', reportPath],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-stale',
      GITHUB_TOKEN: ''
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 0, 'non-apply mode should still return skip code');
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(report.schema, 'priority/policy-report@v1');
  assert.equal(report.result, 'skipped');
  assert.equal(report.apply, false);
});

test('priority:policy verify fails when queue-managed ruleset is missing merge_queue', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;
  const repoState = {
    allow_squash_merge: true,
    allow_merge_commit: false,
    allow_rebase_merge: true,
    allow_auto_merge: true,
    delete_branch_on_merge: true,
    permissions: {
      admin: true
    }
  };

  const developChecks = [...EXPECTED_DEVELOP_CHECKS];
  const mainChecks = [
    'lint',
    'pester',
    'vi-binary-check',
    'vi-compare',
    'Policy Guard (Upstream) / policy-guard',
    'commit-integrity'
  ];
  const releaseChecks = [
    'lint',
    'pester',
    'publish',
    'vi-binary-check',
    'vi-compare',
    'mock-cli',
    'Policy Guard (Upstream) / policy-guard'
  ];

  const branchDevelopProtection = {
    required_status_checks: {
      strict: true,
      checks: developChecks.map((context) => ({ context }))
    },
    required_linear_history: { enabled: true }
  };
  const branchMainProtection = {
    required_status_checks: {
      strict: true,
      checks: mainChecks.map((context) => ({ context }))
    },
    required_linear_history: { enabled: true }
  };

  const rulesetDevelop = {
    id: 8811898,
    name: 'develop',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/develop'], exclude: [] } },
    rules: [
      { type: 'required_linear_history' },
      {
        type: 'required_status_checks',
        parameters: {
          required_status_checks: developChecks.map((context) => ({ context }))
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
          allowed_merge_methods: ['squash', 'rebase']
        }
      },
      {
        type: 'code_quality',
        parameters: {
          severity: 'warnings'
        }
      },
      {
        type: 'copilot_code_review',
        parameters: {
          review_on_push: true,
          review_draft_pull_requests: false
        }
      }
    ]
  };
  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/main'], exclude: [] } },
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
        type: 'required_status_checks',
        parameters: {
          required_status_checks: mainChecks.map((context) => ({ context }))
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
          allowed_merge_methods: ['squash', 'rebase']
        }
      },
      {
        type: 'code_quality',
        parameters: {
          severity: 'warnings'
        }
      },
      {
        type: 'copilot_code_review',
        parameters: {
          review_on_push: true,
          review_draft_pull_requests: false
        }
      }
    ]
  };
  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/release/*'], exclude: [] } },
    rules: [
      {
        type: 'required_status_checks',
        parameters: {
          required_status_checks: releaseChecks.map((context) => ({ context }))
        }
      },
      {
        type: 'pull_request',
        parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false,
          allowed_merge_methods: ['rebase']
        }
      }
    ]
  };

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method !== 'GET') {
      throw new Error(`Unexpected request ${method} ${url}`);
    }
    if (url === repoUrl) {
      return createResponse(repoState);
    }
    if (url === branchDevelopUrl) {
      return createResponse(branchDevelopProtection);
    }
    if (url === branchMainUrl) {
      return createResponse(branchMainProtection);
    }
    if (url === rulesetDevelopUrl) {
      return createResponse(rulesetDevelop);
    }
    if (url === rulesetMainUrl) {
      return createResponse(rulesetMain);
    }
    if (url === rulesetReleaseUrl) {
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

  assert.equal(code, 1, 'verify mode should fail when queue rule is missing');
  assert.ok(
    errorMessages.some((msg) => msg.includes('merge_queue: rule missing')),
    'expected merge_queue missing diagnostic'
  );
  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GITHUB_TOKEN')),
    'expected auth source to be logged'
  );
});

test('priority:policy verify uses queue-managed rulesets as required-check source of truth', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;
  const branchDevelopUrl = `${repoUrl}/branches/develop/protection`;
  const branchMainUrl = `${repoUrl}/branches/main/protection`;

  const repoState = {
    allow_squash_merge: true,
    allow_merge_commit: false,
    allow_rebase_merge: true,
    allow_auto_merge: true,
    delete_branch_on_merge: true,
    permissions: {
      admin: true
    }
  };

  const developChecksExpected = [...EXPECTED_DEVELOP_CHECKS];
  const mainChecksExpected = [
    'lint',
    'pester',
    'vi-binary-check',
    'vi-compare',
    'Policy Guard (Upstream) / policy-guard',
    'commit-integrity'
  ];
  const releaseChecksExpected = [
    'lint',
    'pester',
    'publish',
    'vi-binary-check',
    'vi-compare',
    'mock-cli',
    'Policy Guard (Upstream) / policy-guard'
  ];

  const branchDevelopProtection = {
    required_status_checks: {
      strict: true,
      checks: developChecksExpected
        .filter((context) => context !== 'commit-integrity')
        .map((context) => ({ context }))
    },
    required_linear_history: { enabled: true },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  const branchMainProtection = {
    required_status_checks: {
      strict: true,
      checks: mainChecksExpected
        .filter((context) => context !== 'commit-integrity')
        .map((context) => ({ context }))
    },
    required_linear_history: { enabled: true },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  const mergeQueueParams = {
    merge_method: 'SQUASH',
    grouping_strategy: 'ALLGREEN',
    max_entries_to_build: 5,
    min_entries_to_merge: 1,
    max_entries_to_merge: 5,
    min_entries_to_merge_wait_minutes: 1,
    check_response_timeout_minutes: 60
  };

  const rulesetDevelop = {
    id: 8811898,
    name: 'develop',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/develop'], exclude: [] } },
    rules: [
      { type: 'required_linear_history' },
      { type: 'merge_queue', parameters: mergeQueueParams },
      {
        type: 'required_status_checks',
        parameters: {
          required_status_checks: developChecksExpected.map((context) => ({ context }))
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
          allowed_merge_methods: ['squash', 'rebase']
        }
      },
      {
        type: 'code_quality',
        parameters: {
          severity: 'warnings'
        }
      },
      {
        type: 'copilot_code_review',
        parameters: {
          review_on_push: true,
          review_draft_pull_requests: false
        }
      }
    ]
  };

  const rulesetMain = {
    id: 8614140,
    name: 'main',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/main'], exclude: [] } },
    rules: [
      { type: 'merge_queue', parameters: mergeQueueParams },
      {
        type: 'required_status_checks',
        parameters: {
          required_status_checks: mainChecksExpected.map((context) => ({ context }))
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
          allowed_merge_methods: ['squash', 'rebase']
        }
      }
    ]
  };

  const rulesetRelease = {
    id: 8614172,
    name: 'release',
    target: 'branch',
    conditions: { ref_name: { include: ['refs/heads/release/*'], exclude: [] } },
    rules: [
      {
        type: 'required_status_checks',
        parameters: {
          required_status_checks: releaseChecksExpected.map((context) => ({ context }))
        }
      },
      {
        type: 'pull_request',
        parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false,
          allowed_merge_methods: ['rebase']
        }
      }
    ]
  };

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method !== 'GET') {
      throw new Error(`Unexpected request ${method} ${url}`);
    }
    if (url === repoUrl) {
      return createResponse(repoState);
    }
    if (url === branchDevelopUrl) {
      return createResponse(branchDevelopProtection);
    }
    if (url === branchMainUrl) {
      return createResponse(branchMainProtection);
    }
    if (url === rulesetDevelopUrl) {
      return createResponse(rulesetDevelop);
    }
    if (url === rulesetMainUrl) {
      return createResponse(rulesetMain);
    }
    if (url === rulesetReleaseUrl) {
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

  assert.equal(
    code,
    0,
    `verify mode should pass when queue-managed rulesets match policy: ${errorMessages.join(' | ')}`
  );
  assert.deepEqual(errorMessages, []);
  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GITHUB_TOKEN')),
    'auth source log expected'
  );
});

test('priority:policy --fail-on-skip fails non-apply validation when GH_TOKEN 401 has no fallback', async () => {
  const fetchMock = async () => createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');
  const logMessages = [];
  const errorMessages = [];

  const code = await run({
    argv: ['node', 'check-policy.mjs', '--fail-on-skip'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-stale',
      GITHUB_TOKEN: ''
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: (msg) => logMessages.push(msg),
    error: (msg) => errorMessages.push(msg)
  });

  assert.equal(code, 1, 'non-apply mode should fail on auth-unavailable path in strict mode');
  assert.ok(
    errorMessages.some((msg) => msg.includes('Strict mode enabled (--fail-on-skip)')),
    'strict-mode failure diagnostic expected'
  );
  assert.ok(
    !logMessages.some((msg) => msg.includes('skipping non-apply validation')),
    'strict mode should not leave auth-unavailable as pass-through skip'
  );
});

test('priority:policy --fail-on-skip fails when admin permission is unavailable in verify mode', async () => {
  const repoUrl = 'https://api.github.com/repos/test-org/test-repo';
  const rulesetDevelopUrl = `${repoUrl}/rulesets/8811898`;
  const rulesetMainUrl = `${repoUrl}/rulesets/8614140`;
  const rulesetReleaseUrl = `${repoUrl}/rulesets/8614172`;
  const repoState = {
    permissions: {
      admin: false
    }
  };
  const rulesetStub = {
    id: 8811898,
    name: 'develop',
    target: 'branch',
    conditions: {
      ref_name: {
        include: ['refs/heads/develop'],
        exclude: []
      }
    },
    bypass_actors: [],
    rules: []
  };

  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && url === repoUrl) {
      return createResponse(repoState);
    }
    if (method === 'GET' && url === rulesetDevelopUrl) {
      return createResponse(rulesetStub);
    }
    if (method === 'GET' && url === rulesetMainUrl) {
      return createResponse({ ...rulesetStub, id: 8614140, name: 'main' });
    }
    if (method === 'GET' && url === rulesetReleaseUrl) {
      return createResponse({ ...rulesetStub, id: 8614172, name: 'release' });
    }
    throw new Error(`Unexpected request ${method} ${url}`);
  };

  const logMessages = [];
  const errorMessages = [];
  const code = await run({
    argv: ['node', 'check-policy.mjs', '--fail-on-skip'],
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

  assert.equal(code, 1, 'verify mode should fail when admin permission skip path is hit in strict mode');
  assert.ok(
    errorMessages.some((msg) => msg.includes('Strict mode enabled (--fail-on-skip)')),
    'strict-mode failure diagnostic expected for admin-skip path'
  );
  assert.ok(
    logMessages.some((msg) => msg.includes('auth source: GITHUB_TOKEN')),
    'auth source log expected'
  );
});

test('priority:policy --fail-on-skip emits fail report when auth-unavailable skip path is blocked', async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'priority-policy-report-strict-'));
  const reportPath = path.join(tempDir, 'report.json');
  const fetchMock = async () => createResponse({ message: 'Bad credentials', status: '401' }, 401, 'Unauthorized');

  const code = await run({
    argv: ['node', 'check-policy.mjs', '--report', reportPath, '--fail-on-skip'],
    env: {
      ...process.env,
      GITHUB_REPOSITORY: 'test-org/test-repo',
      GH_TOKEN: 'gh-stale',
      GITHUB_TOKEN: ''
    },
    fetchFn: fetchMock,
    execSyncFn: () => {
      throw new Error('execSync should not be called when GITHUB_REPOSITORY is set');
    },
    log: () => {},
    error: () => {}
  });

  assert.equal(code, 1, 'strict mode should fail instead of skip');
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(report.schema, 'priority/policy-report@v1');
  assert.equal(report.result, 'fail');
  assert.match(report.skippedReason, /Strict mode enabled \(\-\-fail-on-skip\)/);
});

test('priority:policy branch-protection seams pass when disabled settings are explicitly disabled', () => {
  const expected = {
    required_status_checks_strict: true,
    required_status_checks: ['lint', 'session-index'],
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
  };

  const actualProtection = {
    required_status_checks: {
      strict: true,
      checks: expected.required_status_checks.map((context) => ({ context }))
    },
    required_linear_history: { enabled: true },
    enforce_admins: { enabled: false },
    required_pull_request_reviews: null,
    restrictions: null,
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
    block_creations: { enabled: false },
    required_conversation_resolution: { enabled: false },
    lock_branch: { enabled: false },
    allow_fork_syncing: { enabled: false }
  };

  const diffs = __test.compareBranchSettings('develop', expected, actualProtection);
  assert.deepEqual(diffs, []);
});

test('priority:policy branch-protection seams fail when disabled settings drift to enabled', () => {
  const expected = {
    required_status_checks_strict: true,
    required_status_checks: ['lint', 'session-index'],
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
  };

  const actualProtection = {
    required_status_checks: {
      strict: true,
      checks: expected.required_status_checks.map((context) => ({ context }))
    },
    required_linear_history: { enabled: true },
    enforce_admins: { enabled: true },
    required_pull_request_reviews: {
      required_approving_review_count: 1
    },
    restrictions: {
      users: ['octocat']
    },
    allow_force_pushes: { enabled: true },
    allow_deletions: { enabled: true },
    block_creations: { enabled: true },
    required_conversation_resolution: { enabled: true },
    lock_branch: { enabled: true },
    allow_fork_syncing: { enabled: true }
  };

  const diffs = __test.compareBranchSettings('develop', expected, actualProtection);
  const requiredFragments = [
    'enforce_admins expected false, actual true',
    'required_pull_request_reviews expected null',
    'restrictions expected null',
    'allow_force_pushes expected false, actual true',
    'allow_deletions expected false, actual true',
    'block_creations expected false, actual true',
    'required_conversation_resolution expected false, actual true',
    'lock_branch expected false, actual true',
    'allow_fork_syncing expected false, actual true'
  ];

  for (const fragment of requiredFragments) {
    assert.ok(
      diffs.some((diff) => diff.includes(fragment)),
      `expected diff fragment not found: ${fragment}`
    );
  }
});

test('priority:policy build branch-protection payload honors explicit disabled settings', () => {
  const expected = {
    required_status_checks_strict: true,
    required_status_checks: ['lint', 'session-index'],
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
  };
  const actualProtection = {
    required_status_checks: { strict: false },
    enforce_admins: { enabled: true },
    required_pull_request_reviews: { required_approving_review_count: 1 },
    restrictions: { users: ['octocat'] },
    required_linear_history: { enabled: false },
    allow_force_pushes: { enabled: true },
    allow_deletions: { enabled: true },
    block_creations: { enabled: true },
    required_conversation_resolution: { enabled: true },
    lock_branch: { enabled: true },
    allow_fork_syncing: { enabled: true }
  };

  const payload = __test.buildBranchProtectionPayload(expected, actualProtection);
  assert.equal(payload.required_status_checks.strict, true);
  assert.deepEqual(payload.required_status_checks.contexts, expected.required_status_checks);
  assert.equal(payload.enforce_admins, false);
  assert.equal(payload.required_pull_request_reviews, null);
  assert.equal(payload.restrictions, null);
  assert.equal(payload.required_linear_history, true);
  assert.equal(payload.allow_force_pushes, false);
  assert.equal(payload.allow_deletions, false);
  assert.equal(payload.block_creations, false);
  assert.equal(payload.required_conversation_resolution, false);
  assert.equal(payload.lock_branch, false);
  assert.equal(payload.allow_fork_syncing, false);
});

test('priority:policy optional ruleset seam treats disabled expectation as explicit absence', () => {
  const normalized = __test.normalizeOptionalRuleExpectation({ enabled: false, severity: 'warnings' });
  assert.deepEqual(normalized, { mode: 'absent', parameters: null });
});

test('priority:policy optional ruleset seam detects missing code_quality rule', () => {
  const diffs = __test.compareOptionalParameterizedRule('code_quality', { severity: 'warnings' }, null);
  assert.deepEqual(diffs, ['code_quality: rule missing']);
});

test('priority:policy optional ruleset seam detects code_quality severity drift', () => {
  const diffs = __test.compareOptionalParameterizedRule(
    'code_quality',
    { severity: 'warnings' },
    {
      type: 'code_quality',
      parameters: {
        severity: 'errors'
      }
    }
  );
  assert.deepEqual(diffs, ['code_quality.severity: expected warnings, actual errors']);
});

test('priority:policy optional ruleset seam detects missing copilot review rule', () => {
  const diffs = __test.compareOptionalParameterizedRule(
    'copilot_code_review',
    { review_on_push: true, review_draft_pull_requests: false },
    null
  );
  assert.deepEqual(diffs, ['copilot_code_review: rule missing']);
});

test('priority:policy optional ruleset seam detects copilot review parameter drift', () => {
  const diffs = __test.compareOptionalParameterizedRule(
    'copilot_code_review',
    { review_on_push: true, review_draft_pull_requests: false },
    {
      type: 'copilot_code_review',
      parameters: {
        review_on_push: false,
        review_draft_pull_requests: true
      }
    }
  );
  assert.deepEqual(diffs, [
    'copilot_code_review.review_on_push: expected true, actual false',
    'copilot_code_review.review_draft_pull_requests: expected false, actual true'
  ]);
});
