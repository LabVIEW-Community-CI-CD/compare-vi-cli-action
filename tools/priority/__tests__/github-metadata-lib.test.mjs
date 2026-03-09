import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const libPath = path.join(repoRoot, 'dist', 'tools', 'cli', 'github-metadata-lib.js');
const metadataLib = await import(pathToFileURL(libPath).href);

function reviewerRef(value) {
  return metadataLib.parseReviewerSpecifier(value);
}

function createIssue({
  id,
  url,
  number,
  title,
  repository = 'example/repo',
  assignees = [],
  milestone = null,
  issueType = null,
  parentIssue = null,
  subIssues = [],
}) {
  return {
    contentType: 'Issue',
    id,
    url,
    number,
    title,
    repository,
    assignees: [...assignees],
    reviewers: [],
    milestone,
    issueType,
    parentIssue,
    subIssues: [...subIssues],
  };
}

function createPullRequest({
  id,
  url,
  number,
  title,
  repository = 'example/repo',
  assignees = [],
  reviewers = [],
  milestone = null,
}) {
  return {
    contentType: 'PullRequest',
    id,
    url,
    number,
    title,
    repository,
    assignees: [...assignees],
    reviewers: [...reviewers],
    milestone,
    issueType: null,
    parentIssue: null,
    subIssues: [],
  };
}

function makeEntityRef(target) {
  return {
    id: target.id,
    url: target.url,
    number: target.number,
    title: target.title ?? null,
  };
}

function parseGraphqlArgs(args) {
  let query = '';
  const variables = {};
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if ((token === '-f' || token === '-F') && index + 1 < args.length) {
      const assignment = args[index + 1];
      const separator = assignment.indexOf('=');
      if (separator >= 0) {
        const key = assignment.slice(0, separator);
        const value = assignment.slice(separator + 1);
        if (key === 'query') {
          query = value;
        } else if (key.endsWith('[]')) {
          const normalized = key.slice(0, -2);
          variables[normalized] ??= [];
          variables[normalized].push(value);
        } else {
          variables[key] = token === '-F' && value === 'null' ? null : value;
        }
      }
      index += 1;
    }
  }
  return { query, variables };
}

function makeRunGhJson({ targets, issueTypes, milestones, calls = [] }) {
  const byUrl = new Map(Object.values(targets).map((target) => [target.url, target]));
  const byId = new Map(Object.values(targets).map((target) => [target.id, target]));

  const responseForTarget = (target) => {
    const [owner, name] = target.repository.split('/');
    const base = {
      __typename: target.contentType,
      id: target.id,
      url: target.url,
      number: target.number,
      title: target.title,
      repository: {
        nameWithOwner: target.repository,
        name,
        owner: { login: owner },
      },
      assignees: {
        nodes: target.assignees.map((login, index) => ({
          id: `USER_${target.id}_${index}`,
          login,
        })),
      },
      milestone: target.milestone,
    };

    if (target.contentType === 'Issue') {
      return {
        ...base,
        issueType: target.issueType,
        parent: target.parentIssue,
        subIssues: {
          totalCount: target.subIssues.length,
          nodes: target.subIssues,
        },
      };
    }

    return {
      ...base,
      reviewRequests: {
        nodes: target.reviewers.map((reviewer) => ({
          requestedReviewer: reviewer.kind === 'User'
            ? { __typename: 'User', id: `R_${reviewer.key}`, login: reviewer.login }
            : {
                __typename: 'Team',
                id: `R_${reviewer.key}`,
                slug: reviewer.teamSlug,
                organization: { login: reviewer.organization },
              },
        })),
      },
    };
  };

  const applyReviewers = (pullRequest, method, variables) => {
    const users = (variables.reviewers ?? []).map((value) => reviewerRef(value));
    const teams = (variables.team_reviewers ?? []).map((slug) => reviewerRef(`example/${slug}`));
    const entries = [...users, ...teams];
    const current = new Map(pullRequest.reviewers.map((reviewer) => [reviewer.key, reviewer]));
    if (method === 'POST') {
      for (const reviewer of entries) {
        current.set(reviewer.key, reviewer);
      }
    } else {
      for (const reviewer of entries) {
        current.delete(reviewer.key);
      }
    }
    pullRequest.reviewers = [...current.values()].sort((left, right) => left.key.localeCompare(right.key));
  };

  return (args) => {
    calls.push(args);

    if (args[0] === 'api' && args[1] === 'graphql') {
      const { query, variables } = parseGraphqlArgs(args);

      if (query.includes('resource(url: $url)')) {
        const target = byUrl.get(variables.url);
        return { data: { resource: target ? responseForTarget(target) : null } };
      }

      if (query.includes('repository(owner: $owner, name: $name)')) {
        return {
          data: {
            repository: {
              nameWithOwner: `${variables.owner}/${variables.name}`,
              issueTypes: { nodes: issueTypes },
              milestones: { nodes: milestones },
            },
          },
        };
      }

      if (query.includes('updateIssue(input:')) {
        const target = byId.get(variables.id);
        if (Object.prototype.hasOwnProperty.call(variables, 'issueTypeId')) {
          const issueTypeId = variables.issueTypeId;
          target.issueType = issueTypeId ? issueTypes.find((entry) => entry.id === issueTypeId) ?? null : null;
        }
        if (Object.prototype.hasOwnProperty.call(variables, 'milestoneId')) {
          const milestoneId = variables.milestoneId;
          target.milestone = milestoneId ? milestones.find((entry) => entry.id === milestoneId) ?? null : null;
        }
        return { data: { updateIssue: { issue: { id: target.id } } } };
      }

      if (query.includes('updatePullRequest(input:')) {
        const target = byId.get(variables.pullRequestId);
        const milestoneId = variables.milestoneId || null;
        target.milestone = milestoneId ? milestones.find((entry) => entry.id === milestoneId) ?? null : null;
        return { data: { updatePullRequest: { pullRequest: { id: target.id } } } };
      }

      if (query.includes('replaceActorsForAssignable')) {
        const target = byId.get(variables.assignableId);
        target.assignees = [...(variables.actorLogins ?? [])].sort((left, right) => left.localeCompare(right));
        return { data: { replaceActorsForAssignable: { assignable: { id: target.id } } } };
      }

      if (query.includes('addSubIssue(input:')) {
        const parent = byId.get(variables.issueId);
        const child = byId.get(variables.subIssueId);
        if (variables.replaceParent === 'true' && child.parentIssue && child.parentIssue.id !== parent.id) {
          const previousParent = byId.get(child.parentIssue.id);
          previousParent.subIssues = previousParent.subIssues.filter((entry) => entry.id !== child.id);
        }
        child.parentIssue = makeEntityRef(parent);
        if (!parent.subIssues.some((entry) => entry.id === child.id)) {
          parent.subIssues.push(makeEntityRef(child));
          parent.subIssues.sort((left, right) => left.url.localeCompare(right.url));
        }
        return { data: { addSubIssue: { issue: { id: parent.id } } } };
      }

      if (query.includes('removeSubIssue(input:')) {
        const parent = byId.get(variables.issueId);
        const child = byId.get(variables.subIssueId);
        parent.subIssues = parent.subIssues.filter((entry) => entry.id !== child.id);
        if (child.parentIssue?.id === parent.id) {
          child.parentIssue = null;
        }
        return { data: { removeSubIssue: { issue: { id: parent.id } } } };
      }
    }

    if (args[0] === 'api' && String(args[1]).includes('/requested_reviewers')) {
      const pullNumber = Number.parseInt(String(args[1]).split('/').slice(-2)[0], 10);
      const pullRequest = Object.values(targets).find((target) => target.contentType === 'PullRequest' && target.number === pullNumber);
      const { variables } = parseGraphqlArgs(args);
      const methodIndex = args.indexOf('--method');
      const method = methodIndex >= 0 ? args[methodIndex + 1] : 'POST';
      applyReviewers(pullRequest, method, variables);
      return {};
    }

    throw new Error(`Unexpected gh invocation: ${args.join(' ')}`);
  };
}

test('parseReviewerSpecifier accepts user and team reviewers and rejects malformed values', () => {
  assert.equal(metadataLib.parseReviewerSpecifier('alice').kind, 'User');
  assert.equal(metadataLib.parseReviewerSpecifier('example/reviewers').kind, 'Team');
  assert.throws(() => metadataLib.parseReviewerSpecifier('a/b/c'), /Invalid reviewer/);
});

test('resolveRequestedMetadata rejects conflicting clear/value combinations', () => {
  assert.throws(
    () => metadataLib.resolveRequestedMetadata({ url: 'https://github.com/example/repo/issues/1', milestone: 'Q2', clear_milestone: true }),
    /Use either --milestone or --clear-milestone/,
  );
});

test('runMetadataApply plans deterministic issue metadata changes in dry-run mode', () => {
  const parent = createIssue({
    id: 'ISSUE_PARENT',
    url: 'https://github.com/example/repo/issues/875',
    number: 875,
    title: 'Parent epic',
  });
  const child = createIssue({
    id: 'ISSUE_CHILD',
    url: 'https://github.com/example/repo/issues/960',
    number: 960,
    title: 'Child issue',
  });
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/949',
    number: 949,
    title: 'Metadata helper',
  });
  const calls = [];
  const runGhJsonFn = makeRunGhJson({
    targets: { parent, child, target },
    issueTypes: [
      { id: 'IT_FEATURE', name: 'Feature' },
      { id: 'IT_TASK', name: 'Task' },
    ],
    milestones: [
      { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
    ],
    calls,
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--dry-run',
      '--issue-type', 'Feature',
      '--milestone', '2',
      '--parent', parent.url,
      '--sub-issue', child.url,
      '--out', 'tests/results/_agent/issue/github-metadata-lib-dry-run.json',
    ],
    now: new Date('2026-03-09T18:00:00Z'),
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'planned');
  assert.equal(result.report.observed.projectedAfter.issueType.name, 'Feature');
  assert.equal(result.report.observed.projectedAfter.milestone.title, 'LabVIEW CI Platform v1 (2026Q2)');
  assert.equal(result.report.observed.projectedAfter.parentIssue.url, parent.url);
  assert.equal(result.report.observed.projectedAfter.subIssues[0].url, child.url);
  assert.equal(result.report.operations.filter((entry) => entry.status === 'planned').length, 4);
  assert.equal(calls.some((args) => args[1] === 'repos/example/repo/pulls/949/requested_reviewers'), false);
});

test('runMetadataApply applies pull-request milestone, assignee, and reviewer changes', () => {
  const target = createPullRequest({
    id: 'PR_TARGET',
    url: 'https://github.com/example/repo/pull/42',
    number: 42,
    title: 'Metadata helper PR',
    reviewers: [reviewerRef('legacy-reviewer')],
  });
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [
      { id: 'IT_FEATURE', name: 'Feature' },
    ],
    milestones: [
      { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
    ],
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--milestone', 'LabVIEW CI Platform v1 (2026Q2)',
      '--assignee', 'svelderrainruiz',
      '--reviewer', 'copilot-swe-agent',
      '--reviewer', 'example/reviewers',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-pr.json',
    ],
    now: new Date('2026-03-09T18:05:00Z'),
    env: {
      COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS: '1',
      COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS: '0',
    },
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'pass');
  assert.deepEqual(result.report.observed.after.assignees, ['svelderrainruiz']);
  assert.deepEqual(result.report.observed.after.reviewers, ['copilot-swe-agent', 'example/reviewers']);
  assert.equal(result.report.observed.after.milestone.number, 2);
});

test('runMetadataApply clears issue type and milestone during live issue apply', () => {
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/949',
    number: 949,
    title: 'Metadata helper',
    issueType: { id: 'IT_FEATURE', name: 'Feature' },
    milestone: { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
  });
  const calls = [];
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [
      { id: 'IT_FEATURE', name: 'Feature' },
      { id: 'IT_TASK', name: 'Task' },
    ],
    milestones: [
      { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
    ],
    calls,
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--clear-issue-type',
      '--clear-milestone',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-clear-issue.json',
    ],
    now: new Date('2026-03-09T18:06:00Z'),
    env: {
      COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS: '1',
      COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS: '0',
    },
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'pass');
  assert.equal(result.report.observed.after.issueType, null);
  assert.equal(result.report.observed.after.milestone, null);

  const issueMutationCalls = calls.filter((args) => {
    const { query } = parseGraphqlArgs(args);
    return query.includes('updateIssue(input:');
  });
  assert.equal(issueMutationCalls.length, 2);

  const issueTypeMutation = issueMutationCalls.find((args) => {
    const { variables } = parseGraphqlArgs(args);
    return Object.prototype.hasOwnProperty.call(variables, 'issueTypeId');
  });
  const milestoneMutation = issueMutationCalls.find((args) => {
    const { variables } = parseGraphqlArgs(args);
    return Object.prototype.hasOwnProperty.call(variables, 'milestoneId');
  });

  assert.ok(issueTypeMutation);
  assert.ok(milestoneMutation);
  assert.equal(parseGraphqlArgs(issueTypeMutation).variables.issueTypeId, null);
  assert.equal(parseGraphqlArgs(milestoneMutation).variables.milestoneId, null);
});

test('runMetadataApply updates issue type without clearing the existing milestone', () => {
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/950',
    number: 950,
    title: 'Metadata helper issue',
    issueType: { id: 'IT_TASK', name: 'Task' },
    milestone: { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
  });
  const calls = [];
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [
      { id: 'IT_FEATURE', name: 'Feature' },
      { id: 'IT_TASK', name: 'Task' },
    ],
    milestones: [
      { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
    ],
    calls,
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--issue-type', 'Feature',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-issue-type-only.json',
    ],
    now: new Date('2026-03-09T18:06:15Z'),
    env: {
      COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS: '1',
      COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS: '0',
    },
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'pass');
  assert.equal(result.report.observed.after.issueType.name, 'Feature');
  assert.equal(result.report.observed.after.milestone.title, 'LabVIEW CI Platform v1 (2026Q2)');

  const issueTypeMutation = calls.find((args) => {
    const { query, variables } = parseGraphqlArgs(args);
    return query.includes('updateIssue(input:') && Object.prototype.hasOwnProperty.call(variables, 'issueTypeId');
  });
  assert.ok(issueTypeMutation);
  const parsed = parseGraphqlArgs(issueTypeMutation);
  assert.match(parsed.query, /issueTypeId: \$issueTypeId/);
  assert.doesNotMatch(parsed.query, /milestoneId: \$milestoneId/);
  assert.equal(Object.prototype.hasOwnProperty.call(parsed.variables, 'milestoneId'), false);
});

test('runMetadataApply updates milestone without clearing the existing issue type', () => {
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/951',
    number: 951,
    title: 'Metadata helper issue',
    issueType: { id: 'IT_FEATURE', name: 'Feature' },
    milestone: null,
  });
  const calls = [];
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [
      { id: 'IT_FEATURE', name: 'Feature' },
      { id: 'IT_TASK', name: 'Task' },
    ],
    milestones: [
      { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
    ],
    calls,
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--milestone', 'LabVIEW CI Platform v1 (2026Q2)',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-milestone-only.json',
    ],
    now: new Date('2026-03-09T18:06:20Z'),
    env: {
      COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS: '1',
      COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS: '0',
    },
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'pass');
  assert.equal(result.report.observed.after.issueType.name, 'Feature');
  assert.equal(result.report.observed.after.milestone.title, 'LabVIEW CI Platform v1 (2026Q2)');

  const milestoneMutation = calls.find((args) => {
    const { query, variables } = parseGraphqlArgs(args);
    return query.includes('updateIssue(input:') && Object.prototype.hasOwnProperty.call(variables, 'milestoneId');
  });
  assert.ok(milestoneMutation);
  const parsed = parseGraphqlArgs(milestoneMutation);
  assert.match(parsed.query, /milestoneId: \$milestoneId/);
  assert.doesNotMatch(parsed.query, /issueTypeId: \$issueTypeId/);
  assert.equal(Object.prototype.hasOwnProperty.call(parsed.variables, 'issueTypeId'), false);
});

test('runMetadataApply clears milestone during live pull-request apply', () => {
  const target = createPullRequest({
    id: 'PR_TARGET',
    url: 'https://github.com/example/repo/pull/42',
    number: 42,
    title: 'Metadata helper PR',
    milestone: { id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' },
  });
  const calls = [];
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [{ id: 'IT_FEATURE', name: 'Feature' }],
    milestones: [{ id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' }],
    calls,
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--clear-milestone',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-clear-pr.json',
    ],
    now: new Date('2026-03-09T18:06:30Z'),
    env: {
      COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS: '1',
      COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS: '0',
    },
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'pass');
  assert.equal(result.report.observed.after.milestone, null);

  const pullRequestMutationCall = calls.find((args) => {
    const { query } = parseGraphqlArgs(args);
    return query.includes('updatePullRequest(input:');
  });
  const { variables } = parseGraphqlArgs(pullRequestMutationCall);
  assert.ok(Object.prototype.hasOwnProperty.call(variables, 'milestoneId'));
  assert.equal(variables.milestoneId, null);
});

test('runMetadataApply normalizes Windows caret-escaped milestone values from the npm wrapper', () => {
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/949',
    number: 949,
    title: 'Metadata helper',
  });
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [{ id: 'IT_FEATURE', name: 'Feature' }],
    milestones: [{ id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' }],
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--dry-run',
      '--milestone', 'LabVIEW CI Platform v1 (2026Q2)^',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-caret.json',
    ],
    now: new Date('2026-03-09T18:07:00Z'),
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.execution.status, 'planned');
  assert.equal(result.report.resolved.milestone.value.title, 'LabVIEW CI Platform v1 (2026Q2)');
});

test('runMetadataApply reports unsupported reviewer mutations on issues', () => {
  const target = createIssue({
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/951',
    number: 951,
    title: 'Epic issue',
  });
  const runGhJsonFn = makeRunGhJson({
    targets: { target },
    issueTypes: [{ id: 'IT_FEATURE', name: 'Feature' }],
    milestones: [{ id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' }],
  });

  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--reviewer', 'copilot-swe-agent',
      '--out', 'tests/results/_agent/issue/github-metadata-lib-unsupported.json',
    ],
    now: new Date('2026-03-09T18:10:00Z'),
    runGhJsonFn,
  });

  assert.equal(result.exitCode, 1);
  const reviewerOp = result.report.operations.find((entry) => entry.surface === 'reviewers');
  assert.equal(reviewerOp.status, 'unsupported');
  assert.equal(result.report.execution.status, 'fail');
});
