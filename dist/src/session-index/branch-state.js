import { execFileSync } from 'node:child_process';
function runGit(args, cwd) {
    return execFileSync('git', args, {
        cwd,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe']
    }).trim();
}
function tryRunGit(args, cwd) {
    try {
        const output = runGit(args, cwd);
        return output.length > 0 ? output : undefined;
    }
    catch {
        return undefined;
    }
}
function parseAheadBehind(input) {
    if (!input) {
        return {};
    }
    const [leftRaw, rightRaw] = input.split(/\s+/);
    const ahead = Number.parseInt(leftRaw ?? '', 10);
    const behind = Number.parseInt(rightRaw ?? '', 10);
    return {
        ahead: Number.isFinite(ahead) ? ahead : undefined,
        behind: Number.isFinite(behind) ? behind : undefined
    };
}
function computeSummary(branch, upstream, ahead, behind, isClean, hasUntracked) {
    const parts = [];
    if (upstream) {
        if ((ahead ?? 0) === 0 && (behind ?? 0) === 0) {
            parts.push(`up-to-date with ${upstream}`);
        }
        else {
            if (ahead !== undefined && ahead > 0) {
                parts.push(`ahead ${ahead} of ${upstream}`);
            }
            if (behind !== undefined && behind > 0) {
                parts.push(`behind ${behind} from ${upstream}`);
            }
        }
    }
    else {
        parts.push('no upstream configured');
    }
    if (!isClean) {
        parts.push(hasUntracked ? 'dirty (includes untracked files)' : 'dirty');
    }
    if (parts.length === 0) {
        parts.push('status unknown');
    }
    return `Branch ${branch}: ${parts.join('; ')}`;
}
export function collectBranchState(cwd = process.cwd()) {
    try {
        const branch = tryRunGit(['rev-parse', '--abbrev-ref', 'HEAD'], cwd);
        if (!branch) {
            return undefined;
        }
        const upstream = tryRunGit(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], cwd);
        const countsRaw = upstream
            ? tryRunGit(['rev-list', '--left-right', '--count', `HEAD...${upstream}`], cwd)
            : undefined;
        const { ahead, behind } = parseAheadBehind(countsRaw);
        const statusOutput = tryRunGit(['status', '--porcelain'], cwd) ?? '';
        const hasUntracked = statusOutput
            .split('\n')
            .filter((line) => line.length > 0)
            .some((line) => line.startsWith('??'));
        const isClean = statusOutput.trim().length === 0;
        const summary = computeSummary(branch, upstream, ahead ?? 0, behind ?? 0, isClean, hasUntracked);
        const state = {
            branch,
            upstream,
            ahead: ahead ?? 0,
            behind: behind ?? 0,
            hasUpstream: Boolean(upstream),
            isClean,
            hasUntracked,
            summary,
            timestampUtc: new Date().toISOString()
        };
        return state;
    }
    catch {
        return undefined;
    }
}
