import { sessionIndexSchema } from './schema.js';
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
        this.index.run = { ...this.index.run, ...run };
        return this;
    }
    setEnvironment(env) {
        this.index.environment = { ...(this.index.environment ?? {}), ...env };
        return this;
    }
    setBranchProtection(bp) {
        if (!bp) {
            this.index.branchProtection = undefined;
            return this;
        }
        if (this.index.branchProtection) {
            this.index.branchProtection = { ...this.index.branchProtection, ...bp };
        }
        else {
            this.index.branchProtection = { ...bp };
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
        this.index.branchProtection.notes = [
            ...existing,
            ...notes.filter(Boolean)
        ];
        return this;
    }
    setTestsSummary(summary) {
        const tests = this.index.tests ?? {};
        this.index.tests = { ...tests, summary };
        return this;
    }
    addTestCase(testCase) {
        const tests = this.index.tests ?? {};
        const cases = tests.cases ?? [];
        tests.cases = [...cases, testCase];
        this.index.tests = tests;
        return this;
    }
    addArtifact(artifact) {
        const artifacts = this.index.artifacts ?? [];
        this.index.artifacts = [...artifacts, artifact];
        return this;
    }
    addNote(note) {
        if (!note) {
            return this;
        }
        const notes = this.index.notes ?? [];
        this.index.notes = [...notes, note];
        return this;
    }
    setExtra(key, value) {
        this.index.extra = { ...(this.index.extra ?? {}), [key]: value };
        return this;
    }
    toJSON() {
        return { ...this.index };
    }
    build() {
        return sessionIndexSchema.parse(this.index);
    }
}
export function createSessionIndexBuilder() {
    return SessionIndexBuilder.create();
}
