import { sessionIndexSchema } from './schema.js';
import type {
  SessionIndexArtifact,
  SessionIndexTestCase,
  SessionIndexV2
} from './schema.js';

export class SessionIndexBuilder {
  private readonly index: SessionIndexV2;

  private constructor(base: Partial<SessionIndexV2>) {
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

  public static create(): SessionIndexBuilder {
    return new SessionIndexBuilder({});
  }

  public withGeneratedAt(date: Date): this {
    this.index.generatedAtUtc = date.toISOString();
    return this;
  }

  public setRun(run: SessionIndexV2['run']): this {
    this.index.run = { ...this.index.run, ...run };
    return this;
  }

  public setEnvironment(env: SessionIndexV2['environment']): this {
    this.index.environment = { ...(this.index.environment ?? {}), ...env };
    return this;
  }

  public setEnvironmentToggles(
    toggles: NonNullable<NonNullable<SessionIndexV2['environment']>['toggles']>
  ): this {
    const environment = this.index.environment ?? {};
    environment.toggles = toggles;
    this.index.environment = environment;
    return this;
  }

  public setBranchProtection(bp: SessionIndexV2['branchProtection'] | undefined): this {
    if (!bp) {
      this.index.branchProtection = undefined;
      return this;
    }
    if (this.index.branchProtection) {
      this.index.branchProtection = { ...this.index.branchProtection, ...bp };
    } else {
      this.index.branchProtection = { ...bp };
    }
    return this;
  }

  public addBranchProtectionNotes(...notes: string[]): this {
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

  public setTestsSummary(summary: NonNullable<SessionIndexV2['tests']>['summary']): this {
    const tests = this.index.tests ?? {};
    this.index.tests = { ...tests, summary };
    return this;
  }

  public addTestCase(testCase: SessionIndexTestCase): this {
    const tests = this.index.tests ?? {};
    const cases = tests.cases ?? [];
    tests.cases = [...cases, testCase];
    this.index.tests = tests;
    return this;
  }

  public addArtifact(artifact: SessionIndexArtifact): this {
    const artifacts = this.index.artifacts ?? [];
    this.index.artifacts = [...artifacts, artifact];
    return this;
  }

  public addNote(note: string): this {
    if (!note) {
      return this;
    }
    const notes = this.index.notes ?? [];
    this.index.notes = [...notes, note];
    return this;
  }

  public setExtra(key: string, value: unknown): this {
    this.index.extra = { ...(this.index.extra ?? {}), [key]: value };
    return this;
  }

  public toJSON(): SessionIndexV2 {
    return { ...this.index };
  }

  public build(): SessionIndexV2 {
    return sessionIndexSchema.parse(this.index);
  }
}

export function createSessionIndexBuilder(): SessionIndexBuilder {
  return SessionIndexBuilder.create();
}
