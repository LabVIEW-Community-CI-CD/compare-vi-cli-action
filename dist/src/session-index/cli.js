import { ArgumentParser } from 'argparse';
import { readFileSync, writeFileSync } from 'node:fs';
import { buildToggleValuesPayload } from '../config/toggles.js';
import { createSessionIndexBuilder } from './builder.js';
function normalizeProfiles(input) {
    if (!input) {
        return [];
    }
    const values = Array.isArray(input) ? input : [input];
    const flattened = values
        .flatMap((entry) => entry.split(/[,\s]+/))
        .map((entry) => entry.trim())
        .filter((entry) => entry.length > 0);
    const unique = Array.from(new Set(flattened));
    unique.sort((a, b) => a.localeCompare(b));
    return unique;
}
const parser = new ArgumentParser({
    description: 'Session Index v2 helper'
});
parser.add_argument('--out', {
    help: 'Optional path to write the generated session-index.json (defaults to stdout)'
});
parser.add_argument('--sample', {
    help: 'Emit a sample session index with placeholder data',
    action: 'store_true'
});
parser.add_argument('--workflow', {
    help: 'Workflow name when generating real output',
    default: process.env.GITHUB_WORKFLOW || 'unknown'
});
parser.add_argument('--job', {
    help: 'Job name',
    default: process.env.GITHUB_JOB
});
parser.add_argument('--from-v1', {
    help: 'Path to an existing v1 session-index.json to convert'
});
parser.add_argument('--cases', {
    help: 'Path(s) to session-index.v2.cases.json files to include',
    action: 'append'
});
parser.add_argument('--toggle-profile', {
    help: 'Toggle profile(s) to apply (repeatable)',
    action: 'append',
    dest: 'toggle_profiles'
});
const args = parser.parse_args();
const builder = createSessionIndexBuilder();
const argProfiles = normalizeProfiles(args.toggle_profiles ?? undefined);
const envProfiles = normalizeProfiles(process.env.AGENT_TOGGLE_PROFILES);
const defaultProfiles = process.env.GITHUB_ACTIONS && process.env.GITHUB_ACTIONS.toLowerCase() === 'true'
    ? ['ci-orchestrated']
    : ['dev-workstation'];
const toggleProfiles = argProfiles.length > 0
    ? argProfiles
    : envProfiles.length > 0
        ? envProfiles
        : defaultProfiles;
const togglePayload = buildToggleValuesPayload({
    profiles: toggleProfiles
});
if (args.sample) {
    builder
        .setRun({
        workflow: args.workflow,
        job: args.job ?? 'sample',
        branch: 'develop',
        commit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        trigger: {
            kind: 'pull_request',
            number: 119,
            author: 'sample-user'
        }
    })
        .setEnvironment({
        runner: 'ubuntu-24.04',
        node: process.version,
        pwsh: '7.5.3'
    })
        .setBranchProtection({
        status: 'warn',
        reason: 'api_forbidden',
        expected: ['Validate / lint', 'Validate / fixtures', 'Validate / session-index'],
        produced: ['Validate / lint', 'Validate / fixtures'],
        actual: {
            status: 'available',
            contexts: ['Validate', 'Workflows Lint']
        },
        mapping: {
            path: 'tools/policy/branch-required-checks.json',
            digest: '9121da2e7b43a122c02db5adf6148f42de443d89159995fce7d035ae66745772'
        },
        notes: [
            'Branch protection query failed: Response status code does not indicate success: 403 (Forbidden).'
        ]
    })
        .setTestsSummary({
        total: 7,
        passed: 7,
        failed: 0,
        errors: 0,
        skipped: 0,
        durationSeconds: 14.75
    })
        .addTestCase({
        id: 'Watcher.BusyLoop.Tests::should exit when hang detected',
        category: 'tests/Watcher.BusyLoop.Tests.ps1',
        requirement: 'REQ-1234',
        rationale: 'Busy-loop detection must terminate the watcher within 120 seconds.',
        expectedResult: 'Watcher exits with code 2 and logs hang telemetry.',
        outcome: 'passed',
        durationMs: 1739,
        artifacts: ['tests/results/watcher-busyloop/pester-results.xml'],
        tags: ['busy-loop', 'watcher']
    })
        .addArtifact({
        name: 'pester-summary',
        path: 'tests/results/pester-summary.json',
        kind: 'summary'
    })
        .addArtifact({
        name: 'compare-report',
        path: 'tests/results/compare-report.html',
        kind: 'report',
        mimeType: 'text/html'
    })
        .addNote('Sample session index generated for demonstration.');
    if (args.cases) {
        const paths = Array.isArray(args.cases)
            ? args.cases
            : [args.cases];
        for (const casePath of paths) {
            try {
                const rawCases = JSON.parse(readFileSync(casePath, 'utf8'));
                const cases = Array.isArray(rawCases.cases)
                    ? rawCases.cases
                    : [];
                for (const testCase of cases) {
                    builder.addTestCase({
                        id: String(testCase.id ?? testCase.name ?? 'unknown'),
                        description: testCase.description
                            ? String(testCase.description)
                            : undefined,
                        category: testCase.category
                            ? String(testCase.category)
                            : undefined,
                        outcome: testCase.outcome ??
                            'unknown',
                        durationMs: typeof testCase.durationMs === 'number'
                            ? testCase.durationMs
                            : undefined,
                        artifacts: Array.isArray(testCase.artifacts)
                            ? testCase.artifacts
                            : undefined,
                        tags: Array.isArray(testCase.tags)
                            ? testCase.tags
                            : undefined,
                        requirement: testCase.requirement
                            ? String(testCase.requirement)
                            : undefined,
                        rationale: testCase.rationale
                            ? String(testCase.rationale)
                            : undefined,
                        expectedResult: testCase.expectedResult
                            ? String(testCase.expectedResult)
                            : undefined,
                        diagnostics: Array.isArray(testCase.diagnostics)
                            ? testCase.diagnostics
                            : undefined
                    });
                }
            }
            catch (error) {
                console.warn(`Failed to load test cases from ${casePath}:`, error);
            }
        }
    }
}
else if (args.from_v1) {
    const raw = JSON.parse(readFileSync(args.from_v1, 'utf8'));
    const generatedAt = typeof raw.generatedAtUtc === 'string'
        ? new Date(raw.generatedAtUtc)
        : new Date();
    builder.withGeneratedAt(generatedAt);
    builder.setRun({
        workflow: args.workflow,
        job: args.job ?? process.env.GITHUB_JOB,
        branch: raw.branchProtection?.branch ?? process.env.GITHUB_REF_NAME,
        commit: process.env.GITHUB_SHA,
        repository: process.env.GITHUB_REPOSITORY,
        trigger: {
            kind: process.env.GITHUB_EVENT_NAME
        }
    });
    if (raw.summary && typeof raw.summary === 'object') {
        const summary = raw.summary;
        builder.setTestsSummary({
            total: Number(summary.total ?? 0),
            passed: Number(summary.passed ?? 0),
            failed: Number(summary.failed ?? 0),
            errors: Number(summary.errors ?? 0),
            skipped: Number(summary.skipped ?? 0),
            durationSeconds: summary.duration_s !== undefined ? Number(summary.duration_s) : undefined
        });
    }
    if (raw.branchProtection && typeof raw.branchProtection === 'object') {
        const bp = raw.branchProtection;
        const result = (bp.result ?? {});
        const rawStatus = typeof result.status === 'string' ? result.status.toLowerCase() : undefined;
        let status = 'ok';
        if (rawStatus === 'warn') {
            status = 'warn';
        }
        else if (rawStatus === 'error') {
            status = 'error';
        }
        else if (rawStatus === 'fail') {
            status = 'error';
        }
        else if (rawStatus === 'ok') {
            status = 'ok';
        }
        builder.setBranchProtection({
            status,
            reason: result.reason,
            expected: Array.isArray(bp.expected)
                ? bp.expected
                : undefined,
            produced: Array.isArray(bp.produced)
                ? bp.produced
                : undefined,
            actual: bp.actual && typeof bp.actual === 'object'
                ? bp.actual
                : undefined,
            mapping: bp.contract && typeof bp.contract === 'object'
                ? {
                    path: bp.contract
                        .mappingPath,
                    digest: bp.contract
                        .mappingDigest
                }
                : undefined,
            notes: Array.isArray(bp.notes) ? bp.notes : undefined
        });
    }
    if (typeof raw.stepSummary === 'string') {
        builder.addNote(raw.stepSummary);
    }
    if (raw.files && typeof raw.files === 'object') {
        const files = raw.files;
        for (const [key, value] of Object.entries(files)) {
            if (typeof value === 'string') {
                builder.addArtifact({
                    name: key,
                    path: value,
                    kind: key.includes('summary')
                        ? 'summary'
                        : key.includes('report')
                            ? 'report'
                            : 'artifact'
                });
            }
        }
    }
}
else {
    builder.setRun({
        workflow: args.workflow,
        job: args.job ?? process.env.GITHUB_JOB,
        branch: process.env.GITHUB_REF_NAME,
        commit: process.env.GITHUB_SHA,
        repository: process.env.GITHUB_REPOSITORY,
        trigger: {
            kind: process.env.GITHUB_EVENT_NAME
        }
    });
}
builder.setEnvironmentToggles(togglePayload);
const index = builder.build();
const json = JSON.stringify(index, null, 2);
if (args.out) {
    writeFileSync(args.out, json, { encoding: 'utf8' });
}
else {
    process.stdout.write(json);
}
