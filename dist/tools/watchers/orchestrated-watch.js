import { execSync } from 'node:child_process';
import { ArgumentParser } from 'argparse';
import { setTimeout as sleep } from 'node:timers/promises';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
const DEFAULT_WORKFLOW_FILE = '.github/workflows/ci-orchestrated.yml';
const DEFAULT_ERROR_GRACE_MS = 120000;
const DEFAULT_NOT_FOUND_GRACE_MS = 90000;
class WatcherAbort extends Error {
    constructor(message, summary) {
        super(message);
        this.name = 'WatcherAbort';
        this.summary = summary;
    }
}
class GitHubRateLimitError extends Error {
    constructor(message, resetAt) {
        super(message);
        this.name = 'GitHubRateLimitError';
        this.resetAt = resetAt;
    }
}
function normaliseError(error) {
    if (error instanceof Error) {
        return error.message ?? String(error);
    }
    if (typeof error === 'string') {
        return error;
    }
    return JSON.stringify(error);
}
function isNotFoundError(error) {
    const message = normaliseError(error).toLowerCase();
    return message.includes('404') || message.includes('not found');
}
function buildSummary(params) {
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
function resolveRepo() {
    const fromEnv = process.env.GITHUB_REPOSITORY;
    if (fromEnv) {
        return fromEnv;
    }
    try {
        const remote = execSync('git config --get remote.origin.url', { encoding: 'utf8' }).trim();
        if (remote.endsWith('.git')) {
            const clean = remote.slice(0, -4);
            return clean.split(':').pop()?.split('/github.com/').pop() ?? clean;
        }
        return remote.split(':').pop() ?? remote;
    }
    catch (err) {
        throw new Error(`Unable to determine repository. Set GITHUB_REPOSITORY. (${err.message})`);
    }
}
function parseRateLimitReset(headers) {
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
function buildRateLimitMessage(params) {
    const { bodyMessage, documentationUrl, resetAt, tokenProvided } = params;
    const parts = [bodyMessage.trim()];
    if (resetAt) {
        const deltaMs = resetAt.getTime() - Date.now();
        if (Number.isFinite(deltaMs) && deltaMs > 0) {
            const minutes = Math.ceil(deltaMs / 60000);
            parts.push(`Limit resets in ~${minutes} minute${minutes === 1 ? '' : 's'} (${resetAt.toISOString()}).`);
        }
        else {
            parts.push(`Limit reset timestamp: ${resetAt.toISOString()}.`);
        }
    }
    if (tokenProvided) {
        parts.push('Wait for the rate limit to reset before retrying.');
    }
    else {
        parts.push('Provide GH_TOKEN or GITHUB_TOKEN to authenticate and raise the rate limit.');
    }
    if (documentationUrl) {
        parts.push(`Docs: ${documentationUrl}`);
    }
    return parts.join(' ');
}
async function fetchJson(url, token) {
    const headers = {
        Accept: 'application/vnd.github+json',
    };
    if (token) {
        headers.Authorization = `Bearer ${token}`;
    }
    const res = await fetch(url, { headers });
    const text = await res.text();
    let parsed;
    if (text) {
        try {
            parsed = JSON.parse(text);
        }
        catch { }
    }
    if (!res.ok) {
        const bodyMessage = typeof parsed?.message === 'string'
            ? String(parsed.message)
            : res.statusText;
        if (res.status === 403 && bodyMessage.toLowerCase().includes('rate limit')) {
            const documentationUrl = typeof parsed?.documentation_url === 'string'
                ? String(parsed.documentation_url)
                : undefined;
            const resetAt = parseRateLimitReset(res.headers);
            throw new GitHubRateLimitError(buildRateLimitMessage({
                bodyMessage,
                documentationUrl,
                resetAt,
                tokenProvided: Boolean(token),
            }), resetAt);
        }
        const detail = text ? text.trim() : '';
        const suffix = detail ? `: ${detail}` : '';
        throw new Error(`GitHub request failed (${res.status} ${res.statusText})${suffix}`);
    }
    if (parsed === undefined) {
        try {
            parsed = JSON.parse(text);
        }
        catch (err) {
            throw new Error(`Failed to parse JSON from GitHub (${url}): ${err.message}\nResponse:\n${text}`);
        }
    }
    return parsed;
}
async function findLatestRun(repo, workflow, branch, token) {
    const url = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/runs?branch=${encodeURIComponent(branch)}&per_page=5`;
    const data = await fetchJson(url, token);
    return data.workflow_runs?.[0];
}
function formatJob(job) {
    const status = job.status ?? 'unknown';
    const conclusion = job.conclusion ?? '';
    const suffix = conclusion ? ` (${conclusion})` : '';
    return `- ${job.name}: ${status}${suffix}`;
}
async function watchRun(repo, runId, token, pollMs = 15000, errorGraceMs = DEFAULT_ERROR_GRACE_MS, notFoundGraceMs = DEFAULT_NOT_FOUND_GRACE_MS) {
    // eslint-disable-next-line no-console
    console.log(`Watching run ${runId} in ${repo}...`);
    let latestRun;
    let latestJobs = [];
    let runDataLoaded = false;
    let errorWindowStart;
    let notFoundStart;
    while (true) {
        try {
            const runUrl = `https://api.github.com/repos/${repo}/actions/runs/${runId}`;
            latestRun = await fetchJson(runUrl, token);
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
            const jobsUrl = `https://api.github.com/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`;
            const jobsResp = await fetchJson(jobsUrl, token);
            latestJobs = jobsResp.jobs ?? [];
            if (latestJobs.length) {
                // eslint-disable-next-line no-console
                console.log('Jobs:');
                for (const job of latestJobs) {
                    // eslint-disable-next-line no-console
                    console.log(formatJob(job));
                }
            }
            else {
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
        }
        catch (err) {
            // eslint-disable-next-line no-console
            console.error(`[watcher] ${(err.message).trim()}`);
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
                    throw new WatcherAbort(`Run ${runId} in ${repo} was not found after ${Math.round(notFoundGraceMs / 1000)}s.`, summary);
                }
            }
            else {
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
                    throw new WatcherAbort(`Aborting watcher for run ${runId} after ${Math.round(errorGraceMs / 1000)}s of consecutive errors.`, summary);
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
    let runId = args.run_id;
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
        const branch = process.env.GITHUB_REF_NAME ?? process.env.GITHUB_HEAD_REF ?? process.env.GITHUB_REF ?? undefined;
        const sha = process.env.GITHUB_SHA ?? undefined;
        const serverUrl = process.env.GITHUB_SERVER_URL ?? 'https://github.com';
        const htmlUrl = `${serverUrl.replace(/\/$/, '')}/${repo}/actions/runs/${runId}`;
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
            const outPath = resolve(process.cwd(), args.out);
            mkdirSync(dirname(outPath), { recursive: true });
            writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
        }
        return;
    }
    try {
        const summary = await watchRun(repo, runId, token, args.poll_ms ?? 15000, args.error_grace_ms ?? DEFAULT_ERROR_GRACE_MS, args.notfound_grace_ms ?? DEFAULT_NOT_FOUND_GRACE_MS);
        if (args.out) {
            const outPath = resolve(process.cwd(), args.out);
            mkdirSync(dirname(outPath), { recursive: true });
            writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
        }
        if (summary.conclusion && summary.conclusion.toLowerCase() !== 'success') {
            process.exitCode = 1;
        }
    }
    catch (err) {
        if (err instanceof WatcherAbort) {
            // eslint-disable-next-line no-console
            console.error(`[watcher] ${err.message}`);
            if (args.out) {
                const outPath = resolve(process.cwd(), args.out);
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
    console.error(`[watcher] fatal: ${err.message}`);
    process.exitCode = 1;
});
