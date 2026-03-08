#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

export const REVIEW_SIGNAL_SCHEMA = 'priority/copilot-review-signal@v1';
export const DEFAULT_REPORT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'copilot-review-signal.json',
);
export const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;

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

interface CliOptions {
  help: boolean;
  repo: string | null;
  prNumber: number | null;
  headSha: string | null;
  outPath: string;
  stepSummaryPath: string | null;
  pullFile: string | null;
  reviewsFile: string | null;
  threadsFile: string | null;
}

interface PullPayload {
  number?: number;
  html_url?: string;
  state?: string;
  draft?: boolean;
  updated_at?: string;
  user?: {
    login?: string;
  };
  head?: {
    sha?: string;
    ref?: string;
  };
  base?: {
    ref?: string;
    repo?: {
      full_name?: string;
    };
  };
}

interface ReviewPayload {
  id?: number | string;
  state?: string;
  body?: string;
  html_url?: string;
  submitted_at?: string;
  commit_id?: string;
  user?: {
    login?: string;
  };
}

interface ReviewThreadCommentPayload {
  id?: string;
  body?: string;
  createdAt?: string;
  publishedAt?: string;
  url?: string;
  author?: {
    login?: string;
  };
  originalCommit?: {
    oid?: string;
  };
  pullRequestReview?: {
    databaseId?: number;
    state?: string;
    submittedAt?: string;
    author?: {
      login?: string;
    };
    commit?: {
      oid?: string;
    };
  };
}

interface GraphQlPageInfoPayload {
  hasNextPage?: boolean;
  endCursor?: string | null;
}

interface ReviewThreadCommentConnectionPayload {
  pageInfo?: GraphQlPageInfoPayload;
  nodes?: ReviewThreadCommentPayload[];
}

interface ReviewThreadPayload {
  id?: string;
  isResolved?: boolean;
  isOutdated?: boolean;
  path?: string;
  line?: number;
  originalLine?: number;
  comments?: ReviewThreadCommentConnectionPayload;
}

interface ReviewThreadsConnectionPayload {
  pageInfo?: GraphQlPageInfoPayload;
  nodes?: ReviewThreadPayload[];
}

interface ReviewThreadsGraphQlPayload {
  data?: {
    repository?: {
      pullRequest?: {
        reviewThreads?: ReviewThreadsConnectionPayload;
      };
    };
  };
}

interface NormalizedReview {
  id: string;
  state: string | null;
  commitId: string | null;
  submittedAt: string | null;
  url: string | null;
  isCurrentHead: boolean;
  suppressedNotesObserved: boolean;
  suppressedNoteCount: number | null;
  bodySummary: string | null;
}

interface NormalizedComment {
  id: string;
  url: string | null;
  publishedAt: string | null;
  commitId: string | null;
  reviewId: string | null;
  reviewState: string | null;
  isCurrentHead: boolean;
  snippet: string | null;
}

interface NormalizedThread {
  threadId: string;
  path: string | null;
  line: number | null;
  originalLine: number | null;
  isResolved: boolean;
  isOutdated: boolean;
  copilotCommentCount: number;
  currentHeadCommentCount: number;
  staleCommentCount: number;
  actionable: boolean;
  latestComment: NormalizedComment | null;
  actionableComments: NormalizedComment[];
}

interface ReviewSignalSummary {
  copilotReviewCount: number;
  currentHeadReviewCount: number;
  staleReviewCount: number;
  unresolvedThreadCount: number;
  actionableThreadCount: number;
  actionableCommentCount: number;
  staleThreadCount: number;
  suppressedNotesObservedInLatestReview: boolean;
  suppressedNoteCountInLatestReview: number | null;
}

interface ReviewSignalPullRequest {
  number: number | null;
  url: string | null;
  state: string | null;
  draft: boolean | null;
  headSha: string | null;
  headRef: string | null;
  baseRef: string | null;
  author: string | null;
  updatedAt: string | null;
}

interface ReviewSignalSource {
  pull: 'file' | 'gh';
  reviews: 'file' | 'gh';
  threads: 'file' | 'gh';
}

interface ReviewSignalLatestReview {
  id: string;
  state: string | null;
  commitId: string | null;
  submittedAt: string | null;
  url: string | null;
  isCurrentHead: boolean;
  suppressedNotesObserved: boolean;
  suppressedNoteCount: number | null;
  bodySummary: string | null;
}

interface ReviewSignalStaleReview {
  id: string;
  state: string | null;
  commitId: string | null;
  submittedAt: string | null;
  url: string | null;
  bodySummary: string | null;
}

interface ReviewSignalUnresolvedThread {
  threadId: string;
  path: string | null;
  line: number | null;
  originalLine: number | null;
  isOutdated: boolean;
  actionable: boolean;
  copilotCommentCount: number;
  currentHeadCommentCount: number;
  staleCommentCount: number;
  latestComment: NormalizedComment | null;
}

interface ReviewSignalActionableComment {
  id: string;
  threadId: string;
  path: string | null;
  line: number | null;
  url: string | null;
  publishedAt: string | null;
  commitId: string | null;
  reviewId: string | null;
  reviewState: string | null;
  snippet: string | null;
}

interface ReviewSignalReport {
  schema: typeof REVIEW_SIGNAL_SCHEMA;
  schemaVersion: string;
  generatedAt: string;
  status: 'pass' | 'fail';
  repository: string | null;
  source: ReviewSignalSource;
  reviewState: 'clean' | 'attention' | 'error';
  pullRequest: ReviewSignalPullRequest;
  summary: ReviewSignalSummary;
  signals: {
    hasCopilotReview: boolean;
    hasCurrentHeadReview: boolean;
    hasStaleReview: boolean;
    hasUnresolvedThreads: boolean;
    hasActionableComments: boolean;
    hasSuppressedNotesInLatestReview: boolean;
  };
  latestCopilotReview: ReviewSignalLatestReview | null;
  staleReviews: ReviewSignalStaleReview[];
  unresolvedThreads: ReviewSignalUnresolvedThread[];
  actionableComments: ReviewSignalActionableComment[];
  errors: string[];
}

interface AnalyzeOptions {
  repository: string | null;
  pull: PullPayload;
  reviews: ReviewPayload[];
  threads: ReviewThreadsGraphQlPayload | ReviewThreadPayload[];
  now?: Date;
  source?: Partial<ReviewSignalSource>;
  headShaOverride?: string | null;
}

interface RunCopilotReviewSignalOptions {
  argv?: string[];
  now?: Date;
  loadPullFn?: (options: CliOptions) => PullPayload;
  loadReviewsFn?: (options: CliOptions) => ReviewPayload[];
  loadThreadsFn?: (options: CliOptions) => ReviewThreadsGraphQlPayload | ReviewThreadPayload[];
  writeReportFn?: (reportPath: string, report: ReviewSignalReport) => string;
  appendStepSummaryFn?: (stepSummaryPath: string | null, report: ReviewSignalReport) => void;
}

function printUsage(): void {
  const lines = [
    'Usage: node dist/tools/priority/copilot-review-signal.js [options]',
    '',
    'Collects current-head Copilot review state for a pull request and writes a machine-readable artifact.',
    '',
    'Options:',
    '  --repo <owner/repo>       Repository slug used for gh api calls.',
    '  --pr <number>             Pull request number.',
    '  --head-sha <sha>          Optional head SHA override (defaults to pull.head.sha).',
    `  --out <path>              Output JSON path (default: ${DEFAULT_REPORT_PATH}).`,
    '  --step-summary <path>     Optional GitHub step summary path to append a short summary.',
    '  --pull-file <path>        Optional captured pull payload JSON for offline tests.',
    '  --reviews-file <path>     Optional captured pull reviews JSON for offline tests.',
    '  --threads-file <path>     Optional captured GraphQL review threads JSON for offline tests.',
    '  -h, --help                Show help.',
  ];

  for (const line of lines) {
    console.log(line);
  }
}

function normalizeText(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeSha(value: unknown): string | null {
  const normalized = normalizeText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function normalizeIso(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  const parsed = new Date(String(value));
  if (Number.isNaN(parsed.valueOf())) {
    return null;
  }
  return parsed.toISOString();
}

function normalizeInteger(value: unknown): number | null {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number.parseInt(value, 10);
    return Number.isInteger(parsed) ? parsed : null;
  }
  return null;
}

function normalizeBoolean(value: unknown): boolean | null {
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

function summarizeBody(body: unknown, maxLength = 200): string | null {
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

export function parseRepoSlug(repo: string): { owner: string; repo: string } {
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

function isCopilotLogin(login: unknown): boolean {
  const normalized = normalizeText(login)?.toLowerCase();
  return normalized ? COPILOT_LOGINS.has(normalized) : false;
}

function detectSuppressedNotes(body: unknown): { observed: boolean; count: number | null } {
  const normalized = normalizeText(body);
  if (!normalized) {
    return { observed: false, count: null };
  }

  const detailedMatch = normalized.match(/Comments suppressed due to low confidence\s*\((\d+)\)/i);
  if (detailedMatch) {
    return {
      observed: true,
      count: Number.parseInt(detailedMatch[1], 10),
    };
  }

  return {
    observed: /Comments suppressed due to low confidence/i.test(normalized),
    count: null,
  };
}

function compareIsoDescending(left: string | null, right: string | null): number {
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

function compareIdDescending(left: string, right: string): number {
  return right.localeCompare(left, undefined, { numeric: true });
}

function runGhJson(args: string[]): unknown {
  const result = spawnSync('gh', args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    maxBuffer: GH_JSON_MAX_BUFFER_BYTES,
  } as Parameters<typeof spawnSync>[2] & { maxBuffer: number });

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh ${args.join(' ')}: ${message}`);
  }

  const status = result.status ?? 0;
  if (status !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    const parts = [`gh ${args.join(' ')} failed with exit code ${status}.`];
    if (stderr) parts.push(stderr);
    if (stdout) parts.push(stdout);
    throw new Error(parts.join(' '));
  }

  try {
    return JSON.parse(result.stdout ?? '');
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse JSON from gh ${args.join(' ')}: ${message}`);
  }
}

function readJsonFile<T>(filePath: string): T {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!existsSync(resolved)) {
    throw new Error(`JSON file not found: ${resolved}`);
  }
  return JSON.parse(readFileSync(resolved, 'utf8')) as T;
}

export function parseCliArgs(argv = process.argv): CliOptions {
  const args = argv.slice(2);
  const options: CliOptions = {
    help: false,
    repo: null,
    prNumber: null,
    headSha: null,
    outPath: DEFAULT_REPORT_PATH,
    stepSummaryPath: null,
    pullFile: null,
    reviewsFile: null,
    threadsFile: null,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--repo' ||
      token === '--pr' ||
      token === '--head-sha' ||
      token === '--out' ||
      token === '--step-summary' ||
      token === '--pull-file' ||
      token === '--reviews-file' ||
      token === '--threads-file'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      if (token === '--head-sha') options.headSha = normalizeSha(next);
      if (token === '--out') options.outPath = next;
      if (token === '--step-summary') options.stepSummaryPath = next;
      if (token === '--pull-file') options.pullFile = next;
      if (token === '--reviews-file') options.reviewsFile = next;
      if (token === '--threads-file') options.threadsFile = next;
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.help) {
    return options;
  }

  if (options.prNumber === null && !options.pullFile) {
    throw new Error('Pull request number is required. Pass --pr <number> or --pull-file <path>.');
  }
  if (!options.repo && !options.pullFile) {
    throw new Error('Repository slug is required. Pass --repo <owner/repo> or --pull-file <path>.');
  }

  return options;
}

function loadPullPayload(options: CliOptions): PullPayload {
  if (options.pullFile) {
    return readJsonFile<PullPayload>(options.pullFile);
  }

  if (!options.repo || options.prNumber === null) {
    throw new Error('Both --repo and --pr are required for live pull lookups.');
  }

  return runGhJson(['api', `repos/${options.repo}/pulls/${options.prNumber}`]) as PullPayload;
}

function loadReviewsPayload(options: CliOptions): ReviewPayload[] {
  if (options.reviewsFile) {
    return readJsonFile<ReviewPayload[]>(options.reviewsFile);
  }

  if (!options.repo || options.prNumber === null) {
    throw new Error('Both --repo and --pr are required for live review lookups.');
  }

  const payload = runGhJson(['api', `repos/${options.repo}/pulls/${options.prNumber}/reviews`]);
  if (!Array.isArray(payload)) {
    throw new Error('GitHub reviews payload was not an array.');
  }
  return payload as ReviewPayload[];
}

function loadThreadsPayload(options: CliOptions): ReviewThreadsGraphQlPayload {
  if (options.threadsFile) {
    return readJsonFile<ReviewThreadsGraphQlPayload>(options.threadsFile);
  }

  if (!options.repo || options.prNumber === null) {
    throw new Error('Both --repo and --pr are required for live review-thread lookups.');
  }

  const { owner, repo } = parseRepoSlug(options.repo);
  return runGhJson([
    'api',
    'graphql',
    '-f',
    `query=${REVIEW_THREADS_QUERY}`,
    '-F',
    `owner=${owner}`,
    '-F',
    `repo=${repo}`,
    '-F',
    `number=${options.prNumber}`,
  ]) as ReviewThreadsGraphQlPayload;
}

function extractThreadNodes(
  payload: ReviewThreadsGraphQlPayload | ReviewThreadPayload[],
): ReviewThreadPayload[] {
  if (Array.isArray(payload)) {
    return payload;
  }

  const nodes = payload.data?.repository?.pullRequest?.reviewThreads?.nodes;
  return Array.isArray(nodes) ? nodes : [];
}

function detectThreadPaginationErrors(
  payload: ReviewThreadsGraphQlPayload | ReviewThreadPayload[],
): string[] {
  if (Array.isArray(payload)) {
    return [];
  }

  const errors: string[] = [];
  const reviewThreads = payload.data?.repository?.pullRequest?.reviewThreads;
  if (reviewThreads?.pageInfo?.hasNextPage) {
    errors.push(
      'Review-thread payload exceeded the first 100 threads. Pagination is required before this report can be trusted.',
    );
  }

  const nodes = Array.isArray(reviewThreads?.nodes) ? reviewThreads.nodes : [];
  for (const thread of nodes) {
    if (thread.comments?.pageInfo?.hasNextPage) {
      const threadId = normalizeText(thread.id) ?? 'thread:unknown';
      errors.push(
        `Review-thread comments for ${threadId} exceeded the first 100 comments. Pagination is required before this report can be trusted.`,
      );
    }
  }

  return errors;
}

function normalizeComment(
  comment: ReviewThreadCommentPayload,
  headSha: string | null,
): NormalizedComment | null {
  const authorLogin = comment.author?.login ?? comment.pullRequestReview?.author?.login ?? null;
  if (!isCopilotLogin(authorLogin)) {
    return null;
  }

  const commitId = normalizeSha(
    comment.pullRequestReview?.commit?.oid ?? comment.originalCommit?.oid,
  );
  return {
    id: normalizeText(comment.id) ?? 'comment:unknown',
    url: normalizeText(comment.url),
    publishedAt: normalizeIso(comment.publishedAt ?? comment.createdAt),
    commitId,
    reviewId: normalizeInteger(comment.pullRequestReview?.databaseId)?.toString() ?? null,
    reviewState: normalizeText(comment.pullRequestReview?.state),
    isCurrentHead: Boolean(headSha && commitId && commitId === headSha),
    snippet: summarizeBody(comment.body),
  };
}

function normalizeThread(
  thread: ReviewThreadPayload,
  headSha: string | null,
): NormalizedThread | null {
  const comments = Array.isArray(thread.comments?.nodes)
    ? thread.comments.nodes
        .map((comment) => normalizeComment(comment, headSha))
        .filter((comment): comment is NormalizedComment => comment !== null)
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
  const currentHeadCommentCount = actionableComments.length;
  const staleCommentCount = comments.filter((comment) => !comment.isCurrentHead).length;
  const isResolved = Boolean(thread.isResolved);
  const isOutdated = Boolean(thread.isOutdated);

  return {
    threadId: normalizeText(thread.id) ?? 'thread:unknown',
    path: normalizeText(thread.path),
    line: normalizeInteger(thread.line),
    originalLine: normalizeInteger(thread.originalLine),
    isResolved,
    isOutdated,
    copilotCommentCount: comments.length,
    currentHeadCommentCount,
    staleCommentCount,
    actionable: !isResolved && !isOutdated && currentHeadCommentCount > 0,
    latestComment: sortedComments[0] ?? null,
    actionableComments,
  };
}

function normalizeReviews(
  reviews: ReviewPayload[],
  headSha: string | null,
): NormalizedReview[] {
  return reviews
    .filter((review) => isCopilotLogin(review.user?.login))
    .map((review) => {
      const suppressed = detectSuppressedNotes(review.body);
      const commitId = normalizeSha(review.commit_id);
      return {
        id: normalizeInteger(review.id)?.toString() ?? normalizeText(review.id) ?? 'review:unknown',
        state: normalizeText(review.state),
        commitId,
        submittedAt: normalizeIso(review.submitted_at),
        url: normalizeText(review.html_url),
        isCurrentHead: Boolean(headSha && commitId && commitId === headSha),
        suppressedNotesObserved: suppressed.observed,
        suppressedNoteCount: suppressed.count,
        bodySummary: summarizeBody(review.body),
      };
    })
    .sort((left, right) => {
      const byTime = compareIsoDescending(left.submittedAt, right.submittedAt);
      if (byTime !== 0) {
        return byTime;
      }
      return compareIdDescending(left.id, right.id);
    });
}

function zeroSummary(): ReviewSignalSummary {
  return {
    copilotReviewCount: 0,
    currentHeadReviewCount: 0,
    staleReviewCount: 0,
    unresolvedThreadCount: 0,
    actionableThreadCount: 0,
    actionableCommentCount: 0,
    staleThreadCount: 0,
    suppressedNotesObservedInLatestReview: false,
    suppressedNoteCountInLatestReview: null,
  };
}

function buildSource(options: CliOptions): ReviewSignalSource {
  return {
    pull: options.pullFile ? 'file' : 'gh',
    reviews: options.reviewsFile ? 'file' : 'gh',
    threads: options.threadsFile ? 'file' : 'gh',
  };
}

function determineReviewState(
  signals: ReviewSignalReport['signals'],
): 'clean' | 'attention' {
  if (
    !signals.hasCopilotReview ||
    !signals.hasCurrentHeadReview ||
    signals.hasStaleReview ||
    signals.hasUnresolvedThreads ||
    signals.hasActionableComments
  ) {
    return 'attention';
  }

  return 'clean';
}

export function analyzeCopilotReviewSignal({
  repository,
  pull,
  reviews,
  threads,
  now = new Date(),
  source = {},
  headShaOverride = null,
}: AnalyzeOptions): ReviewSignalReport {
  const pullRequest: ReviewSignalPullRequest = {
    number: normalizeInteger(pull.number),
    url: normalizeText(pull.html_url),
    state: normalizeText(pull.state),
    draft: normalizeBoolean(pull.draft),
    headSha: normalizeSha(headShaOverride ?? pull.head?.sha),
    headRef: normalizeText(pull.head?.ref),
    baseRef: normalizeText(pull.base?.ref),
    author: normalizeText(pull.user?.login),
    updatedAt: normalizeIso(pull.updated_at),
  };

  const resolvedRepository =
    normalizeText(repository) ?? normalizeText(pull.base?.repo?.full_name);
  const headSha = pullRequest.headSha;
  const normalizedReviews = normalizeReviews(reviews, headSha);
  const latestReview = normalizedReviews[0] ?? null;
  const staleReviews = normalizedReviews.filter((review) => !review.isCurrentHead);
  const normalizedThreads = extractThreadNodes(threads)
    .map((thread) => normalizeThread(thread, headSha))
    .filter((thread): thread is NormalizedThread => thread !== null);
  const errors = detectThreadPaginationErrors(threads);

  const unresolvedThreads = normalizedThreads.filter((thread) => !thread.isResolved);
  const actionableThreads = unresolvedThreads.filter((thread) => thread.actionable);
  const actionableComments: ReviewSignalActionableComment[] = actionableThreads.flatMap((thread) =>
    thread.actionableComments.map((comment) => ({
      id: comment.id,
      threadId: thread.threadId,
      path: thread.path,
      line: thread.line,
      url: comment.url,
      publishedAt: comment.publishedAt,
      commitId: comment.commitId,
      reviewId: comment.reviewId,
      reviewState: comment.reviewState,
      snippet: comment.snippet,
    })),
  );

  const summary: ReviewSignalSummary = {
    copilotReviewCount: normalizedReviews.length,
    currentHeadReviewCount: normalizedReviews.filter((review) => review.isCurrentHead).length,
    staleReviewCount: staleReviews.length,
    unresolvedThreadCount: unresolvedThreads.length,
    actionableThreadCount: actionableThreads.length,
    actionableCommentCount: actionableComments.length,
    staleThreadCount: unresolvedThreads.filter(
      (thread) => thread.staleCommentCount > 0 && thread.currentHeadCommentCount === 0,
    ).length,
    suppressedNotesObservedInLatestReview: latestReview?.suppressedNotesObserved ?? false,
    suppressedNoteCountInLatestReview: latestReview?.suppressedNoteCount ?? null,
  };

  const signals = {
    hasCopilotReview: normalizedReviews.length > 0,
    hasCurrentHeadReview: summary.currentHeadReviewCount > 0,
    hasStaleReview: summary.staleReviewCount > 0,
    hasUnresolvedThreads: summary.unresolvedThreadCount > 0,
    hasActionableComments: summary.actionableCommentCount > 0,
    hasSuppressedNotesInLatestReview: summary.suppressedNotesObservedInLatestReview,
  };

  return {
    schema: REVIEW_SIGNAL_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: errors.length > 0 ? 'fail' : 'pass',
    repository: resolvedRepository,
    source: {
      pull: source.pull ?? 'gh',
      reviews: source.reviews ?? 'gh',
      threads: source.threads ?? 'gh',
    },
    reviewState: errors.length > 0 ? 'error' : determineReviewState(signals),
    pullRequest,
    summary,
    signals,
    latestCopilotReview: latestReview
      ? {
          id: latestReview.id,
          state: latestReview.state,
          commitId: latestReview.commitId,
          submittedAt: latestReview.submittedAt,
          url: latestReview.url,
          isCurrentHead: latestReview.isCurrentHead,
          suppressedNotesObserved: latestReview.suppressedNotesObserved,
          suppressedNoteCount: latestReview.suppressedNoteCount,
          bodySummary: latestReview.bodySummary,
        }
      : null,
    staleReviews: staleReviews.map((review) => ({
      id: review.id,
      state: review.state,
      commitId: review.commitId,
      submittedAt: review.submittedAt,
      url: review.url,
      bodySummary: review.bodySummary,
    })),
    unresolvedThreads: unresolvedThreads.map((thread) => ({
      threadId: thread.threadId,
      path: thread.path,
      line: thread.line,
      originalLine: thread.originalLine,
      isOutdated: thread.isOutdated,
      actionable: thread.actionable,
      copilotCommentCount: thread.copilotCommentCount,
      currentHeadCommentCount: thread.currentHeadCommentCount,
      staleCommentCount: thread.staleCommentCount,
      latestComment: thread.latestComment,
    })),
    actionableComments,
    errors,
  };
}

function buildFailureReport(
  options: CliOptions,
  now: Date,
  error: Error,
): ReviewSignalReport {
  return {
    schema: REVIEW_SIGNAL_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    status: 'fail',
    repository: options.repo,
    source: buildSource(options),
    reviewState: 'error',
    pullRequest: {
      number: options.prNumber,
      url: null,
      state: null,
      draft: null,
      headSha: options.headSha,
      headRef: null,
      baseRef: null,
      author: null,
      updatedAt: null,
    },
    summary: zeroSummary(),
    signals: {
      hasCopilotReview: false,
      hasCurrentHeadReview: false,
      hasStaleReview: false,
      hasUnresolvedThreads: false,
      hasActionableComments: false,
      hasSuppressedNotesInLatestReview: false,
    },
    latestCopilotReview: null,
    staleReviews: [],
    unresolvedThreads: [],
    actionableComments: [],
    errors: [error.message || String(error)],
  };
}

function writeReport(reportPath: string, report: ReviewSignalReport): string {
  const resolved = path.resolve(process.cwd(), reportPath);
  mkdirSync(path.dirname(resolved), { recursive: true });
  writeFileSync(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

function appendStepSummary(
  stepSummaryPath: string | null,
  report: ReviewSignalReport,
): void {
  if (!stepSummaryPath) {
    return;
  }

  const resolved = path.resolve(process.cwd(), stepSummaryPath);
  mkdirSync(path.dirname(resolved), { recursive: true });

  const lines = [
    '### Copilot Review Signal',
    '',
    `- status: \`${report.status}\``,
    `- review_state: \`${report.reviewState}\``,
    `- repository: \`${report.repository ?? 'unknown'}\``,
    `- pull_request: \`#${report.pullRequest.number ?? 'unknown'}\``,
    `- head_sha: \`${report.pullRequest.headSha ?? 'unknown'}\``,
    `- current_head_review: \`${report.signals.hasCurrentHeadReview}\``,
    `- stale_review: \`${report.signals.hasStaleReview}\``,
    `- unresolved_threads: \`${report.summary.unresolvedThreadCount}\``,
    `- actionable_comments: \`${report.summary.actionableCommentCount}\``,
    `- suppressed_notes_in_latest_review: \`${report.summary.suppressedNotesObservedInLatestReview}\``,
  ];

  if (report.latestCopilotReview) {
    lines.push(`- latest_review_commit: \`${report.latestCopilotReview.commitId ?? 'unknown'}\``);
    lines.push(`- latest_review_submitted_at: \`${report.latestCopilotReview.submittedAt ?? 'unknown'}\``);
  }

  if (report.actionableComments.length > 0) {
    lines.push('', '#### Actionable Copilot Comments', '');
    for (const comment of report.actionableComments.slice(0, 5)) {
      const location = [comment.path ?? 'unknown-path', comment.line ?? '?'].join(':');
      lines.push(
        `- \`${location}\` ${comment.url ?? ''} ${comment.snippet ? `- ${comment.snippet}` : ''}`.trim(),
      );
    }
  }

  if (report.status === 'fail' && report.errors.length > 0) {
    lines.push('', '#### Errors', '');
    for (const error of report.errors) {
      lines.push(`- ${error}`);
    }
  }

  writeFileSync(resolved, `${lines.join('\n')}\n`, { encoding: 'utf8', flag: 'a' });
}

export function runCopilotReviewSignal({
  argv = process.argv,
  now = new Date(),
  loadPullFn = loadPullPayload,
  loadReviewsFn = loadReviewsPayload,
  loadThreadsFn = loadThreadsPayload,
  writeReportFn = writeReport,
  appendStepSummaryFn = appendStepSummary,
}: RunCopilotReviewSignalOptions = {}): {
  exitCode: number;
  report: ReviewSignalReport | null;
  reportPath: string | null;
} {
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
  let report: ReviewSignalReport;

  try {
    const pull = loadPullFn(options);
    const reviews = loadReviewsFn(options);
    const threads = loadThreadsFn(options);
    report = analyzeCopilotReviewSignal({
      repository: options.repo,
      pull,
      reviews,
      threads,
      now,
      source: buildSource(options),
      headShaOverride: options.headSha,
    });
    if (report.status !== 'pass') {
      exitCode = 1;
    }
  } catch (error) {
    exitCode = 1;
    report = buildFailureReport(
      options,
      now,
      error instanceof Error ? error : new Error(String(error)),
    );
  }

  const reportPath = writeReportFn(options.outPath, report);
  appendStepSummaryFn(options.stepSummaryPath, report);

  console.log(`[copilot-review-signal] report: ${reportPath}`);
  if (report.status === 'pass') {
    console.log(
      `[copilot-review-signal] currentHead=${report.signals.hasCurrentHeadReview} stale=${report.signals.hasStaleReview} actionable=${report.summary.actionableCommentCount}`,
    );
  } else {
    console.error(`[copilot-review-signal] ${report.errors.join('; ')}`);
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
    const result = runCopilotReviewSignal();
    process.exit(result.exitCode);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    process.exit(1);
  }
}
