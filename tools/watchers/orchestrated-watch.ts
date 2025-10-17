import { execSync } from 'node:child_process';
import { ArgumentParser } from 'argparse';
import { setTimeout as sleep } from 'node:timers/promises';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

interface WorkflowRun {
  id: number;
  status?: string | null;
  conclusion?: string | null;
  html_url?: string;
  head_branch?: string;
  head_sha?: string;
  display_title?: string;
}

interface WorkflowJobsResponse {
  jobs: Array<{
    id: number;
    name: string;
    status: string;
    conclusion: string | null;
    html_url?: string;
    started_at?: string;
    completed_at?: string;
  }>;
}

const DEFAULT_WORKFLOW_FILE = '.github/workflows/ci-orchestrated.yml';
const DEFAULT_ERROR_GRACE_MS = 120_000;
const DEFAULT_NOT_FOUND_GRACE_MS = 90_000;

interface WatcherSummary {
  schema: 'ci-watch/rest-v1';
  repo: string;
  runId: number;
  branch?: string;
  headSha?: string;
  status?: string;
  conclusion?: string;
  htmlUrl?: string;
  displayTitle?: string;
  polledAtUtc: string;
  jobs: Array<{
    id: number;
    name: string;
    status: string;
    conclusion?: string | null;
    htmlUrl?: string;
  }>;
}

class WatcherAbort extends Error {
  public readonly summary: WatcherSummary;

  constructor(message: string, summary: WatcherSummary) {
    super(message);
    this.name = 'WatcherAbort';
    this.summary = summary;
  }
}

class GitHubRateLimitError extends Error {
  public readonly resetAt?: Date;

  constructor(message: string, resetAt?: Date) {
    super(message);
    this.name = 'GitHubRateLimitError';
    this.resetAt = resetAt;
  }
}

function normaliseError(error: unknown): string {
  if (error instanceof Error) {
    return error.message ?? String(error);
  }
  if (typeof error === 'string') {
    return error;
  }
  return JSON.stringify(error);
}

function isNotFoundError(error: unknown): boolean {
  const message = normaliseError(error).toLowerCase();
  return message.includes('404') || message.includes('not found');
}

function buildSummary(params: {
  repo: string;
  runId: number;
  run?: WorkflowRun;
  jobs?: WorkflowJobsResponse['jobs'];
  status: string;
  conclusion: string;
}): WatcherSummary {
  const { repo, runId, run, jobs, status, conclusion } = params;
  return {
    schema: 'ci-watch/rest-v1',
    repo,
    runId,
    branch: run?.head_branch ?? undefined,
    headSha: run?.head_sha ?? undefined,
    status,
    conclusion,
    htmlUrl: run?.html_url ?? undefined,
    displayTitle: run?.display_title ?? undefined,
    polledAtUtc: new Date().toISOString(),
    jobs: (jobs ?? []).map((job) => ({
      id: job.id,
      name: job.name,
      status: job.status,
      conclusion: job.conclusion ?? undefined,
      htmlUrl: job.html_url ?? undefined,
    })),
  };
}

function parseGitRemoteUrl(remoteUrl: string | null | undefined): string | null {
  if (!remoteUrl) {
    return null;
  }

  const trimmed = remoteUrl.trim();
  if (!trimmed) {
    return null;
  }

  const sanitized = trimmed.replace(/^git\+/i, '');
  const stripGitSuffix = (slug: string) => slug.replace(/\.git$/i, '');

  const sshMatch = sanitized.match(/^git@[^:]+:(.+)$/i);
  if (sshMatch) {
    return stripGitSuffix(sshMatch[1]);
  }

  try {
    const parsed = new URL(sanitized);
    if (parsed.hostname && parsed.pathname) {
      const slug = parsed.pathname.replace(/^\/+/, '');
      if (slug) {
        return stripGitSuffix(slug);
      }
    }
  } catch {
    // Ignore invalid URLs and fall back to heuristic handling below.
  }

  if (/^[^/]+\/[\w.-]+$/i.test(trimmed)) {
    return stripGitSuffix(trimmed);
  }

  return null;
}

function resolveRepo(): string {
  const fromEnv = process.env.GITHUB_REPOSITORY;
  if (fromEnv) {
    const cleaned = fromEnv.trim();
    if (cleaned) {
      return cleaned;
    }
  }
  try {
    const remote = execSync('git config --get remote.origin.url', { encoding: 'utf8' }).trim();
    const parsed = parseGitRemoteUrl(remote);
    if (parsed) {
      return parsed;
    }
    return remote.split(':').pop() ?? remote;
  } catch (err) {
    throw new Error(`Unable to determine repository. Set GITHUB_REPOSITORY. (${(err as Error).message})`);
  }
}

function parseRateLimitReset(headers: Headers): Date | undefined {
  const resetHeader = headers.get('x-ratelimit-reset');
  if (!resetHeader) {
    return undefined;
  }

  const resetEpoch = Number(resetHeader);
  if (!Number.isFinite(resetEpoch) || resetEpoch <= 0) {
    return undefined;
  }

  return new Date(resetEpoch * 1000);
}

function buildRateLimitMessage(params: {
  bodyMessage: string;
  documentationUrl?: string;
  resetAt?: Date;
  tokenProvided: boolean;
}): string {
  const { bodyMessage, documentationUrl, resetAt, tokenProvided } = params;
  const parts = [bodyMessage.trim()];

  if (resetAt) {
    const deltaMs = resetAt.getTime() - Date.now();
    if (Number.isFinite(deltaMs) && deltaMs > 0) {
      const minutes = Math.ceil(deltaMs / 60_000);
      parts.push(`Limit resets in ~${minutes} minute${minutes === 1 ? '' : 's'} (${resetAt.toISOString()}).`);
    } else {
      parts.push(`Limit reset timestamp: ${resetAt.toISOString()}.`);
    }
  }

  if (tokenProvided) {
    parts.push('Wait for the rate limit to reset before retrying.');
  } else {
    parts.push('Provide GH_TOKEN or GITHUB_TOKEN to authenticate and raise the rate limit.');
  }

  if (documentationUrl) {
    parts.push(`Docs: ${documentationUrl}`);
  }

  return parts.join(' ');
}

async function fetchJson<T>(url: string, token?: string): Promise<T> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const res = await fetch(url, { headers });
  const text = await res.text();
  let parsed: unknown;

  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {}
  }

  if (!res.ok) {
    const bodyMessage = typeof (parsed as { message?: string })?.message === 'string'
      ? String((parsed as { message?: string }).message)
      : res.statusText;
    if (res.status === 403 && bodyMessage.toLowerCase().includes('rate limit')) {
      const documentationUrl = typeof (parsed as { documentation_url?: string })?.documentation_url === 'string'
        ? String((parsed as { documentation_url?: string }).documentation_url)
        : undefined;
      const resetAt = parseRateLimitReset(res.headers);
      throw new GitHubRateLimitError(
        buildRateLimitMessage({
          bodyMessage,
          documentationUrl,
          resetAt,
          tokenProvided: Boolean(token),
        }),
        resetAt,
      );
    }

    const detail = text ? text.trim() : '';
    const suffix = detail ? `: ${detail}` : '';
    throw new Error(`GitHub request failed (${res.status} ${res.statusText})${suffix}`);
  }

  if (parsed === undefined) {
    try {
      parsed = JSON.parse(text) as T;
    } catch (err) {
      throw new Error(`Failed to parse JSON from GitHub (${url}): ${(err as Error).message}\nResponse:\n${text}`);
    }
  }

  return parsed as T;
}

async function findLatestRun(repo: string, workflow: string, branch: string, token?: string): Promise<WorkflowRun | undefined> {
  const url = new URL(`https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/runs`);
  url.searchParams.set('branch', branch);
  url.searchParams.set('per_page', '5');
  const data = await fetchJson<{ workflow_runs: WorkflowRun[] }>(url.toString(), token);
  return data.workflow_runs?.[0];
}

function formatJob(job: WorkflowJobsResponse['jobs'][number]): string {
  const status = job.status ?? 'unknown';
  const conclusion = job.conclusion ?? '';
  const suffix = conclusion ? ` (${conclusion})` : '';
  return `- ${job.name}: ${status}${suffix}`;
}

async function watchRun(
  repo: string,
  runId: number,
  token: string | undefined,
  pollMs = 15000,
  errorGraceMs = DEFAULT_ERROR_GRACE_MS,
  notFoundGraceMs = DEFAULT_NOT_FOUND_GRACE_MS,
): Promise<WatcherSummary> {
  // eslint-disable-next-line no-console
  console.log(`Watching run ${runId} in ${repo}...`);

  let latestRun: WorkflowRun | undefined;
  let latestJobs: WorkflowJobsResponse['jobs'] = [];
  let runDataLoaded = false;
  let errorWindowStart: number | undefined;
  let notFoundStart: number | undefined;

  while (true) {
    try {
      const runUrl = new URL(`https://api.github.com/repos/${repo}/actions/runs/${runId}`);
      latestRun = await fetchJson<WorkflowRun>(runUrl.toString(), token);

      const title = latestRun.display_title ?? `Run ${latestRun.id}`;
      const status = latestRun.status ?? 'unknown';
      const conclusion = latestRun.conclusion ?? '';
      const branch = latestRun.head_branch ?? '';
      const sha = latestRun.head_sha ?? '';

      // eslint-disable-next-line no-console
      console.log(`\n${title}`);
      // eslint-disable-next-line no-console
      console.log(`Status: ${status}  Conclusion: ${conclusion}`.trim());
      if (branch || sha) {
        // eslint-disable-next-line no-console
        console.log(`Ref: ${branch} ${sha}`.trim());
      }
      if (latestRun.html_url) {
        // eslint-disable-next-line no-console
    console.log(`URL: ${latestRun.html_url}`);
      }

      const jobsUrl = new URL(`https://api.github.com/repos/${repo}/actions/runs/${runId}/jobs`);
      jobsUrl.searchParams.set('per_page', '100');
      const jobsResp = await fetchJson<WorkflowJobsResponse>(jobsUrl.toString(), token);
      latestJobs = jobsResp.jobs ?? [];
      if (latestJobs.length) {
        // eslint-disable-next-line no-console
        console.log('Jobs:');
        for (const job of latestJobs) {
          // eslint-disable-next-line no-console
          console.log(formatJob(job));
        }
      } else {
        latestJobs = [];
      }

      runDataLoaded = true;
      errorWindowStart = undefined;
      notFoundStart = undefined;

      if (status === 'completed') {
        return {
          schema: 'ci-watch/rest-v1',
          repo,
          runId,
          branch: latestRun.head_branch ?? undefined,
          headSha: latestRun.head_sha ?? undefined,
          status: latestRun.status ?? undefined,
          conclusion: latestRun.conclusion ?? undefined,
          htmlUrl: latestRun.html_url ?? undefined,
          displayTitle: latestRun.display_title ?? undefined,
          polledAtUtc: new Date().toISOString(),
          jobs: latestJobs.map((job) => ({
            id: job.id,
            name: job.name,
            status: job.status,
            conclusion: job.conclusion ?? undefined,
            htmlUrl: job.html_url ?? undefined,
          })),
        };
      }
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(`[watcher] ${((err as Error).message).trim()}`);
      if (err instanceof GitHubRateLimitError) {
        const summary = buildSummary({
          repo,
          runId,
          run: latestRun,
          jobs: latestJobs,
          status: 'rate_limited',
          conclusion: 'watcher-error',
        });
        throw new WatcherAbort(err.message, summary);
      }
      if (!runDataLoaded && isNotFoundError(err)) {
        if (!notFoundStart) {
          notFoundStart = Date.now();
        }
        if (Date.now() - notFoundStart >= notFoundGraceMs) {
          const summary = buildSummary({
            repo,
            runId,
            run: latestRun,
            jobs: latestJobs,
            status: 'not_found',
            conclusion: 'watcher-error',
          });
          throw new WatcherAbort(
            `Run ${runId} in ${repo} was not found after ${Math.round(notFoundGraceMs / 1000)}s.`,
            summary,
          );
        }
      } else {
        if (!errorWindowStart) {
          errorWindowStart = Date.now();
        }
        if (Date.now() - errorWindowStart >= errorGraceMs) {
          const summary = buildSummary({
            repo,
            runId,
            run: latestRun,
            jobs: latestJobs,
            status: latestRun?.status ?? 'error',
            conclusion: 'watcher-error',
          });
          throw new WatcherAbort(
            `Aborting watcher for run ${runId} after ${Math.round(errorGraceMs / 1000)}s of consecutive errors.`,
            summary,
          );
        }
      }
    }

    await sleep(pollMs);
  }
}

async function main() {
  const parser = new ArgumentParser({
    description: 'Watch GitHub Actions run for ci-orchestrated.yml',
  });
  parser.add_argument('--run-id', { type: Number, help: 'Workflow run id to follow' });
  parser.add_argument('--branch', { help: 'Branch to locate the most recent run (if run id missing)' });
  parser.add_argument('--workflow', { default: DEFAULT_WORKFLOW_FILE, help: 'Workflow file name (default: ci-orchestrated)' });
  parser.add_argument('--poll-ms', { type: Number, default: 15000, help: 'Polling interval in milliseconds' });
  parser.add_argument('--out', { help: 'Optional path to write watcher summary JSON' });
  parser.add_argument('--error-grace-ms', { type: Number, default: DEFAULT_ERROR_GRACE_MS, help: 'Milliseconds of consecutive errors before aborting (default: 120000)' });
  parser.add_argument('--notfound-grace-ms', { type: Number, default: DEFAULT_NOT_FOUND_GRACE_MS, help: 'Milliseconds to wait after repeated 404 responses before aborting (default: 90000)' });
  const args = parser.parse_args();

  const repo = resolveRepo();
  const token = process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN ?? undefined;

  let runId: number | undefined = args.run_id;
  if (!runId) {
    if (!args.branch) {
      throw new Error('Provide --run-id or --branch');
    }
    const latest = await findLatestRun(repo, args.workflow, args.branch, token);
    if (!latest) {
      throw new Error(`No runs found for branch ${args.branch}`);
    }
    runId = latest.id;
  }

  const currentRunIdRaw = process.env.GITHUB_RUN_ID;
  const currentRunId = currentRunIdRaw ? Number(currentRunIdRaw) : undefined;
  const isCurrentRun = Number.isFinite(currentRunId) && currentRunId === runId;

  if (isCurrentRun) {
    // eslint-disable-next-line no-console
    console.log(`[watcher] Run ${runId} matches current workflow; skipping self-watch to avoid deadlock.`);
    const branch =
      process.env.GITHUB_REF_NAME ?? process.env.GITHUB_HEAD_REF ?? process.env.GITHUB_REF ?? undefined;
    const sha = process.env.GITHUB_SHA ?? undefined;
    const serverUrl = process.env.GITHUB_SERVER_URL ?? 'https://github.com';
    const baseUrl = serverUrl.endsWith('/') ? serverUrl : `${serverUrl}/`;
    const htmlUrl = new URL(`${repo}/actions/runs/${runId}`, baseUrl).toString();
    const summary = buildSummary({
      repo,
      runId,
      run: {
        id: runId,
        head_branch: branch,
        head_sha: sha,
        html_url: htmlUrl,
        display_title: process.env.GITHUB_WORKFLOW ?? undefined,
      },
      jobs: [],
      status: 'skipped',
      conclusion: 'success',
    });

    if (args.out) {
      const outPath = resolve(process.cwd(), args.out as string);
      mkdirSync(dirname(outPath), { recursive: true });
      writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
    }

    return;
  }

  try {
    const summary = await watchRun(
      repo,
      runId,
      token,
      args.poll_ms ?? 15000,
      args.error_grace_ms ?? DEFAULT_ERROR_GRACE_MS,
      args.notfound_grace_ms ?? DEFAULT_NOT_FOUND_GRACE_MS,
    );

    if (args.out) {
      const outPath = resolve(process.cwd(), args.out as string);
      mkdirSync(dirname(outPath), { recursive: true });
      writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
    }

    if (summary.conclusion && summary.conclusion.toLowerCase() !== 'success') {
      process.exitCode = 1;
    }
  } catch (err) {
    if (err instanceof WatcherAbort) {
      // eslint-disable-next-line no-console
      console.error(`[watcher] ${err.message}`);
      if (args.out) {
        const outPath = resolve(process.cwd(), args.out as string);
        mkdirSync(dirname(outPath), { recursive: true });
        writeFileSync(outPath, `${JSON.stringify(err.summary, null, 2)}\n`, 'utf8');
      }
      process.exitCode = 1;
      return;
    }

    throw err;
  }
}

main().catch((err) => {
  console.error(`[watcher] fatal: ${(err as Error).message}`);
  process.exitCode = 1;
});
