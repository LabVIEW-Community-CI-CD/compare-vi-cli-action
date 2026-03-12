import { createSessionIndexBuilder } from './builder.js';
const branchProtectionReasonSet = new Set([
    'aligned',
    'missing_required',
    'extra_required',
    'mismatch',
    'mapping_missing',
    'api_unavailable',
    'api_error',
    'api_forbidden'
]);
function asRecord(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return undefined;
    }
    return value;
}
function asString(value) {
    if (typeof value !== 'string') {
        return undefined;
    }
    const trimmed = value.trim();
    return trimmed ? trimmed : undefined;
}
function asNumber(value) {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value === 'string' && value.trim()) {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) {
            return parsed;
        }
    }
    return undefined;
}
function asStringArray(value) {
    if (!Array.isArray(value)) {
        return undefined;
    }
    const items = value
        .map((entry) => asString(entry))
        .filter((entry) => Boolean(entry));
    return items.length > 0 ? items : [];
}
function normalizeBranch(value) {
    if (!value) {
        return value;
    }
    if (value.startsWith('refs/heads/')) {
        return value.slice('refs/heads/'.length);
    }
    return value;
}
function mapBranchProtectionStatus(value) {
    switch ((value ?? '').trim().toLowerCase()) {
        case 'ok':
            return 'ok';
        case 'warn':
            return 'warn';
        case 'fail':
        case 'error':
            return 'error';
        default:
            return undefined;
    }
}
function mapBranchProtectionReason(value) {
    if (!value) {
        return undefined;
    }
    return branchProtectionReasonSet.has(value)
        ? value
        : undefined;
}
function inferArtifactKind(name) {
    if (/summary/i.test(name)) {
        return 'summary';
    }
    if (/report|html|xml/i.test(name)) {
        return 'report';
    }
    if (/log|ndjson/i.test(name)) {
        return 'log';
    }
    return 'artifact';
}
function inferArtifactMimeType(name) {
    if (/html/i.test(name)) {
        return 'text/html';
    }
    if (/xml/i.test(name)) {
        return 'application/xml';
    }
    if (/json|ndjson/i.test(name)) {
        return 'application/json';
    }
    if (/txt/i.test(name)) {
        return 'text/plain';
    }
    return undefined;
}
export function convertSessionIndexV1ToV2(payload, options = {}) {
    const source = asRecord(payload);
    if (!source) {
        throw new Error('session-index v1 payload must be an object');
    }
    const builder = createSessionIndexBuilder();
    const runContext = asRecord(source.runContext);
    const branchProtection = asRecord(source.branchProtection);
    const branchProtectionResult = asRecord(branchProtection?.result);
    const branchProtectionActual = asRecord(branchProtection?.actual);
    const branchProtectionContract = asRecord(branchProtection?.contract);
    const summary = asRecord(source.summary);
    const files = asRecord(source.files);
    const urls = asRecord(source.urls);
    const watchers = asRecord(source.watchers);
    const drift = asRecord(source.drift);
    builder.setRun({
        id: asString(runContext?.runId),
        attempt: asNumber(runContext?.runAttempt) !== undefined ? Math.max(0, Math.trunc(asNumber(runContext?.runAttempt))) : undefined,
        workflow: asString(runContext?.workflow) ?? options.githubWorkflow ?? 'unknown',
        job: asString(runContext?.job) ?? options.githubJob,
        branch: normalizeBranch(asString(runContext?.ref) ?? options.githubRefName),
        commit: asString(runContext?.commitSha) ?? options.githubSha,
        repository: asString(runContext?.repository) ?? options.githubRepository,
        trigger: asString(options.eventName) ? { kind: asString(options.eventName) } : undefined
    });
    const customEnvironment = {};
    const runnerArch = asString(runContext?.runnerArch);
    const runnerEnvironment = asString(runContext?.runnerEnvironment);
    const runnerMachine = asString(runContext?.runnerMachine);
    const runnerTrackingId = asString(runContext?.runnerTrackingId);
    const runnerLabels = asStringArray(runContext?.runnerLabels);
    if (runnerArch)
        customEnvironment.runnerArch = runnerArch;
    if (runnerEnvironment)
        customEnvironment.runnerEnvironment = runnerEnvironment;
    if (runnerMachine)
        customEnvironment.runnerMachine = runnerMachine;
    if (runnerTrackingId)
        customEnvironment.runnerTrackingId = runnerTrackingId;
    if (runnerLabels && runnerLabels.length > 0)
        customEnvironment.runnerLabels = runnerLabels.join(',');
    const runnerImageOS = asString(runContext?.runnerImageOS);
    const runnerImageVersion = asString(runContext?.runnerImageVersion);
    const runnerImage = runnerImageOS && runnerImageVersion
        ? `${runnerImageOS}:${runnerImageVersion}`
        : runnerImageOS ?? runnerImageVersion;
    if (asString(runContext?.runner) ||
        runnerImage ||
        asString(runContext?.runnerOS) ||
        options.nodeVersion ||
        options.pwshVersion ||
        options.gitVersion ||
        Object.keys(customEnvironment).length > 0) {
        builder.setEnvironment({
            runner: asString(runContext?.runner),
            runnerImage,
            os: asString(runContext?.runnerOS),
            node: options.nodeVersion,
            pwsh: options.pwshVersion,
            git: options.gitVersion,
            custom: Object.keys(customEnvironment).length > 0 ? customEnvironment : undefined
        });
    }
    const branchProtectionStatus = mapBranchProtectionStatus(asString(branchProtectionResult?.status));
    if (branchProtectionStatus) {
        builder.setBranchProtection({
            status: branchProtectionStatus,
            reason: mapBranchProtectionReason(asString(branchProtectionResult?.reason)),
            expected: asStringArray(branchProtection?.expected),
            actual: asStringArray(branchProtectionActual?.contexts),
            mapping: asString(branchProtectionContract?.mappingPath) && asString(branchProtectionContract?.mappingDigest)
                ? {
                    path: asString(branchProtectionContract?.mappingPath),
                    digest: asString(branchProtectionContract?.mappingDigest)
                }
                : undefined,
            notes: asStringArray(branchProtection?.notes)
        });
    }
    const total = asNumber(summary?.total);
    const passed = asNumber(summary?.passed);
    const failed = asNumber(summary?.failed);
    const errors = asNumber(summary?.errors);
    const skipped = asNumber(summary?.skipped);
    if ([total, passed, failed, errors, skipped].every((value) => value !== undefined)) {
        builder.setTestsSummary({
            total: Math.max(0, Math.trunc(total)),
            passed: Math.max(0, Math.trunc(passed)),
            failed: Math.max(0, Math.trunc(failed)),
            errors: Math.max(0, Math.trunc(errors)),
            skipped: Math.max(0, Math.trunc(skipped)),
            durationSeconds: asNumber(summary?.duration_s)
        });
    }
    if (options.v1Path) {
        builder.addArtifact({
            name: 'session-index-v1',
            path: options.v1Path,
            kind: 'summary',
            mimeType: 'application/json'
        });
    }
    if (files) {
        for (const [name, entry] of Object.entries(files)) {
            const artifactPath = asString(entry);
            if (!artifactPath) {
                continue;
            }
            builder.addArtifact({
                name,
                path: artifactPath,
                kind: inferArtifactKind(name),
                mimeType: inferArtifactMimeType(name)
            });
        }
    }
    const extra = {};
    if (asString(source.resultsDir))
        extra.resultsDir = asString(source.resultsDir);
    if (typeof source.includeIntegration === 'boolean')
        extra.includeIntegration = source.includeIntegration;
    if (source.integrationMode !== undefined)
        extra.integrationMode = source.integrationMode;
    if (source.integrationSource !== undefined)
        extra.integrationSource = source.integrationSource;
    if (asString(source.status))
        extra.status = asString(source.status);
    if (urls)
        extra.urls = urls;
    if (watchers)
        extra.watchers = watchers;
    if (drift)
        extra.drift = drift;
    if (asString(source.stepSummary))
        extra.stepSummary = asString(source.stepSummary);
    if (runContext)
        extra.runContext = runContext;
    for (const [key, value] of Object.entries(extra)) {
        builder.setExtra(key, value);
    }
    return builder.build();
}
