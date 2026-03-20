#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync as nodeReadFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseArgs,
  parseRouterIssueNumber,
  parseCacheIssueNumber,
  parseCacheNoStandingReason,
  parseNoStandingReasonFromReport,
  resolveStandingIssueNumberForPr,
  parseIssueNumberFromBranch,
  assertBranchMatchesIssue,
  buildTitle,
  buildBody,
  resolveBody,
  createPriorityPr,
  writePriorityPrReport
} from '../create-pr.mjs';
import { loadBranchClassContract } from '../lib/branch-classification.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const TEST_BRANCH_CONTRACT = loadBranchClassContract(repoRoot);

function readDefaultPrTemplate(filePath, encoding) {
  return nodeReadFileSync(filePath, encoding);
}

function createPriorityPrWithNoMergedHistory(overrides = {}) {
  return createPriorityPr({
    findMergedPullRequestFn: () => null,
    ...overrides
  });
}

test('parseArgs accepts explicit PR helper overrides', () => {
  const options = parseArgs([
    'node',
    'create-pr.mjs',
    '--repo',
    'example/repo',
    '--issue',
    '963',
    '--branch',
    'issue/680-test',
    '--base',
    'main',
    '--title',
    'Explicit title',
    '--body-file',
    'pr-body.md'
  ]);

  assert.deepEqual(options, {
    repository: 'example/repo',
    issue: 963,
    branch: 'issue/680-test',
    base: 'main',
    title: 'Explicit title',
    body: null,
    bodyFile: 'pr-body.md',
    reportDir: path.join('tests', 'results', '_agent', 'issue'),
    headRemote: null,
    help: false
  });
});

test('parseArgs rejects conflicting body inputs', () => {
  assert.throws(
    () =>
      parseArgs([
        'node',
        'create-pr.mjs',
        '--body',
        'inline body',
        '--body-file',
        'pr-body.md'
      ]),
    /Use either --body or --body-file/i
  );
});

test('parseArgs rejects non-numeric issue overrides', () => {
  assert.throws(
    () => parseArgs(['node', 'create-pr.mjs', '--issue', 'abc']),
    /Invalid issue number/i
  );
});

test('parseArgs accepts body values that begin with a dash', () => {
  const options = parseArgs([
    'node',
    'create-pr.mjs',
    '--body',
    '- follow-up fix for current-head review'
  ]);

  assert.equal(options.body, '- follow-up fix for current-head review');
});

test('parseArgs accepts an explicit head remote override', () => {
  const options = parseArgs(['node', 'create-pr.mjs', '--head-remote', 'personal']);
  assert.equal(options.headRemote, 'personal');
});

test('parseArgs accepts an explicit report directory override', () => {
  const options = parseArgs(['node', 'create-pr.mjs', '--report-dir', '.tmp/pr-reports']);
  assert.equal(options.reportDir, '.tmp/pr-reports');
});

test('parseRouterIssueNumber returns positive integer issue values', () => {
  assert.equal(parseRouterIssueNumber({ issue: 680 }), 680);
  assert.equal(parseRouterIssueNumber({ issue: '681' }), 681);
  assert.equal(parseRouterIssueNumber({ issue: 0 }), null);
  assert.equal(parseRouterIssueNumber({ issue: null }), null);
});

test('parseCacheIssueNumber accepts OPEN standing-priority cache entries', () => {
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'open',
      labels: ['standing-priority']
    }),
    680
  );
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'OPEN',
      labels: [{ name: 'fork-standing-priority' }]
    }),
    680
  );
});

test('parseCacheIssueNumber rejects closed or non-standing cache entries', () => {
  assert.equal(
    parseCacheIssueNumber({
      number: 588,
      state: 'closed',
      labels: ['standing-priority']
    }),
    null
  );
  assert.equal(
    parseCacheIssueNumber({
      number: 680,
      state: 'open',
      labels: ['bug']
    }),
    null
  );
});

test('parseCacheNoStandingReason exposes queue-empty idle cache state', () => {
  assert.equal(
    parseCacheNoStandingReason({
      state: 'NONE',
      noStandingReason: 'queue-empty'
    }),
    'queue-empty'
  );
  assert.equal(
    parseCacheNoStandingReason({
      state: 'OPEN',
      noStandingReason: 'queue-empty'
    }),
    null
  );
});

test('parseNoStandingReasonFromReport exposes queue-empty from the no-standing artifact', () => {
  assert.equal(
    parseNoStandingReasonFromReport({
      schema: 'standing-priority/no-standing@v1',
      reason: 'queue-empty'
    }),
    'queue-empty'
  );
  assert.equal(
    parseNoStandingReasonFromReport({
      schema: 'other/schema',
      reason: 'queue-empty'
    }),
    null
  );
});

test('resolveStandingIssueNumberForPr prefers router over cache', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: 680 };
      }
      return {
        number: 588,
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.deepEqual(result, {
    issueNumber: 680,
    localIssueNumber: 680,
    issueTitle: null,
    issueUrl: null,
    source: 'router',
    noStandingReason: null,
    mirrorOf: null
  });
});

test('resolveStandingIssueNumberForPr treats explicit empty router issue as authoritative', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: null };
      }
      if (filePath.endsWith('no-standing-priority.json')) {
        return {
          schema: 'standing-priority/no-standing@v1',
          reason: 'queue-empty'
        };
      }
      return {
        number: 680,
        title: 'Stale mirrored issue',
        url: 'https://github.com/example/repo/issues/680',
        mirrorOf: {
          number: 966,
          repository: 'upstream-owner/repo',
          url: 'https://github.com/upstream-owner/repo/issues/966'
        },
        state: 'NONE',
        labels: []
      };
    }
  });

  assert.deepEqual(result, {
    issueNumber: null,
    localIssueNumber: null,
    issueTitle: null,
    issueUrl: null,
    source: 'router',
    noStandingReason: 'queue-empty',
    mirrorOf: null
  });
});

test('resolveStandingIssueNumberForPr falls back to cache when router is unavailable', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return null;
      }
      return {
        number: 680,
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.deepEqual(result, {
    issueNumber: 680,
    localIssueNumber: 680,
    issueTitle: null,
    issueUrl: null,
    source: 'cache',
    noStandingReason: null,
    mirrorOf: null
  });
});

test('createPriorityPr refuses to open a priority PR when the standing queue is empty', () => {
  assert.throws(
    () =>
      createPriorityPrWithNoMergedHistory({
        env: {},
        options: {},
        getRepoRootFn: () => '/tmp/repo',
        getCurrentBranchFn: () => 'feature/manual-follow-up',
        ensureGhCliFn: () => {},
        resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
        ensureForkRemoteFn: () => ({ owner: 'fork-owner', repo: 'repo' }),
        pushBranchFn: () => {},
        runGhPrCreateFn: () => {
          throw new Error('should not create PR');
        },
        resolveStandingIssueNumberFn: () => ({ issueNumber: null, source: 'router', noStandingReason: 'queue-empty' }),
        loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
      }),
    /Standing-priority queue is empty/i
  );
});

test('parseIssueNumberFromBranch extracts issue numbers from issue/* branches', () => {
  assert.equal(parseIssueNumberFromBranch('issue/680-sync-standing-priority'), 680);
  assert.equal(parseIssueNumberFromBranch('issue/personal-680-sync-standing-priority'), 680);
  assert.equal(parseIssueNumberFromBranch('issue/origin-1420-security-intake-dependabot-api-400'), 1420);
  assert.equal(parseIssueNumberFromBranch('feature/something'), null);
});

test('assertBranchMatchesIssue fails on mismatch', () => {
  assert.throws(
    () => assertBranchMatchesIssue('issue/588-old-branch', 680),
    /maps to #588, but standing priority resolves to #680/i
  );
});

test('buildTitle and buildBody honor env overrides', () => {
  assert.equal(
    buildTitle('issue/680-something', 680, { PR_TITLE: 'Custom Title' }),
    'Custom Title'
  );
  assert.equal(
    buildBody(680, { PR_BODY: 'Custom Body' }),
    'Custom Body'
  );
});

test('buildBody emits populated automation-authored metadata instead of placeholder bullets', () => {
  const body = buildBody(
    {
      issueNumber: 680,
      issueTitle: 'Standing helper fix',
      issueUrl: 'https://github.com/example/repo/issues/680',
      branch: 'issue/origin-680-standing-helper-fix',
      base: 'develop'
    },
    {},
    {
      repoRoot: process.cwd(),
      readFileSyncFn: nodeReadFileSync
    }
  );

  assert.match(body, /^# Summary/m);
  assert.match(body, /## Agent Metadata \(required for automation-authored PRs\)/);
  assert.match(body, /- Agent-ID: `agent\/copilot-codex-a`/);
  assert.match(body, /Primary issue or standing-priority context: #680 - Standing helper fix/);
  assert.match(body, /Issue URL: https:\/\/github.com\/example\/repo\/issues\/680/);
  assert.match(body, /Standard `develop` branch protections and required checks apply\./);
  assert.match(body, /Closes #680/);
  assert.doesNotMatch(body, /\(fill in summary\)/);
  assert.doesNotMatch(body, /\(document testing\)/);
});

test('buildBody reflects the resolved base branch in required-check guidance', () => {
  const body = buildBody(
    {
      issueNumber: 681,
      branch: 'issue/origin-681-main-hotfix',
      base: 'main'
    },
    {},
    {
      repoRoot: process.cwd(),
      readFileSyncFn: nodeReadFileSync
    }
  );

  assert.match(body, /Standard `main` branch protections and required checks apply\./);
  assert.doesNotMatch(body, /Standard develop required checks apply\./);
});

test('resolveBody prefers explicit body-file content over env defaults', () => {
  const body = resolveBody({
    options: { bodyFile: 'pr-body.md' },
    issueNumber: 680,
    readFileSyncFn: () => '## Summary\n- explicit\n'
  });

  assert.equal(body, '## Summary\n- explicit\n');
});

test('createPriorityPr builds PR metadata from resolved standing issue', () => {
  let pushedBranch = null;
  let prPayload = null;
  const result = createPriorityPrWithNoMergedHistory({
    env: {},
    options: {},
    readFileSyncFn: readDefaultPrTemplate,
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/680-sync-standing-priority',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({
      owner: 'LabVIEW-Community-CI-CD',
      repo: 'compare-vi-cli-action-fork',
      sameOwnerFork: true,
      remoteName: remote
    }),
    pushBranchFn: (_repoRoot, branch, remote) => {
      pushedBranch = `${remote}:${branch}`;
    },
    runGhPrCreateFn: (payload) => {
      prPayload = payload;
      return { strategy: 'gh-pr-create' };
    },
    resolveStandingIssueNumberFn: () => ({ issueNumber: 680, source: 'router' }),
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  assert.equal(pushedBranch, 'origin:issue/680-sync-standing-priority');
  assert.ok(prPayload);
  assert.equal(prPayload.base, 'develop');
  assert.equal(prPayload.title, 'Update for standing priority #680');
  assert.match(prPayload.body, /## Agent Metadata \(required for automation-authored PRs\)/);
  assert.match(prPayload.body, /Closes #680/);
  assert.doesNotMatch(prPayload.body, /\(fill in summary\)/);
  assert.equal(result.issueNumber, 680);
  assert.equal(result.issueSource, 'router');
  assert.equal(result.branchModel.branchPlane, 'upstream');
  assert.equal(result.branchModel.selectedHeadRemote, 'origin');
  assert.equal(result.strategy, 'gh-pr-create');
});

test('resolveStandingIssueNumberForPr carries cached issue metadata into the PR helper context', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: 1033 };
      }
      return {
        number: 1033,
        title: 'priority:pr should not open automation PRs with placeholder bodies',
        url: 'https://github.com/example/repo/issues/1033',
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.equal(result.issueTitle, 'priority:pr should not open automation PRs with placeholder bodies');
  assert.equal(result.issueUrl, 'https://github.com/example/repo/issues/1033');
});

test('resolveStandingIssueNumberForPr drops stale cached metadata when router-selected issue does not match cache', () => {
  const result = resolveStandingIssueNumberForPr('/tmp/repo', {
    readJsonFn: (filePath) => {
      if (filePath.endsWith('router.json')) {
        return { issue: 1033 };
      }
      return {
        number: 9000,
        title: 'Stale issue title',
        url: 'https://github.com/example/repo/issues/9000',
        state: 'open',
        labels: ['standing-priority']
      };
    }
  });

  assert.equal(result.issueNumber, 1033);
  assert.equal(result.issueTitle, null);
  assert.equal(result.issueUrl, null);
});

test('createPriorityPr honors explicit CLI overrides and body files', () => {
  let prPayload = null;
  const result = createPriorityPrWithNoMergedHistory({
    env: {},
    options: {
      repository: 'example/upstream',
      issue: 963,
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'main',
      title: 'Explicit helper title',
      bodyFile: 'pr-body.md'
    },
    readFileSyncFn: () => '## Summary\n- helper body\n',
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/000-ignored',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => {
      throw new Error('should not resolve upstream when --repo is explicit');
    },
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action-fork', sameOwnerFork: true, remoteName: remote }),
    pushBranchFn: () => {},
    runGhPrCreateFn: (payload) => {
      prPayload = payload;
      return { strategy: 'graphql-same-owner-fork' };
    },
    resolveStandingIssueNumberFn: () => {
      throw new Error('should not resolve standing priority when --issue is explicit');
    },
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  assert.equal(prPayload.upstream.owner, 'example');
  assert.equal(prPayload.upstream.repo, 'upstream');
  assert.equal(prPayload.headRepository.remoteName, 'origin');
  assert.equal(prPayload.branch, 'issue/963-org-owned-fork-pr-helper');
  assert.equal(prPayload.base, 'main');
  assert.equal(prPayload.title, 'Explicit helper title');
  assert.equal(prPayload.body, '## Summary\n- helper body\n');
  assert.equal(result.strategy, 'graphql-same-owner-fork');
  assert.equal(result.issueNumber, 963);
  assert.equal(result.issueSource, 'cli');
  assert.equal(result.branchModel.branchPlane, 'upstream');
});

test('createPriorityPr fails before PR creation when branch issue mismatches standing issue', () => {
  let prCreated = false;
  assert.throws(
    () =>
      createPriorityPrWithNoMergedHistory({
        env: {},
        options: {},
        getRepoRootFn: () => '/tmp/repo',
        getCurrentBranchFn: () => 'issue/588-closed',
        ensureGhCliFn: () => {},
        resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
        ensureForkRemoteFn: () => ({ owner: 'fork-owner', repo: 'repo' }),
        pushBranchFn: () => {},
        runGhPrCreateFn: () => {
          prCreated = true;
        },
        resolveStandingIssueNumberFn: () => ({ issueNumber: 680, source: 'router' })
      }),
    /maps to #588, but standing priority resolves to #680/i
  );
  assert.equal(prCreated, false);
});

test('createPriorityPr ignores incidental trailing numeric suffixes when matching standing issue branches', () => {
  let prPayload = null;
  const result = createPriorityPrWithNoMergedHistory({
    env: {},
    options: {
      issue: 1420
    },
    readFileSyncFn: readDefaultPrTemplate,
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/origin-1420-security-intake-dependabot-api-400',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({
      owner: 'LabVIEW-Community-CI-CD',
      repo: 'compare-vi-cli-action-fork',
      sameOwnerFork: true,
      remoteName: remote
    }),
    pushBranchFn: () => {},
    runGhPrCreateFn: (payload) => {
      prPayload = payload;
      return { strategy: 'gh-pr-create' };
    },
    resolveStandingIssueNumberFn: () => ({ issueNumber: 1420, source: 'router' }),
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  assert.equal(result.issueNumber, 1420);
  assert.equal(prPayload.branch, 'issue/origin-1420-security-intake-dependabot-api-400');
});

test('createPriorityPr uses mirror metadata for PR closing references while matching the local mirror branch', () => {
  let observedTitle = null;
  let observedBody = null;
  createPriorityPrWithNoMergedHistory({
    env: { AGENT_PRIORITY_ACTIVE_FORK_REMOTE: 'personal' },
    options: {},
    readFileSyncFn: readDefaultPrTemplate,
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/personal-1-artifact-download-helper',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'upstream-owner', repo: 'repo' }),
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({
      owner: 'svelderrainruiz',
      repo: 'compare-vi-cli-action',
      remoteName: remote
    }),
    pushBranchFn: () => {},
    runGhPrCreateFn: (payload) => {
      observedTitle = payload.title;
      observedBody = payload.body;
      return { strategy: 'gh-pr-create' };
    },
    resolveStandingIssueNumberFn: () => ({
      issueNumber: 966,
      localIssueNumber: 1,
      source: 'router',
      mirrorOf: {
        number: 966,
        repository: 'upstream-owner/repo',
        url: 'https://github.com/upstream-owner/repo/issues/966'
      }
    }),
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  assert.match(observedTitle, /#966/);
  assert.match(observedBody, /Closes #966/);
});

test('createPriorityPr selects the personal remote from the branch contract for personal lane branches', () => {
  let observedRemote = null;
  let observedBranchModel = null;
  const result = createPriorityPrWithNoMergedHistory({
    env: {},
    options: {},
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/personal-1145-pr-branch-contract',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => {
      observedRemote = remote;
      return { owner: 'svelderrainruiz', repo: 'compare-vi-cli-action', remoteName: remote };
    },
    pushBranchFn: () => ({}),
    runGhPrCreateFn: () => ({ strategy: 'gh-pr-create' }),
    resolveStandingIssueNumberFn: () => ({ issueNumber: 1145, source: 'router' }),
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  observedBranchModel = result.branchModel;
  assert.equal(observedRemote, 'personal');
  assert.equal(observedBranchModel.branchPlane, 'personal');
  assert.equal(observedBranchModel.requiredHeadRemote, 'personal');
  assert.equal(observedBranchModel.selectedHeadRemoteSource, 'branch-contract');
});

test('createPriorityPr fails closed when an explicit head remote conflicts with the branch contract', () => {
  assert.throws(
    () =>
      createPriorityPrWithNoMergedHistory({
        env: {},
        options: {
          headRemote: 'origin'
        },
        getRepoRootFn: () => '/tmp/repo',
        getCurrentBranchFn: () => 'issue/personal-1145-pr-branch-contract',
        ensureGhCliFn: () => {},
        resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
        ensureForkRemoteFn: () => {
          throw new Error('should not resolve the conflicting fork remote');
        },
        pushBranchFn: () => ({}),
        runGhPrCreateFn: () => ({ strategy: 'gh-pr-create' }),
        resolveStandingIssueNumberFn: () => ({ issueNumber: 1145, source: 'router' }),
        loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
      }),
    /resolves to the personal fork plane/i
  );
});

test('writePriorityPrReport persists personal fork lane metadata for future resume', () => {
  const reportDir = mkdtempSync(path.join(os.tmpdir(), 'priority-pr-report-'));
  const { report, reportPath } = writePriorityPrReport(
    {
      repoRoot: reportDir,
      branch: 'issue/personal-969-fork-lane-dogfood',
      base: 'develop',
      issueNumber: 969,
      localIssueNumber: 319,
      issueSource: 'router',
      mirrorOf: {
        number: 969,
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/969'
      },
      headRemote: 'personal',
      upstream: {
        owner: 'LabVIEW-Community-CI-CD',
        repo: 'compare-vi-cli-action'
      },
      headRepository: {
        owner: 'svelderrainruiz',
        repo: 'compare-vi-cli-action'
      },
      branchModel: {
        contractPath: 'tools/policy/branch-classes.json',
        contractDigest: 'abc123',
        branchPlane: 'personal',
        repositoryPlane: 'personal',
        classificationRepository: 'svelderrainruiz/compare-vi-cli-action',
        laneBranchPrefix: 'issue/personal-',
        selectedHeadRemote: 'personal',
        selectedHeadRemoteSource: 'branch-contract',
        requiredHeadRemote: 'personal',
        classification: {
          id: 'lane',
          repositoryRole: 'fork',
          repositoryPlane: 'personal',
          matchedPattern: 'issue/*',
          prSourceAllowed: true,
          prTargetAllowed: false,
          mergePolicy: 'n/a',
          purpose: 'Short-lived implementation branches tied to issues.'
        }
      },
      pushStatus: 'pushed',
      strategy: 'gh-pr-create',
      reusedExistingPullRequest: false,
      pullRequest: {
        number: 1139,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1139',
        isDraft: false
      }
    },
    {
      reportDir,
      getNow: () => '2026-03-14T10:45:00.000Z'
    }
  );

  assert.equal(path.basename(reportPath), 'priority-pr-create-personal-319.json');
  assert.equal(report.schema, 'priority/pr-create@v1');
  assert.equal(report.issue.upstreamNumber, 969);
  assert.equal(report.issue.localNumber, 319);
  assert.equal(report.issue.mirrorOf.number, 969);
  assert.equal(report.head.remote, 'personal');
  assert.equal(report.head.repository, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(report.branchModel.contractPath, 'tools/policy/branch-classes.json');
  assert.equal(report.branchModel.branchPlane, 'personal');
  assert.equal(report.branchModel.selectedHeadRemoteSource, 'branch-contract');
  assert.equal(report.pullRequest.number, 1139);
  assert.match(nodeReadFileSync(reportPath, 'utf8'), /priority\/pr-create@v1/);
});

test('createPriorityPr preserves an already-published human-drafted PR so a later ready-for-review transition can trigger a fresh Copilot review', () => {
  const result = createPriorityPrWithNoMergedHistory({
    env: {},
    options: {
      repository: 'example/upstream',
      issue: 963,
      branch: 'issue/963-org-owned-fork-pr-helper',
      base: 'develop',
      title: 'Explicit helper title',
      body: 'Body'
    },
    getRepoRootFn: () => '/tmp/repo',
    getCurrentBranchFn: () => 'issue/000-ignored',
    ensureGhCliFn: () => {},
    resolveUpstreamFn: () => {
      throw new Error('should not resolve upstream when --repo is explicit');
    },
    ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({
      owner: 'LabVIEW-Community-CI-CD',
      repo: 'compare-vi-cli-action-fork',
      sameOwnerFork: true,
      remoteName: remote
    }),
    pushBranchFn: () => ({
      status: 'already-published',
      remote: 'origin',
      branch: 'issue/963-org-owned-fork-pr-helper',
      recoveredFromPushFailure: true
    }),
    runGhPrCreateFn: () => ({
      strategy: 'graphql-same-owner-fork',
      reusedExisting: true,
      pullRequest: {
        number: 963,
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/963',
        isDraft: true
      }
    }),
    resolveStandingIssueNumberFn: () => {
      throw new Error('should not resolve standing priority when --issue is explicit');
    },
    loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
  });

  assert.equal(result.pushStatus, 'already-published');
  assert.equal(result.reusedExistingPullRequest, true);
  assert.equal(result.pullRequest.number, 963);
  assert.equal(result.pullRequest.isDraft, true);
});

test('createPriorityPr fails closed before push when the branch already backed a merged PR', () => {
  let pushCalled = false;
  let createCalled = false;

  assert.throws(
    () =>
      createPriorityPr({
        env: {},
        options: {},
        getRepoRootFn: () => '/tmp/repo',
        getCurrentBranchFn: () => 'issue/origin-1430-queue-auto-branch-cleanup',
        ensureGhCliFn: () => {},
        resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
        ensureForkRemoteFn: (_repoRoot, _upstream, remote) => ({
          owner: 'LabVIEW-Community-CI-CD',
          repo: 'compare-vi-cli-action-fork',
          sameOwnerFork: true,
          remoteName: remote
        }),
        pushBranchFn: () => {
          pushCalled = true;
          return {};
        },
        runGhPrCreateFn: () => {
          createCalled = true;
          return { strategy: 'graphql-same-owner-fork' };
        },
        findMergedPullRequestFn: () => ({
          number: 1433,
          url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1433',
          state: 'MERGED'
        }),
        resolveStandingIssueNumberFn: () => ({ issueNumber: 1430, source: 'router' }),
        loadBranchClassContractFn: () => TEST_BRANCH_CONTRACT
      }),
    /already backed merged PR #1433 .*Cut a fresh branch from develop/i
  );

  assert.equal(pushCalled, false);
  assert.equal(createCalled, false);
});
