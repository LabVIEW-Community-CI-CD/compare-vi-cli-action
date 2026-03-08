#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormatsPlugin from 'ajv-formats';
import type { FormatsPlugin } from 'ajv-formats';

export const VALIDATION_AGENT_ATTESTATION_SCHEMA = 'validation-agent-attestation@v1';
export const DEFAULT_SIGNAL_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'copilot-review-signal.json',
);
export const DEFAULT_OUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'reviews',
  'validation-agent-attestation.json',
);

const SCHEMA_PATH = path.join(
  'docs',
  'schemas',
  'validation-agent-attestation-v1.schema.json',
);
const GH_JSON_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const DISPOSITION_VALUES = new Set(['addressed', 'accepted', 'dismissed', 'noted', 'deferred']);
const EVIDENCE_STATUS_VALUES = new Set(['passed', 'failed', 'skipped']);

interface CliOptions {
  help: boolean;
  signalPath: string;
  dispositionsPath: string | null;
  validationEvidencePath: string | null;
  outPath: string;
  repo: string | null;
  prNumber: number | null;
  headSha: string | null;
  copilotReviewId: string | null;
  postComment: boolean;
}

interface ReviewSignalComment {
  id?: string | null;
  reviewId?: string | null;
  snippet?: string | null;
}

interface ReviewSignalThread {
  threadId?: string | null;
  path?: string | null;
  line?: number | null;
  latestComment?: ReviewSignalComment | null;
}

interface ReviewSignalActionableComment {
  id?: string | null;
  threadId?: string | null;
  reviewId?: string | null;
  path?: string | null;
  line?: number | null;
  snippet?: string | null;
}

interface ReviewSignalReport {
  schema?: string;
  repository?: string | null;
  status?: string | null;
  reviewState?: string | null;
  pullRequest?: {
    number?: number | null;
    url?: string | null;
    headSha?: string | null;
  };
  latestCopilotReview?: {
    id?: string | null;
    url?: string | null;
    submittedAt?: string | null;
    isCurrentHead?: boolean | null;
    state?: string | null;
  } | null;
  summary?: {
    unresolvedThreadCount?: number | null;
    actionableCommentCount?: number | null;
    staleReviewCount?: number | null;
  };
  unresolvedThreads?: ReviewSignalThread[];
  actionableComments?: ReviewSignalActionableComment[];
}

interface ThreadDispositionInput {
  threadId?: string;
  disposition?: string;
  note?: string | null;
  path?: string | null;
  line?: number | string | null;
}

interface CommentDispositionInput {
  commentId?: string;
  threadId?: string | null;
  reviewId?: string | null;
  disposition?: string;
  note?: string | null;
}

interface DispositionsInput {
  threads?: ThreadDispositionInput[];
  comments?: CommentDispositionInput[];
}

interface ValidationEvidenceCommandInput {
  command?: string;
  status?: string;
  exitCode?: number | string | null;
  details?: string | null;
  artifactPath?: string | null;
}

interface ValidationEvidenceCheckInput {
  name?: string;
  status?: string;
  details?: string | null;
}

interface ValidationEvidenceInput {
  summary?: string | null;
  commands?: ValidationEvidenceCommandInput[];
  checks?: ValidationEvidenceCheckInput[];
  artifacts?: string[];
  notes?: string[];
}

interface ValidationEvidenceCommand {
  command: string;
  status: 'passed' | 'failed' | 'skipped';
  exitCode: number | null;
  details: string | null;
  artifactPath: string | null;
}

interface ValidationEvidenceCheck {
  name: string;
  status: 'passed' | 'failed' | 'skipped';
  details: string | null;
}

interface ThreadDisposition {
  threadId: string;
  disposition: 'addressed' | 'accepted' | 'dismissed' | 'noted' | 'deferred';
  note: string | null;
  path: string | null;
  line: number | null;
  latestCommentId: string | null;
  latestCommentReviewId: string | null;
}

interface CommentDisposition {
  commentId: string;
  threadId: string | null;
  reviewId: string | null;
  disposition: 'addressed' | 'accepted' | 'dismissed' | 'noted' | 'deferred';
  note: string | null;
}

interface ValidationAgentAttestation {
  schema: typeof VALIDATION_AGENT_ATTESTATION_SCHEMA;
  schemaVersion: string;
  generatedAt: string;
  repository: string;
  pullRequest: {
    number: number;
    url: string | null;
    headSha: string;
  };
  copilotReview: {
    id: string;
    url: string | null;
    submittedAt: string | null;
    state: string | null;
    isCurrentHead: boolean | null;
  };
  reviewSignal: {
    artifactPath: string;
    status: string | null;
    reviewState: string | null;
    unresolvedThreadCount: number;
    actionableCommentCount: number;
    staleReviewCount: number;
  };
  dispositions: {
    threads: ThreadDisposition[];
    comments: CommentDisposition[];
  };
  validationEvidence: {
    summary: string | null;
    commands: ValidationEvidenceCommand[];
    checks: ValidationEvidenceCheck[];
    artifacts: string[];
    notes: string[];
  };
  commentPost: {
    requested: boolean;
    posted: boolean;
    actorLogin: string | null;
    postedAt: string | null;
  };
  source: {
    signalPath: string;
    dispositionsPath: string;
    validationEvidencePath: string;
  };
}

interface KnownThreadRecord {
  threadId: string;
  path: string | null;
  line: number | null;
  latestCommentId: string | null;
  latestCommentReviewId: string | null;
}

interface KnownCommentRecord {
  commentId: string;
  threadId: string | null;
  reviewId: string | null;
}

interface RunValidationAgentAttestationOptions {
  argv?: string[];
  now?: Date;
  readJsonFn?: (filePath: string) => unknown;
  writeReportFn?: (reportPath: string, report: ValidationAgentAttestation) => string;
  postCommentFn?: (repo: string, prNumber: number, body: string) => void;
  lookupCurrentLoginFn?: () => string;
}

let cachedValidator:
  | ((payload: ValidationAgentAttestation) => { valid: boolean; errors: string[] })
  | null = null;
const addFormats = addFormatsPlugin as unknown as FormatsPlugin;

function printUsage(): void {
  const lines = [
    'Usage: node dist/tools/priority/validation-agent-attestation.js [options]',
    '',
    'Writes a machine-readable validation-agent-attestation artifact and can optionally post a PR comment.',
    '',
    'Options:',
    `  --signal <path>              Copilot review signal JSON path (default: ${DEFAULT_SIGNAL_PATH}).`,
    '  --dispositions <path>        JSON file describing thread/comment dispositions.',
    '  --validation-evidence <path> JSON file describing validation evidence.',
    `  --out <path>                 Output JSON path (default: ${DEFAULT_OUT_PATH}).`,
    '  --repo <owner/repo>          Optional repository override; must match the signal when provided.',
    '  --pr <number>                Optional PR number override; must match the signal when provided.',
    '  --head-sha <sha>             Optional head SHA override; must match the signal when provided.',
    '  --copilot-review-id <id>     Optional Copilot review id override.',
    '  --post-comment               Post a PR comment using the signed-in gh identity after validation succeeds.',
    '  -h, --help                   Show help.',
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

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values)];
}

function parseRepoSlug(repo: string): { owner: string; repo: string } {
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

function readJsonFile<T>(filePath: string): T {
  const resolved = path.resolve(process.cwd(), filePath);
  if (!existsSync(resolved)) {
    throw new Error(`JSON file not found: ${resolved}`);
  }
  return JSON.parse(readFileSync(resolved, 'utf8')) as T;
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

function lookupCurrentLogin(): string {
  const payload = runGhJson(['api', 'user']) as { login?: string | null };
  const login = normalizeText(payload?.login);
  if (!login) {
    throw new Error('Unable to resolve the signed-in gh login.');
  }
  return login;
}

function postComment(repo: string, prNumber: number, body: string): void {
  const tempRoot = process.env.TEMP ?? process.env.TMP ?? process.cwd();
  const bodyPath = path.join(
    tempRoot,
    `validation-agent-attestation-${Date.now()}-${Math.floor(Math.random() * 1000000)}.md`,
  );
  writeFileSync(bodyPath, `${body}\n`, 'utf8');

  const result = spawnSync(
    'gh',
    ['pr', 'comment', String(prNumber), '--repo', repo, '--body-file', bodyPath],
    {
      cwd: process.cwd(),
      encoding: 'utf8',
    },
  );

  if (result.error) {
    const message = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run gh pr comment: ${message}`);
  }

  const status = result.status ?? 0;
  if (status !== 0) {
    const stderr = normalizeText(result.stderr);
    const stdout = normalizeText(result.stdout);
    const parts = [`gh pr comment failed with exit code ${status}.`];
    if (stderr) parts.push(stderr);
    if (stdout) parts.push(stdout);
    throw new Error(parts.join(' '));
  }
}

function parseCliArgs(argv = process.argv): CliOptions {
  const args = argv.slice(2);
  const options: CliOptions = {
    help: false,
    signalPath: DEFAULT_SIGNAL_PATH,
    dispositionsPath: null,
    validationEvidencePath: null,
    outPath: DEFAULT_OUT_PATH,
    repo: null,
    prNumber: null,
    headSha: null,
    copilotReviewId: null,
    postComment: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }
    if (token === '--post-comment') {
      options.postComment = true;
      continue;
    }

    const next = args[index + 1];
    if (
      token === '--signal' ||
      token === '--dispositions' ||
      token === '--validation-evidence' ||
      token === '--out' ||
      token === '--repo' ||
      token === '--pr' ||
      token === '--head-sha' ||
      token === '--copilot-review-id'
    ) {
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--signal') options.signalPath = next;
      if (token === '--dispositions') options.dispositionsPath = next;
      if (token === '--validation-evidence') options.validationEvidencePath = next;
      if (token === '--out') options.outPath = next;
      if (token === '--repo') options.repo = normalizeText(next);
      if (token === '--pr') options.prNumber = normalizeInteger(next);
      if (token === '--head-sha') options.headSha = normalizeSha(next);
      if (token === '--copilot-review-id') options.copilotReviewId = normalizeText(next);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.help) {
    if (!options.dispositionsPath) {
      throw new Error('Dispositions JSON is required. Pass --dispositions <path>.');
    }
    if (!options.validationEvidencePath) {
      throw new Error('Validation evidence JSON is required. Pass --validation-evidence <path>.');
    }
  }

  return options;
}

function normalizeDisposition(value: unknown): ThreadDisposition['disposition'] {
  const normalized = normalizeText(value)?.toLowerCase();
  if (!normalized || !DISPOSITION_VALUES.has(normalized)) {
    throw new Error(
      `Disposition must be one of ${Array.from(DISPOSITION_VALUES).join(', ')} (received: ${String(value)}).`,
    );
  }
  return normalized as ThreadDisposition['disposition'];
}

function normalizeEvidenceStatus(value: unknown): ValidationEvidenceCommand['status'] {
  const normalized = normalizeText(value)?.toLowerCase();
  if (!normalized || !EVIDENCE_STATUS_VALUES.has(normalized)) {
    throw new Error(
      `Validation evidence status must be one of ${Array.from(EVIDENCE_STATUS_VALUES).join(', ')} (received: ${String(value)}).`,
    );
  }
  return normalized as ValidationEvidenceCommand['status'];
}

function loadValidator(): (payload: ValidationAgentAttestation) => { valid: boolean; errors: string[] } {
  if (cachedValidator) {
    return cachedValidator;
  }

  const schema = readJsonFile<Record<string, unknown>>(SCHEMA_PATH);
  const ajv = new Ajv2020({ allErrors: true, strict: false, allowUnionTypes: true });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  cachedValidator = (payload) => {
    const valid = validate(payload);
    const errors = (validate.errors ?? []).map((error) => {
      const instancePath = error.instancePath || '/';
      return `${instancePath} ${error.message ?? error.keyword}`.trim();
    });
    return { valid: Boolean(valid), errors };
  };

  return cachedValidator;
}

function validateAttestationPayload(payload: ValidationAgentAttestation): void {
  const validate = loadValidator();
  const result = validate(payload);
  if (!result.valid) {
    throw new Error(`Attestation schema validation failed:\n${result.errors.join('\n')}`);
  }
}

function buildKnownThreadMap(signal: ReviewSignalReport): Map<string, KnownThreadRecord> {
  const records = new Map<string, KnownThreadRecord>();
  const threads = Array.isArray(signal.unresolvedThreads) ? signal.unresolvedThreads : [];
  for (const thread of threads) {
    const threadId = normalizeText(thread?.threadId);
    if (!threadId) {
      continue;
    }
    records.set(threadId, {
      threadId,
      path: normalizeText(thread.path),
      line: normalizeInteger(thread.line),
      latestCommentId: normalizeText(thread.latestComment?.id),
      latestCommentReviewId: normalizeText(thread.latestComment?.reviewId),
    });
  }
  return records;
}

function buildKnownCommentMap(signal: ReviewSignalReport): Map<string, KnownCommentRecord> {
  const records = new Map<string, KnownCommentRecord>();
  const actionableComments = Array.isArray(signal.actionableComments) ? signal.actionableComments : [];
  for (const comment of actionableComments) {
    const commentId = normalizeText(comment?.id);
    if (!commentId) {
      continue;
    }
    records.set(commentId, {
      commentId,
      threadId: normalizeText(comment.threadId),
      reviewId: normalizeText(comment.reviewId),
    });
  }

  const unresolvedThreads = Array.isArray(signal.unresolvedThreads) ? signal.unresolvedThreads : [];
  for (const thread of unresolvedThreads) {
    const commentId = normalizeText(thread.latestComment?.id);
    if (!commentId || records.has(commentId)) {
      continue;
    }
    records.set(commentId, {
      commentId,
      threadId: normalizeText(thread.threadId),
      reviewId: normalizeText(thread.latestComment?.reviewId),
    });
  }

  return records;
}

function normalizeThreadDispositions(
  input: DispositionsInput,
  knownThreads: Map<string, KnownThreadRecord>,
): ThreadDisposition[] {
  if (!Array.isArray(input.threads)) {
    throw new Error('Dispositions JSON must contain a threads array.');
  }

  const seen = new Set<string>();
  return input.threads.map((entry) => {
    const threadId = normalizeText(entry?.threadId);
    if (!threadId) {
      throw new Error('Each thread disposition must include threadId.');
    }
    if (seen.has(threadId)) {
      throw new Error(`Duplicate thread disposition for ${threadId}.`);
    }
    seen.add(threadId);

    const known = knownThreads.get(threadId);
    if (!known) {
      throw new Error(`Thread disposition references unknown review thread ${threadId}.`);
    }

    return {
      threadId,
      disposition: normalizeDisposition(entry.disposition),
      note: normalizeText(entry.note),
      path: normalizeText(entry.path) ?? known.path,
      line: normalizeInteger(entry.line) ?? known.line,
      latestCommentId: known.latestCommentId,
      latestCommentReviewId: known.latestCommentReviewId,
    };
  });
}

function normalizeCommentDispositions(
  input: DispositionsInput,
  knownComments: Map<string, KnownCommentRecord>,
): CommentDisposition[] {
  if (!Array.isArray(input.comments)) {
    throw new Error('Dispositions JSON must contain a comments array.');
  }

  const seen = new Set<string>();
  return input.comments.map((entry) => {
    const commentId = normalizeText(entry?.commentId);
    if (!commentId) {
      throw new Error('Each comment disposition must include commentId.');
    }
    if (seen.has(commentId)) {
      throw new Error(`Duplicate comment disposition for ${commentId}.`);
    }
    seen.add(commentId);

    const known = knownComments.get(commentId);
    if (!known) {
      throw new Error(`Comment disposition references unknown review comment ${commentId}.`);
    }

    const threadId = normalizeText(entry.threadId) ?? known.threadId;
    const reviewId = normalizeText(entry.reviewId) ?? known.reviewId;
    if (normalizeText(entry.threadId) && known.threadId && normalizeText(entry.threadId) !== known.threadId) {
      throw new Error(`Comment disposition ${commentId} references thread ${entry.threadId}, expected ${known.threadId}.`);
    }
    if (normalizeText(entry.reviewId) && known.reviewId && normalizeText(entry.reviewId) !== known.reviewId) {
      throw new Error(`Comment disposition ${commentId} references review ${entry.reviewId}, expected ${known.reviewId}.`);
    }

    return {
      commentId,
      threadId,
      reviewId,
      disposition: normalizeDisposition(entry.disposition),
      note: normalizeText(entry.note),
    };
  });
}

function normalizeValidationEvidence(input: ValidationEvidenceInput): ValidationAgentAttestation['validationEvidence'] {
  const commands = Array.isArray(input.commands) ? input.commands : [];
  const checks = Array.isArray(input.checks) ? input.checks : [];
  const artifacts = Array.isArray(input.artifacts)
    ? uniqueStrings(input.artifacts.map((entry) => normalizeText(entry)).filter((entry): entry is string => entry !== null))
    : [];
  const notes = Array.isArray(input.notes)
    ? uniqueStrings(input.notes.map((entry) => normalizeText(entry)).filter((entry): entry is string => entry !== null))
    : [];

  return {
    summary: normalizeText(input.summary),
    commands: commands.map((entry, index) => {
      const command = normalizeText(entry?.command);
      if (!command) {
        throw new Error(`Validation evidence command #${index + 1} is missing command.`);
      }
      return {
        command,
        status: normalizeEvidenceStatus(entry.status),
        exitCode: normalizeInteger(entry.exitCode),
        details: normalizeText(entry.details),
        artifactPath: normalizeText(entry.artifactPath),
      };
    }),
    checks: checks.map((entry, index) => {
      const name = normalizeText(entry?.name);
      if (!name) {
        throw new Error(`Validation evidence check #${index + 1} is missing name.`);
      }
      return {
        name,
        status: normalizeEvidenceStatus(entry.status),
        details: normalizeText(entry.details),
      };
    }),
    artifacts,
    notes,
  };
}

function buildAttestation(
  options: CliOptions,
  signal: ReviewSignalReport,
  dispositionsInput: DispositionsInput,
  validationEvidenceInput: ValidationEvidenceInput,
  now: Date,
  actorLogin: string | null,
  posted: boolean,
): ValidationAgentAttestation {
  if (signal.schema !== 'priority/copilot-review-signal@v1') {
    throw new Error(`Unexpected review signal schema '${String(signal.schema ?? 'unknown')}'.`);
  }

  const signalRepository = normalizeText(signal.repository);
  const repository = normalizeText(options.repo) ?? signalRepository;
  if (!repository) {
    throw new Error('Repository is missing from both the signal and CLI arguments.');
  }
  parseRepoSlug(repository);
  if (signalRepository && normalizeText(options.repo) && repository !== signalRepository) {
    throw new Error(`Repository override ${repository} does not match signal repository ${signalRepository}.`);
  }

  const signalPrNumber = normalizeInteger(signal.pullRequest?.number);
  const prNumber = options.prNumber ?? signalPrNumber;
  if (prNumber === null) {
    throw new Error('Pull request number is missing from both the signal and CLI arguments.');
  }
  if (signalPrNumber !== null && options.prNumber !== null && options.prNumber !== signalPrNumber) {
    throw new Error(`PR override ${options.prNumber} does not match signal PR ${signalPrNumber}.`);
  }

  const signalHeadSha = normalizeSha(signal.pullRequest?.headSha);
  const headSha = options.headSha ?? signalHeadSha;
  if (!headSha) {
    throw new Error('Head SHA is missing from both the signal and CLI arguments.');
  }
  if (signalHeadSha && options.headSha && options.headSha !== signalHeadSha) {
    throw new Error(`Head SHA override ${options.headSha} does not match signal head SHA ${signalHeadSha}.`);
  }

  const signalReviewId = normalizeText(signal.latestCopilotReview?.id);
  const copilotReviewId = normalizeText(options.copilotReviewId) ?? signalReviewId;
  if (!copilotReviewId) {
    throw new Error('Copilot review id is required.');
  }
  if (signalReviewId && options.copilotReviewId && options.copilotReviewId !== signalReviewId) {
    throw new Error(`Copilot review id override ${options.copilotReviewId} does not match signal review id ${signalReviewId}.`);
  }

  const knownThreads = buildKnownThreadMap(signal);
  const knownComments = buildKnownCommentMap(signal);
  const threadDispositions = normalizeThreadDispositions(dispositionsInput, knownThreads);
  const commentDispositions = normalizeCommentDispositions(dispositionsInput, knownComments);
  const validationEvidence = normalizeValidationEvidence(validationEvidenceInput);

  if (!options.dispositionsPath || !options.validationEvidencePath) {
    throw new Error('Dispositions and validation evidence paths are required.');
  }

  return {
    schema: VALIDATION_AGENT_ATTESTATION_SCHEMA,
    schemaVersion: '1.0.0',
    generatedAt: now.toISOString(),
    repository,
    pullRequest: {
      number: prNumber,
      url: normalizeText(signal.pullRequest?.url),
      headSha,
    },
    copilotReview: {
      id: copilotReviewId,
      url: normalizeText(signal.latestCopilotReview?.url),
      submittedAt: normalizeText(signal.latestCopilotReview?.submittedAt),
      state: normalizeText(signal.latestCopilotReview?.state),
      isCurrentHead:
        typeof signal.latestCopilotReview?.isCurrentHead === 'boolean'
          ? signal.latestCopilotReview.isCurrentHead
          : null,
    },
    reviewSignal: {
      artifactPath: options.signalPath,
      status: normalizeText(signal.status),
      reviewState: normalizeText(signal.reviewState),
      unresolvedThreadCount: normalizeInteger(signal.summary?.unresolvedThreadCount) ?? 0,
      actionableCommentCount: normalizeInteger(signal.summary?.actionableCommentCount) ?? 0,
      staleReviewCount: normalizeInteger(signal.summary?.staleReviewCount) ?? 0,
    },
    dispositions: {
      threads: threadDispositions,
      comments: commentDispositions,
    },
    validationEvidence,
    commentPost: {
      requested: options.postComment,
      posted,
      actorLogin,
      postedAt: posted ? now.toISOString() : null,
    },
    source: {
      signalPath: options.signalPath,
      dispositionsPath: options.dispositionsPath,
      validationEvidencePath: options.validationEvidencePath,
    },
  };
}

function buildCommentBody(attestation: ValidationAgentAttestation): string {
  const preview = {
    schema: attestation.schema,
    generatedAt: attestation.generatedAt,
    repository: attestation.repository,
    pullRequest: attestation.pullRequest,
    copilotReview: attestation.copilotReview,
    reviewSignal: attestation.reviewSignal,
    dispositions: attestation.dispositions,
    validationEvidence: attestation.validationEvidence,
  };

  return [
    '### Validation Agent Attestation',
    '',
    `- repository: \`${attestation.repository}\``,
    `- pull_request: \`#${attestation.pullRequest.number}\``,
    `- head_sha: \`${attestation.pullRequest.headSha}\``,
    `- copilot_review_id: \`${attestation.copilotReview.id}\``,
    `- thread_dispositions: \`${attestation.dispositions.threads.length}\``,
    `- comment_dispositions: \`${attestation.dispositions.comments.length}\``,
    `- validation_commands: \`${attestation.validationEvidence.commands.length}\``,
    '',
    '```json',
    JSON.stringify(preview, null, 2),
    '```',
  ].join('\n');
}

function writeReport(reportPath: string, report: ValidationAgentAttestation): string {
  const resolved = path.resolve(process.cwd(), reportPath);
  mkdirSync(path.dirname(resolved), { recursive: true });
  writeFileSync(resolved, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  return resolved;
}

export function runValidationAgentAttestation({
  argv = process.argv,
  now = new Date(),
  readJsonFn = readJsonFile,
  writeReportFn = writeReport,
  postCommentFn = postComment,
  lookupCurrentLoginFn = lookupCurrentLogin,
}: RunValidationAgentAttestationOptions = {}): {
  exitCode: number;
  attestation: ValidationAgentAttestation | null;
  reportPath: string | null;
  error: string | null;
} {
  try {
    const options = parseCliArgs(argv);
    if (options.help) {
      printUsage();
      return {
        exitCode: 0,
        attestation: null,
        reportPath: null,
        error: null,
      };
    }

    const signal = readJsonFn(options.signalPath) as ReviewSignalReport;
    const dispositions = readJsonFn(options.dispositionsPath ?? '') as DispositionsInput;
    const validationEvidence = readJsonFn(
      options.validationEvidencePath ?? '',
    ) as ValidationEvidenceInput;
    const actorLogin = options.postComment ? lookupCurrentLoginFn() : null;

    const baseAttestation = buildAttestation(
      options,
      signal,
      dispositions,
      validationEvidence,
      now,
      actorLogin,
      false,
    );
    validateAttestationPayload(baseAttestation);

    if (options.postComment) {
      const body = buildCommentBody(baseAttestation);
      postCommentFn(baseAttestation.repository, baseAttestation.pullRequest.number, body);
    }

    const finalAttestation = buildAttestation(
      options,
      signal,
      dispositions,
      validationEvidence,
      now,
      actorLogin,
      options.postComment,
    );
    validateAttestationPayload(finalAttestation);
    const reportPath = writeReportFn(options.outPath, finalAttestation);

    console.log(`[validation-agent-attestation] report: ${reportPath}`);
    if (options.postComment) {
      console.log(
        `[validation-agent-attestation] posted attestation comment to #${finalAttestation.pullRequest.number} as ${finalAttestation.commentPost.actorLogin ?? 'unknown'}`,
      );
    }

    return {
      exitCode: 0,
      attestation: finalAttestation,
      reportPath,
      error: null,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    return {
      exitCode: 1,
      attestation: null,
      reportPath: null,
      error: message,
    };
  }
}

const isDirectRun =
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isDirectRun) {
  const result = runValidationAgentAttestation();
  process.exit(result.exitCode);
}
