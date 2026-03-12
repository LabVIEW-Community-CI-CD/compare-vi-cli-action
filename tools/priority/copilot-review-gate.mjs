#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

export const COPILOT_REVIEW_GATE_SCHEMA = 'priority/copilot-review-gate@v1';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'copilot-review-gate.json',
);
const DEFAULT_GATED_BASE_REFS = ['develop'];
const DEFAULT_POLL_ATTEMPTS = 1;
const DEFAULT_POLL_DELAY_MS = 10000;
const GITHUB_API_URL = 'https://api.github.com';
const CANONICAL_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';

const COPILOT_LOGINS = new Set([
  'copilot',
  'copilot-pull-request-reviewer',
  'copilot-pull-request-reviewer[bot]',
]);

const REVIEW_THREADS_QUERY = [
  'query($owner:String!,$repo:String!,$number:Int!){',
  'repository(owner:$owner,name:$repo){',
  'pullRequest(number:$number){',
  'reviewThreads(first:100){',
  'pageInfo{',
  'hasNextPage',
  'endCursor',
  '}',
  'nodes{',
  'id',
  'isResolved',
  'isOutdated',
  'path',
  'line',
  'originalLine',
  'comments(first:100){',
  'pageInfo{',
  'hasNextPage',
  'endCursor',
  '}',
  'nodes{',
  'id',
  'body',
  'createdAt',
  'publishedAt',
  'url',
  'author{login}',
  'originalCommit{oid}',
  'pullRequestReview{',
  'databaseId',
  'state',
  'author{login}',
  'submittedAt',
  'commit{oid}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}',
  '}',
].join(' ');

function normalizeText(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeSha(value) {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeBoolean(value) {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (normalized === 'true') return true;
    if (normalized === 'false') return false;
  }
  return null;
}

function normalizeInteger(value) {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const normalized = value.trim();
    if (normalized.length === 0) {
      return null;
    }
    const parsed = Number.parseInt(normalized, 10);
    return Number.isInteger(parsed) ? parsed : null;
  }
  return null;
}

function parsePositiveInteger(value, { label }) {
  const parsed = normalizeInteger(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`Invalid ${label} value '${value}'. Expected a positive integer.`);
  }
  return parsed;
}

function normalizeIso(value) {
  if (value === null || value === undefined) {
    return null;
  }
  const parsed = new Date(String(value));
  if (Number.isNaN(parsed.valueOf())) {
    return null;
  }
  return parsed.toISOString();
}

function summarizeBody(body, maxLength = 160) {
  const normalized = normalizeText(body);
  if (!normalized) {
    return null;
  }
  const collapsed = normalized.replace(/\s+/g, ' ');
  if (collapsed.length <= maxLength) {
    return collapsed;
  }
  return `${collapsed.slice(0, maxLength - 3)}...`;
}

function compareIsoDescending(left, right) {
  if (left && right) {
    return right.localeCompare(left);
  }
  if (left) {
    return -1;
  }
  if (right) {
    return 1;
  }
  return 0;
}

function compareIdDescending(left, right) {
  return right.localeCompare(left, undefined, { numeric: true });
}

function normalizeBaseRef(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return null;
  }
  const refsHeadsPrefix = 'refs/heads/';
  if (normalized.toLowerCase().startsWith(refsHeadsPrefix)) {
    return normalized.slice(refsHeadsPrefix.length);
  }
  return normalized;
}

function normalizeBaseRefList(value) {
  const normalized = normalizeText(value);
  if (!normalized) {
    return [...DEFAULT_GATED_BASE_REFS];
  }
  return normalized
    .split(',')
    .map((item) => normalizeBaseRef(item)?.toLowerCase())
    .filter((item) => Boolean(item));
}

export function parseRepoSlug(repo) {
  const normalized = normalizeText(repo);
  if (!normalized) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }

  const segments = normalized.split('/').map((segment) => segment.trim());
  if (segments.length !== 2 || segments.some((segment) => segment.length === 0)) {
    throw new Error(`Invalid repository slug '${repo}'. Expected <owner>/<repo>.`);
  }

  const [owner, repoName] = segments;
  return { owner, repo: repoName };
}

function isCanonicalRepository(repo) {
  const normalized = normalizeText(repo)?.toLowerCase();
  return normalized === CANONICAL_REPOSITORY.toLowerCase();
}

function isCopilotLogin(login) {
  const normalized = normalizeText(login)?.toLowerCase();
  return normalized ? COPILOT_LOGINS.has(normalized) : false;
}

function printUsage() {
  const lines = [
    'Usage: node tools/priority/copilot-review-gate.mjs [options]',
    '',
    'Evaluate whether a ready develop PR is allowed into the merge queue after Copilot review.',
    '',
    'Options:',
    '  --event-name <name>        Workflow event name (pull_request_target, pull_request_review, pull_request_review_thread, merge_group).',
    '  --repo <owner/repo>        Repository slug used for live GitHub API lookups.',
    '  --pr <number>              Pull request number for live lookups.',
    '  --head-sha <sha>           Current pull request head SHA.',
    '  --base-ref <branch>        Pull request base ref or merge-group base ref.',
    '  --draft <true|false>       Whether the pull request is currently a draft.',
    '  --signal <path>            Optional Copilot review signal report produced on pull_request_target.',
    `  --poll-attempts <n>        Live poll attempts when the initial Copilot review is missing (default: ${DEFAULT_POLL_ATTEMPTS}).`,
    `  --poll-delay-ms <n>        Delay between live poll attempts in milliseconds (default: ${DEFAULT_POLL_DELAY_MS}).`,
    `  --out <path>               Output JSON path (default: ${DEFAULT_REPORT_PATH}).`,
    '  --step-summary <path>      Optional GitHub step summary path.',
    `  --gated-base-refs <csv>    Branches that require the queue gate (default: ${DEFAULT_GATED_BASE_REFS.join(',')}).`,
    '  -h, --help                 Show help.',
  ];

  for (const line of lines) {
    console.log(line);
  }
}

export function parseCliArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    help: false,
    eventName: 'pull_request_target',
    repo: null,
    prNumber: null,
    headSha: null,
    baseRef: null,
    draft: null,
    signalPath: null,
    pollAttempts: DEFAULT_POLL_ATTEMPTS,
    pollDelayMs: DEFAULT_POLL_DELAY_MS,
    outPath: DEFAULT_REPORT_PATH,
    stepSummaryPath: null,
    gatedBaseRefs: [...DEFAULT_GATED_BASE_REFS],
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--event-name' ||
      token === '--repo' ||
      token === '--pr' ||
      token === '--head-sha' ||
      token === '--base-ref' ||
      token === '--draft' ||
      token === '--signal' ||
      token === '--poll-attempts' ||
      token === '--poll-delay-ms' ||
      token === '--out' ||
      token === '--step-summary' ||
      token === '--gated-base-refs'
    ) {
      if (next === undefined) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--event-name') options.eventName = normalizeText(next) ?? options.eventName;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      if (token === '--head-sha') options.headSha = normalizeSha(next);
      if (token === '--base-ref') options.baseRef = normalizeBaseRef(next);
      if (token === '--draft') options.draft = normalizeBoolean(next);
      if (token === '--signal') options.signalPath = normalizeText(next);
      if (token === '--poll-attempts') options.pollAttempts = parsePositiveInteger(next, { label: '--poll-attempts' });
      if (token === '--poll-delay-ms') options.pollDelayMs = parsePositiveInteger(next, { label: '--poll-delay-ms' });
      if (token === '--out') options.outPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      if (token === '--gated-base-refs') options.gatedBaseRefs = normalizeBaseRefList(next);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (options.eventName !== 'merge_group' && !options.signalPath) {
      if (!options.repo) {
        throw new Error('Repository slug is required. Pass --repo <owner/repo>.');
      }
      if (options.prNumber === null) {
        throw new Error('Pull request number is required. Pass --pr <number>.');
      }
      if (!options.headSha) {
        throw new Error('Head SHA is required. Pass --head-sha <sha>.');
      }
    }
  }

  return options;
}

function getAuthToken(env = process.env) {
  return normalizeText(env.GH_TOKEN) ?? normalizeText(env.GITHUB_TOKEN);
}

async function githubRequestJson(url, { method = 'GET', body = null, token } = {}) {
  const resolvedToken = normalizeText(token);
  if (!resolvedToken) {
    throw new Error('GitHub token is required for live Copilot queue gate lookups.');
  }

  const headers = {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${resolvedToken}`,
    'User-Agent': 'copilot-review-gate',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  if (body !== null) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetch(url, {
    method,
    headers,
    body: body === null ? undefined : JSON.stringify(body),
  });

  const rawText = await response.text();
  let payload = null;
  if (rawText.length > 0) {
    try {
      payload = JSON.parse(rawText);
    } catch (error) {
      if (response.ok) {
        throw new Error(`GitHub API returned non-JSON payload for ${url}.`);
      }
    }
  }

  if (!response.ok) {
    const apiMessage = normalizeText(payload?.message) ?? normalizeText(rawText);
    throw new Error(
      `GitHub API ${method} ${url} failed (${response.status} ${response.statusText})${
        apiMessage ? `: ${apiMessage}` : ''
      }.`,
    );
  }

  return payload;
}

async function loadLiveReviews(options, token = getAuthToken()) {
  if (!options.repo || options.prNumber === null) {
    throw new Error('Live review lookups require both --repo and --pr.');
  }

  const reviews = [];
  for (let page = 1; page <= 10; page += 1) {
    const payload = await githubRequestJson(
      `${GITHUB_API_URL}/repos/${options.repo}/pulls/${options.prNumber}/reviews?per_page=100&page=${page}`,
      { token },
    );
    if (!Array.isArray(payload)) {
      throw new Error('GitHub review payload was not an array.');
    }
    reviews.push(...payload);
    if (payload.length < 100) {
      return reviews;
    }
  }

  throw new Error('GitHub review payload exceeded 1000 reviews. Pagination guard requires a narrower implementation.');
}

async function loadLiveThreads(options, token = getAuthToken()) {
  if (!options.repo || options.prNumber === null) {
    throw new Error('Live review-thread lookups require both --repo and --pr.');
  }

  const { owner, repo } = parseRepoSlug(options.repo);
  const payload = await githubRequestJson(`${GITHUB_API_URL}/graphql`, {
    method: 'POST',
    token,
    body: {
      query: REVIEW_THREADS_QUERY,
      variables: {
        owner,
        repo,
        number: options.prNumber,
      },
    },
  });

  if (Array.isArray(payload?.errors) && payload.errors.length > 0) {
    const messages = payload.errors
      .map((entry) => normalizeText(entry?.message))
      .filter((entry) => Boolean(entry));
    throw new Error(`GitHub GraphQL review-thread query failed: ${messages.join('; ')}`);
  }

  return payload;
}

function readJsonFile(filePath) {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!existsSync(resolved)) {
    throw new Error(`JSON file not found: ${resolved}`);
  }
  return JSON.parse(readFileSync(resolved, 'utf8'));
}

function extractThreadNodes(payload) {
  if (Array.isArray(payload)) {
    return payload;
  }
  const nodes = payload?.data?.repository?.pullRequest?.reviewThreads?.nodes;
  return Array.isArray(nodes) ? nodes : [];
}

function detectThreadPaginationErrors(payload) {
  if (Array.isArray(payload)) {
    return [];
  }

  const errors = [];
  const reviewThreads = payload?.data?.repository?.pullRequest?.reviewThreads;
  if (reviewThreads?.pageInfo?.hasNextPage) {
    errors.push(
      'Review-thread payload exceeded the first 100 threads. Pagination is required before this queue gate can be trusted.',
    );
  }

  const nodes = Array.isArray(reviewThreads?.nodes) ? reviewThreads.nodes : [];
  for (const thread of nodes) {
    if (thread?.comments?.pageInfo?.hasNextPage) {
      const threadId = normalizeText(thread?.id) ?? 'thread:unknown';
      errors.push(
        `Review-thread comments for ${threadId} exceeded the first 100 comments. Pagination is required before this queue gate can be trusted.`,
      );
    }
  }

  return errors;
}

function normalizeComment(comment, headSha) {
  const authorLogin = comment?.author?.login ?? comment?.pullRequestReview?.author?.login ?? null;
  if (!isCopilotLogin(authorLogin)) {
    return null;
  }

  const commitId = normalizeSha(comment?.pullRequestReview?.commit?.oid ?? comment?.originalCommit?.oid);
  return {
    id: normalizeText(comment?.id) ?? 'comment:unknown',
    url: normalizeText(comment?.url),
    publishedAt: normalizeIso(comment?.publishedAt ?? comment?.createdAt),
    commitId,
    reviewId: normalizeInteger(comment?.pullRequestReview?.databaseId)?.toString() ?? null,
    reviewState: normalizeText(comment?.pullRequestReview?.state),
    isCurrentHead: Boolean(headSha && commitId && commitId === headSha),
    snippet: summarizeBody(comment?.body),
  };
}

function normalizeThread(thread, headSha) {
  const comments = Array.isArray(thread?.comments?.nodes)
    ? thread.comments.nodes
        .map((comment) => normalizeComment(comment, headSha))
        .filter((comment) => comment !== null)
    : [];

  if (comments.length === 0) {
    return null;
  }

  const sortedComments = [...comments].sort((left, right) => {
    const byTime = compareIsoDescending(left.publishedAt, right.publishedAt);
    if (byTime !== 0) {
      return byTime;
    }
    return compareIdDescending(left.id, right.id);
  });

  const actionableComments = comments.filter((comment) => comment.isCurrentHead);
  return {
    threadId: normalizeText(thread?.id) ?? 'thread:unknown',
    path: normalizeText(thread?.path),
    line: normalizeInteger(thread?.line),
    originalLine: normalizeInteger(thread?.originalLine),
    isResolved: Boolean(thread?.isResolved),
    isOutdated: Boolean(thread?.isOutdated),
    copilotCommentCount: comments.length,
    currentHeadCommentCount: actionableComments.length,
    staleCommentCount: comments.filter((comment) => !comment.isCurrentHead).length,
    actionable: !thread?.isResolved && !thread?.isOutdated && actionableComments.length > 0,
    latestComment: sortedComments[0] ?? null,
    actionableComments,
  };
}

function normalizeReviews(reviews, headSha) {
  return reviews
    .filter((review) => isCopilotLogin(review?.user?.login))
    .map((review) => ({
      id: normalizeInteger(review?.id)?.toString() ?? normalizeText(review?.id) ?? 'review:unknown',
      state: normalizeText(review?.state),
      commitId: normalizeSha(review?.commit_id),
      submittedAt: normalizeIso(review?.submitted_at),
      url: normalizeText(review?.html_url),
      isCurrentHead: Boolean(headSha && normalizeSha(review?.commit_id) === headSha),
      bodySummary: summarizeBody(review?.body),
    }))
    .sort((left, right) => {
      const byTime = compareIsoDescending(left.submittedAt, right.submittedAt);
      if (byTime !== 0) {
        return byTime;
      }
      return compareIdDescending(left.id, right.id);
    });
}

function buildPullRequest(options, signalReport = null) {
  const signalPull = signalReport?.pullRequest ?? {};
  const repository = normalizeText(signalReport?.repository) ?? normalizeText(options.repo);
  const number = normalizeInteger(signalPull.number) ?? options.prNumber;
  return {
    number,
    url:
      normalizeText(signalPull.url) ??
      (repository && number !== null ? `https://github.com/${repository}/pull/${number}` : null),
    baseRef: normalizeBaseRef(signalPull.baseRef ?? options.baseRef),
    draft: normalizeBoolean(signalPull.draft) ?? options.draft ?? false,
    headSha: normalizeSha(signalPull.headSha ?? options.headSha),
  };
}

function sleep(delayMs) {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}

function evaluateGateOutcome({
  eventName,
  repository,
  sourceMode,
  pullRequest,
  reviews,
  threads,
  errors = [],
  gatedBaseRefs,
  now,
}) {
  const reasons = [];
  const normalizedBaseRef = normalizeBaseRef(pullRequest.baseRef)?.toLowerCase() ?? null;
  const canonicalRepository = isCanonicalRepository(repository);
  const gateApplies =
    eventName !== 'merge_group' &&
    pullRequest.draft !== true &&
    Boolean(normalizedBaseRef && gatedBaseRefs.includes(normalizedBaseRef) && canonicalRepository);

  const summary = {
    copilotReviewCount: reviews.length,
    currentHeadReviewCount: reviews.filter((review) => review.isCurrentHead).length,
    staleReviewCount: reviews.filter((review) => !review.isCurrentHead).length,
    actionableThreadCount: threads.filter((thread) => thread.actionable).length,
    actionableCommentCount: threads.reduce(
      (total, thread) => total + thread.actionableComments.length,
      0,
    ),
    latestReviewSubmittedAt: reviews[0]?.submittedAt ?? null,
  };

  const latestCopilotReview = reviews[0]
    ? {
        id: reviews[0].id,
        state: reviews[0].state,
        commitId: reviews[0].commitId,
        submittedAt: reviews[0].submittedAt,
        url: reviews[0].url,
        isCurrentHead: reviews[0].isCurrentHead,
        bodySummary: reviews[0].bodySummary,
      }
    : null;

  const actionableThreads = threads
    .filter((thread) => thread.actionable)
    .map((thread) => ({
      threadId: thread.threadId,
      path: thread.path,
      line: thread.line,
      originalLine: thread.originalLine,
      copilotCommentCount: thread.copilotCommentCount,
      currentHeadCommentCount: thread.currentHeadCommentCount,
      staleCommentCount: thread.staleCommentCount,
      latestComment: thread.latestComment,
    }));
  const staleReviewCleanFollowup =
    Boolean(latestCopilotReview) &&
    eventName !== 'pull_request_target' &&
    latestCopilotReview.isCurrentHead === false &&
    summary.currentHeadReviewCount === 0 &&
    summary.staleReviewCount > 0 &&
    summary.actionableThreadCount === 0 &&
    summary.actionableCommentCount === 0;

  let status = 'pass';
  let gateState = 'ready';

  if (eventName === 'merge_group') {
    gateState = 'skipped';
    reasons.push('merge-group-skip');
  } else if (pullRequest.draft === true) {
    gateState = 'skipped';
    reasons.push('draft-pr-skip');
  } else if (!normalizedBaseRef || !gatedBaseRefs.includes(normalizedBaseRef)) {
    gateState = 'skipped';
    reasons.push('base-ref-not-gated');
  } else if (!canonicalRepository) {
    gateState = 'skipped';
    reasons.push('throughput-fork-skip');
  } else if (errors.length > 0) {
    status = 'fail';
    gateState = 'error';
    reasons.push('copilot-review-data-error');
  } else if (!latestCopilotReview) {
    status = 'fail';
    gateState = 'blocked';
    reasons.push('copilot-review-missing');
  } else if (!latestCopilotReview.isCurrentHead || summary.currentHeadReviewCount === 0) {
    if (staleReviewCleanFollowup) {
      reasons.push('stale-review-clean-followup');
    } else {
      status = 'fail';
      gateState = 'blocked';
      reasons.push('current-head-review-missing');
      if (!latestCopilotReview.isCurrentHead) {
        reasons.push('latest-review-stale');
      }
    }
  } else if (summary.actionableThreadCount > 0 || summary.actionableCommentCount > 0) {
    status = 'fail';
    gateState = 'blocked';
    reasons.push('actionable-comments-present');
  } else {
    reasons.push('current-head-review-clean');
  }

  return {
    schema: COPILOT_REVIEW_GATE_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status,
    gateState,
    repository,
    source: {
      mode: sourceMode,
      eventName,
    },
    pullRequest: {
      number: pullRequest.number,
      url: pullRequest.url,
      baseRef: pullRequest.baseRef,
      draft: pullRequest.draft,
      headSha: pullRequest.headSha,
    },
    summary,
    signals: {
      gateApplies,
      hasCopilotReview: summary.copilotReviewCount > 0,
      hasCurrentHeadReview: summary.currentHeadReviewCount > 0,
      latestReviewIsCurrentHead: latestCopilotReview?.isCurrentHead ?? false,
      hasActionableCurrentHeadComments: summary.actionableCommentCount > 0,
      staleReviewCleanFollowup,
    },
    latestCopilotReview,
    actionableThreads,
    reasons,
    errors,
  };
}

function buildReportFromSignal(options, signalReport, now) {
  if (signalReport?.schema !== 'priority/copilot-review-signal@v1') {
    throw new Error(
      `Unsupported Copilot review signal schema '${signalReport?.schema ?? 'unknown'}'.`,
    );
  }

  const pullRequest = buildPullRequest(options, signalReport);
  const latestReview = signalReport.latestCopilotReview
    ? [
        {
          id: normalizeText(signalReport.latestCopilotReview.id) ?? 'review:unknown',
          state: normalizeText(signalReport.latestCopilotReview.state),
          commitId: normalizeSha(signalReport.latestCopilotReview.commitId),
          submittedAt: normalizeIso(signalReport.latestCopilotReview.submittedAt),
          url: normalizeText(signalReport.latestCopilotReview.url),
          isCurrentHead: Boolean(signalReport.latestCopilotReview.isCurrentHead),
          bodySummary: summarizeBody(signalReport.latestCopilotReview.bodySummary),
        },
      ]
    : [];

  const staleReviews = Array.isArray(signalReport.staleReviews)
    ? signalReport.staleReviews.map((review) => ({
        id: normalizeText(review?.id) ?? 'review:unknown',
        state: normalizeText(review?.state),
        commitId: normalizeSha(review?.commitId),
        submittedAt: normalizeIso(review?.submittedAt),
        url: normalizeText(review?.url),
        isCurrentHead: false,
        bodySummary: summarizeBody(review?.bodySummary),
      }))
    : [];

  const reviews = [...latestReview, ...staleReviews].sort((left, right) => {
    const byTime = compareIsoDescending(left.submittedAt, right.submittedAt);
    if (byTime !== 0) {
      return byTime;
    }
    return compareIdDescending(left.id, right.id);
  });

  const actionableThreads = Array.isArray(signalReport.unresolvedThreads)
    ? signalReport.unresolvedThreads
        .filter((thread) => Boolean(thread?.actionable))
        .map((thread) => ({
          threadId: normalizeText(thread?.threadId) ?? 'thread:unknown',
          path: normalizeText(thread?.path),
          line: normalizeInteger(thread?.line),
          originalLine: normalizeInteger(thread?.originalLine),
          copilotCommentCount: normalizeInteger(thread?.copilotCommentCount) ?? 0,
          currentHeadCommentCount: normalizeInteger(thread?.currentHeadCommentCount) ?? 0,
          staleCommentCount: normalizeInteger(thread?.staleCommentCount) ?? 0,
          actionable: true,
          latestComment: thread?.latestComment
            ? {
                id: normalizeText(thread.latestComment.id) ?? 'comment:unknown',
                url: normalizeText(thread.latestComment.url),
                publishedAt: normalizeIso(thread.latestComment.publishedAt),
                commitId: normalizeSha(thread.latestComment.commitId),
                reviewId: normalizeText(thread.latestComment.reviewId),
                reviewState: normalizeText(thread.latestComment.reviewState),
                isCurrentHead: Boolean(thread.latestComment.isCurrentHead),
                snippet: summarizeBody(thread.latestComment.snippet),
              }
            : null,
          actionableComments: Array.isArray(signalReport.actionableComments)
            ? signalReport.actionableComments
                .filter((comment) => normalizeText(comment?.threadId) === normalizeText(thread?.threadId))
                .map((comment) => ({
                  id: normalizeText(comment?.id) ?? 'comment:unknown',
                  url: normalizeText(comment?.url),
                  publishedAt: normalizeIso(comment?.publishedAt),
                  commitId: normalizeSha(comment?.commitId),
                  reviewId: normalizeText(comment?.reviewId),
                  reviewState: normalizeText(comment?.reviewState),
                  isCurrentHead: true,
                  snippet: summarizeBody(comment?.snippet),
                }))
            : [],
        }))
    : [];

  const errors = Array.isArray(signalReport.errors)
    ? signalReport.errors.map((entry) => normalizeText(entry)).filter((entry) => Boolean(entry))
    : [];

  return evaluateGateOutcome({
    eventName: options.eventName,
    repository: normalizeText(signalReport.repository) ?? normalizeText(options.repo),
    sourceMode: 'signal',
    pullRequest,
    reviews,
    threads: actionableThreads,
    errors,
    gatedBaseRefs: options.gatedBaseRefs,
    now,
  });
}

function buildReportFromLiveData(options, reviewsPayload, threadsPayload, now) {
  const pullRequest = buildPullRequest(options);
  const reviews = normalizeReviews(reviewsPayload, pullRequest.headSha);
  const threads = extractThreadNodes(threadsPayload)
    .map((thread) => normalizeThread(thread, pullRequest.headSha))
    .filter((thread) => thread !== null);
  const errors = detectThreadPaginationErrors(threadsPayload);

  return evaluateGateOutcome({
    eventName: options.eventName,
    repository: normalizeText(options.repo),
    sourceMode: 'live',
    pullRequest,
    reviews,
    threads,
    errors,
    gatedBaseRefs: options.gatedBaseRefs,
    now,
  });
}

function buildFailureReport(options, now, error) {
  const pullRequest = buildPullRequest(options);
  return {
    schema: COPILOT_REVIEW_GATE_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'fail',
    gateState: 'error',
    repository: normalizeText(options.repo),
    source: {
      mode: options.eventName === 'merge_group' ? 'merge-group' : 'live',
      eventName: options.eventName,
    },
    pullRequest: {
      number: pullRequest.number,
      url: pullRequest.url,
      baseRef: pullRequest.baseRef,
      draft: pullRequest.draft,
      headSha: pullRequest.headSha,
    },
    summary: {
      copilotReviewCount: 0,
      currentHeadReviewCount: 0,
      staleReviewCount: 0,
      actionableThreadCount: 0,
      actionableCommentCount: 0,
      latestReviewSubmittedAt: null,
    },
    signals: {
      gateApplies: false,
      hasCopilotReview: false,
      hasCurrentHeadReview: false,
      latestReviewIsCurrentHead: false,
      hasActionableCurrentHeadComments: false,
      staleReviewCleanFollowup: false,
    },
    latestCopilotReview: null,
    actionableThreads: [],
    reasons: ['copilot-review-data-error'],
    errors: [error.message ?? String(error)],
  };
}

function writeReport(reportPath, report) {
  const resolved = path.resolve(process.cwd(), reportPath);
  mkdirSync(path.dirname(resolved), { recursive: true });
  writeFileSync(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function appendStepSummary(stepSummaryPath, report) {
  if (!stepSummaryPath) {
    return;
  }

  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  mkdirSync(path.dirname(resolved), { recursive: true });

  const lines = [
    '### Copilot Queue Gate',
    '',
    `- status: \`${report.status}\``,
    `- gate_state: \`${report.gateState}\``,
    `- source_mode: \`${report.source.mode}\``,
    `- event_name: \`${report.source.eventName}\``,
    `- repository: \`${report.repository ?? 'unknown'}\``,
    `- pull_request: \`#${report.pullRequest.number ?? 'unknown'}\``,
    `- base_ref: \`${report.pullRequest.baseRef ?? 'unknown'}\``,
    `- draft: \`${report.pullRequest.draft}\``,
    `- head_sha: \`${report.pullRequest.headSha ?? 'unknown'}\``,
    `- current_head_review_count: \`${report.summary.currentHeadReviewCount}\``,
    `- actionable_current_head_threads: \`${report.summary.actionableThreadCount}\``,
    `- actionable_current_head_comments: \`${report.summary.actionableCommentCount}\``,
    `- stale_review_clean_followup: \`${report.signals.staleReviewCleanFollowup}\``,
    `- reasons: \`${report.reasons.join(', ') || 'none'}\``,
  ];

  if (report.poll) {
    lines.push(`- poll_attempts_used: \`${report.poll.attemptsUsed}/${report.poll.attemptsRequested}\``);
    lines.push(`- poll_delay_ms: \`${report.poll.delayMs}\``);
  }

  if (report.latestCopilotReview) {
    lines.push(`- latest_review_commit: \`${report.latestCopilotReview.commitId ?? 'unknown'}\``);
    lines.push(
      `- latest_review_submitted_at: \`${report.latestCopilotReview.submittedAt ?? 'unknown'}\``,
    );
  }

  if (report.actionableThreads.length > 0) {
    lines.push('', '#### Actionable Copilot Threads', '');
    for (const thread of report.actionableThreads.slice(0, 5)) {
      const location = [thread.path ?? 'unknown-path', thread.line ?? '?'].join(':');
      lines.push(
        `- \`${location}\`${thread.latestComment?.url ? ` ${thread.latestComment.url}` : ''}${
          thread.latestComment?.snippet ? ` - ${thread.latestComment.snippet}` : ''
        }`,
      );
    }
  }

  if (report.errors.length > 0) {
    lines.push('', '#### Errors', '');
    for (const error of report.errors) {
      lines.push(`- ${error}`);
    }
  }

  writeFileSync(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' });
}

function isMissingInitialCopilotReview(report) {
  return (
    report?.status === 'fail' &&
    Array.isArray(report?.reasons) &&
    report.reasons.length === 1 &&
    report.reasons[0] === 'copilot-review-missing'
  );
}

function isWaitingForCurrentHeadCopilotReview(report) {
  return (
    report?.status === 'fail' &&
    Array.isArray(report?.reasons) &&
    report.reasons.includes('current-head-review-missing')
  );
}

function shouldPollForInitialCopilotReview(report, options) {
  return (
    options.eventName === 'pull_request_target' &&
    options.pollAttempts > 1 &&
    (isMissingInitialCopilotReview(report) || isWaitingForCurrentHeadCopilotReview(report))
  );
}

export async function runCopilotReviewGate({
  argv = process.argv,
  now = new Date(),
  readSignalFn = readJsonFile,
  loadReviewsFn = loadLiveReviews,
  loadThreadsFn = loadLiveThreads,
  writeReportFn = writeReport,
  appendStepSummaryFn = appendStepSummary,
} = {}) {
  const options = parseCliArgs(argv);
  if (options.help) {
    printUsage();
    return {
      exitCode: 0,
      report: null,
      reportPath: null,
    };
  }

  let exitCode = 0;
  let report;

  try {
    const signalPathExists = options.signalPath && existsSync(path.resolve(process.cwd(), options.signalPath));
    const signalReport = signalPathExists ? readSignalFn(options.signalPath) : null;
    const preflightPullRequest = buildPullRequest(options, signalReport);
    const preflightBaseRef = normalizeBaseRef(preflightPullRequest.baseRef)?.toLowerCase() ?? null;
    const preflightRepository =
      normalizeText(signalReport?.repository) ??
      normalizeText(options.repo);
    const shouldSkipWithoutLookup =
      options.eventName === 'merge_group' ||
      preflightPullRequest.draft === true ||
      !preflightBaseRef ||
      !options.gatedBaseRefs.includes(preflightBaseRef) ||
      (preflightRepository !== null && !isCanonicalRepository(preflightRepository));

    if (shouldSkipWithoutLookup) {
      report = evaluateGateOutcome({
        eventName: options.eventName,
        repository: preflightRepository,
        sourceMode: options.eventName === 'merge_group' ? 'merge-group' : 'metadata',
        pullRequest: preflightPullRequest,
        reviews: [],
        threads: [],
        errors: [],
        gatedBaseRefs: options.gatedBaseRefs,
        now,
      });
    } else if (signalReport) {
      report = buildReportFromSignal(options, signalReport, now);
    } else {
      const reviews = await loadReviewsFn(options);
      const threads = await loadThreadsFn(options);
      report = buildReportFromLiveData(options, reviews, threads, now);
    }

    if (shouldPollForInitialCopilotReview(report, options)) {
      let attemptsUsed = 1;
      while (attemptsUsed < options.pollAttempts) {
        attemptsUsed += 1;
        await sleep(options.pollDelayMs);
        const reviews = await loadReviewsFn(options);
        const threads = await loadThreadsFn(options);
        report = buildReportFromLiveData(options, reviews, threads, now);
        if (!isMissingInitialCopilotReview(report)) {
          break;
        }
      }

      report = {
        ...report,
        poll: {
          attemptsRequested: options.pollAttempts,
          attemptsUsed,
          delayMs: options.pollDelayMs,
        },
      };
    }

    if (report.status !== 'pass') {
      exitCode = 1;
    }
  } catch (error) {
    exitCode = 1;
    report = buildFailureReport(options, now, error instanceof Error ? error : new Error(String(error)));
  }

  const reportPath = writeReportFn(options.outPath, report);
  appendStepSummaryFn(options.stepSummaryPath, report);

  console.log(`[copilot-review-gate] report: ${reportPath}`);
  if (report.status === 'pass') {
    console.log(
      `[copilot-review-gate] gateState=${report.gateState} reasons=${report.reasons.join(',') || 'none'}`,
    );
  } else {
    console.error(`[copilot-review-gate] ${report.errors.join('; ') || report.reasons.join('; ')}`);
  }

  return {
    exitCode,
    report,
    reportPath,
  };
}

const isDirectRun =
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isDirectRun) {
  try {
    const result = await runCopilotReviewGate();
    process.exit(result.exitCode);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    process.exit(1);
  }
}
