import { sessionIndexSchema } from './schema.js';
function sortUnique(values) {
    if (!values || values.length === 0) {
        return undefined;
    }
    const unique = Array.from(new Set(values.filter((entry) => entry && entry.length > 0)));
    unique.sort((a, b) => a.localeCompare(b));
    return unique;
}
function normalizeToggleValues(toggles) {
    const profiles = [...toggles.profiles].sort((a, b) => a.localeCompare(b));
    const context = toggles.context
        ? {
            ...toggles.context,
            tags: sortUnique(toggles.context.tags)
        }
        : undefined;
    const entries = Object.keys(toggles.values)
        .sort((a, b) => a.localeCompare(b))
        .map((key) => [
        key,
        { ...toggles.values[key] }
    ]);
    return {
        ...toggles,
        profiles,
        context,
        values: Object.fromEntries(entries)
    };
}
function normalizeBranchProtection(branchProtection) {
    const actual = branchProtection.actual
        ? {
            ...branchProtection.actual,
            contexts: sortUnique(branchProtection.actual.contexts)
        }
        : undefined;
    return {
        ...branchProtection,
        expected: sortUnique(branchProtection.expected),
        produced: sortUnique(branchProtection.produced),
        notes: sortUnique(branchProtection.notes),
        actual
    };
}
function normalizeArtifacts(artifacts) {
    if (!artifacts || artifacts.length === 0) {
        return undefined;
    }
    const next = artifacts.map((artifact) => ({ ...artifact }));
    next.sort((a, b) => {
        const nameCompare = a.name.localeCompare(b.name);
        if (nameCompare !== 0) {
            return nameCompare;
        }
        return (a.path ?? '').localeCompare(b.path ?? '');
    });
    return next;
}
function normalizeTestCases(cases) {
    if (!cases || cases.length === 0) {
        return undefined;
    }
    const cloned = cases.map((testCase) => {
        const normalized = { ...testCase };
        if (normalized.id !== undefined) {
            normalized.id = String(normalized.id);
        }
        const requirementValue = normalized.requirement;
        if (requirementValue === undefined || requirementValue === null || String(requirementValue).trim().length === 0) {
            if (normalized.id && normalized.id.trim().length > 0) {
                normalized.requirement = normalized.id;
            }
        }
        else {
            normalized.requirement = String(requirementValue);
        }
        return normalized;
    });
    cloned.sort((a, b) => a.id.localeCompare(b.id));
    return cloned;
}
function normalizeTests(tests) {
    if (!tests) {
        return undefined;
    }
    return {
        ...tests,
        cases: normalizeTestCases(tests.cases)
    };
}
function normalizeNotes(notes) {
    return sortUnique(notes);
}
function normalizeBranchState(state) {
    if (!state) {
        return undefined;
    }
    const trim = (value) => {
        if (typeof value !== 'string') {
            return undefined;
        }
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : undefined;
    };
    const summary = trim(state.summary);
    const timestamp = trim(state.timestampUtc);
    if (!summary || !timestamp) {
        return undefined;
    }
    const normalizeNumber = (value) => typeof value === 'number' && Number.isFinite(value) ? value : undefined;
    const normalizeBoolean = (value) => typeof value === 'boolean' ? value : undefined;
    const normalized = {
        summary,
        timestampUtc: timestamp
    };
    const optionalBranch = trim(state.branch);
    if (optionalBranch) {
        normalized.branch = optionalBranch;
    }
    const optionalUpstream = trim(state.upstream);
    if (optionalUpstream) {
        normalized.upstream = optionalUpstream;
    }
    const ahead = normalizeNumber(state.ahead);
    if (ahead !== undefined) {
        normalized.ahead = ahead;
    }
    const behind = normalizeNumber(state.behind);
    if (behind !== undefined) {
        normalized.behind = behind;
    }
    const hasUpstream = normalizeBoolean(state.hasUpstream);
    if (hasUpstream !== undefined) {
        normalized.hasUpstream = hasUpstream;
    }
    const isClean = normalizeBoolean(state.isClean);
    if (isClean !== undefined) {
        normalized.isClean = isClean;
    }
    const hasUntracked = normalizeBoolean(state.hasUntracked);
    if (hasUntracked !== undefined) {
        normalized.hasUntracked = hasUntracked;
    }
    return normalized;
}
function normalizeStringRecord(record) {
    if (!record) {
        return undefined;
    }
    const entries = Object.entries(record)
        .filter(([_, value]) => typeof value === 'string')
        .sort(([a], [b]) => a.localeCompare(b));
    return Object.fromEntries(entries);
}
function normalizeExtra(extra) {
    if (!extra) {
        return undefined;
    }
    const entries = Object.entries(extra).sort(([a], [b]) => a.localeCompare(b));
    return Object.fromEntries(entries);
}
export class SessionIndexBuilder {
    constructor(base) {
        this.index = {
            schema: 'session-index/v2',
            schemaVersion: '2.0.0',
            generatedAtUtc: new Date().toISOString(),
            run: base.run ?? {
                workflow: 'unknown'
            },
            environment: base.environment,
            branchProtection: base.branchProtection,
            tests: base.tests,
            artifacts: base.artifacts,
            notes: base.notes,
            extra: base.extra
        };
    }
    static create() {
        return new SessionIndexBuilder({});
    }
    withGeneratedAt(date) {
        this.index.generatedAtUtc = date.toISOString();
        return this;
    }
    setRun(run) {
        const next = { ...this.index.run, ...run };
        next.branchState = normalizeBranchState(run.branchState ?? this.index.run.branchState);
        this.index.run = next;
        return this;
    }
    setBranchState(state) {
        this.index.run = {
            ...this.index.run,
            branchState: normalizeBranchState(state)
        };
        return this;
    }
    setEnvironment(env) {
        const merged = {
            ...(this.index.environment ?? {}),
            ...(env ?? {})
        };
        if (merged.toggles) {
            merged.toggles = normalizeToggleValues(merged.toggles);
        }
        merged.custom = normalizeStringRecord(merged.custom);
        this.index.environment = merged;
        return this;
    }
    setEnvironmentToggles(toggles) {
        const environment = this.index.environment ?? {};
        environment.toggles = normalizeToggleValues(toggles);
        environment.custom = normalizeStringRecord(environment.custom);
        this.index.environment = environment;
        return this;
    }
    setBranchProtection(bp) {
        if (!bp) {
            this.index.branchProtection = undefined;
            return this;
        }
        if (this.index.branchProtection) {
            this.index.branchProtection = normalizeBranchProtection({
                ...this.index.branchProtection,
                ...bp
            });
        }
        else {
            this.index.branchProtection = normalizeBranchProtection({ ...bp });
        }
        return this;
    }
    addBranchProtectionNotes(...notes) {
        if (!this.index.branchProtection) {
            this.index.branchProtection = {
                status: 'warn',
                notes: []
            };
        }
        const existing = this.index.branchProtection.notes ?? [];
        this.index.branchProtection.notes = normalizeNotes([
            ...existing,
            ...notes.filter(Boolean)
        ]);
        return this;
    }
    setTestsSummary(summary) {
        const tests = { ...(this.index.tests ?? {}) };
        tests.summary = summary;
        this.index.tests = normalizeTests(tests);
        return this;
    }
    addTestCase(testCase) {
        const tests = { ...(this.index.tests ?? {}) };
        const existingCases = tests.cases ?? [];
        tests.cases = normalizeTestCases([...existingCases, testCase]);
        this.index.tests = normalizeTests(tests);
        return this;
    }
    addArtifact(artifact) {
        const artifacts = this.index.artifacts ?? [];
        this.index.artifacts = normalizeArtifacts([...artifacts, artifact]);
        return this;
    }
    addNote(note) {
        if (!note) {
            return this;
        }
        const notes = this.index.notes ?? [];
        this.index.notes = normalizeNotes([...notes, note]);
        return this;
    }
    setExtra(key, value) {
        this.index.extra = normalizeExtra({ ...(this.index.extra ?? {}), [key]: value });
        return this;
    }
    toJSON() {
        return {
            ...this.index,
            run: {
                ...this.index.run,
                branchState: normalizeBranchState(this.index.run.branchState)
            },
            artifacts: normalizeArtifacts(this.index.artifacts),
            branchProtection: this.index.branchProtection
                ? normalizeBranchProtection(this.index.branchProtection)
                : undefined,
            environment: this.index.environment
                ? {
                    ...this.index.environment,
                    toggles: this.index.environment.toggles
                        ? normalizeToggleValues(this.index.environment.toggles)
                        : undefined,
                    custom: normalizeStringRecord(this.index.environment.custom)
                }
                : undefined,
            notes: normalizeNotes(this.index.notes),
            tests: normalizeTests(this.index.tests),
            extra: normalizeExtra(this.index.extra)
        };
    }
    build() {
        const normalized = this.toJSON();
        Object.assign(this.index, normalized);
        this.index.run = normalized.run;
        this.index.artifacts = normalized.artifacts;
        this.index.branchProtection = normalized.branchProtection;
        this.index.environment = normalized.environment;
        this.index.notes = normalized.notes;
        this.index.tests = normalized.tests;
        this.index.extra = normalized.extra;
        return sessionIndexSchema.parse(normalized);
    }
}
export function createSessionIndexBuilder() {
    return SessionIndexBuilder.create();
}
