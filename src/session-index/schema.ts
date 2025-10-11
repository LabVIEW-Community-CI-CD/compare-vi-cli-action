import { z } from 'zod';

export const triggerSchema = z
  .object({
    kind: z.string().optional(),
    number: z.number().optional(),
    author: z.string().optional(),
    commentId: z.union([z.number(), z.string()]).optional(),
    commentUrl: z.string().optional()
  })
  .strict();

export const runSchema = z
  .object({
    id: z.string().optional(),
    attempt: z.number().int().nonnegative().optional(),
    workflow: z.string(),
    job: z.string().optional(),
    branch: z.string().optional(),
    commit: z.string().optional(),
    repository: z.string().optional(),
    trigger: triggerSchema.optional()
  })
  .strict();

const toggleValueEntrySchema = z
  .object({
    value: z.union([z.string(), z.number(), z.boolean()]),
    valueType: z.enum(['string', 'number', 'boolean']),
    source: z.enum(['default', 'profile', 'variant', 'environment']),
    key: z.string().optional(),
    profile: z.string().optional(),
    variant: z.string().optional(),
    description: z.string().optional()
  })
  .strict();

const toggleContextSchema = z
  .object({
    describe: z.string().optional(),
    it: z.string().optional(),
    tags: z.array(z.string()).optional()
  })
  .strict();

const toggleValuesSchema = z
  .object({
    schema: z.literal('agent-toggle-values/v1'),
    schemaVersion: z.string(),
    generatedAtUtc: z.string(),
    manifestDigest: z.string(),
    manifestGeneratedAtUtc: z.string(),
    profiles: z.array(z.string()),
    context: toggleContextSchema.optional(),
    values: z.record(toggleValueEntrySchema)
  })
  .strict();

export const environmentSchema = z
  .object({
    runner: z.string().optional(),
    runnerImage: z.string().optional(),
    os: z.string().optional(),
    node: z.string().optional(),
    pwsh: z.string().optional(),
    git: z.string().optional(),
    toggles: toggleValuesSchema.optional(),
    custom: z.record(z.string()).optional()
  })
  .strict();

export const branchProtectionSchema = z
  .object({
    status: z.enum(['ok', 'warn', 'error']),
    reason: z
      .enum([
        'aligned',
        'missing_required',
        'extra_required',
        'mismatch',
        'mapping_missing',
        'api_unavailable',
        'api_error',
        'api_forbidden'
      ])
      .optional(),
    expected: z.array(z.string()).optional(),
    produced: z.array(z.string()).optional(),
    actual: z
      .object({
        status: z.enum(['available', 'unavailable', 'error']),
        contexts: z.array(z.string()).optional()
      })
      .optional(),
    mapping: z
      .object({
        path: z.string(),
        digest: z.string()
      })
      .optional(),
    notes: z.array(z.string()).optional()
  })
  .strict();

export const testCaseSchema = z
  .object({
    id: z.string(),
    description: z.string().optional(),
    category: z.string().optional(),
    requirement: z.string().optional(),
    rationale: z.string().optional(),
    expectedResult: z.string().optional(),
    outcome: z.enum(['passed', 'failed', 'skipped', 'error', 'unknown']),
    durationMs: z.number().nonnegative().optional(),
    retry: z.number().int().min(0).optional(),
    artifacts: z.array(z.string()).optional(),
    tags: z.array(z.string()).optional(),
    diagnostics: z.array(z.string()).optional()
  })
  .strict();

export const testsSchema = z
  .object({
    summary: z
      .object({
        total: z.number().int().nonnegative(),
        passed: z.number().int().nonnegative(),
        failed: z.number().int().nonnegative(),
        errors: z.number().int().nonnegative(),
        skipped: z.number().int().nonnegative(),
        durationSeconds: z.number().nonnegative().optional()
      })
      .strict()
      .optional(),
    cases: z.array(testCaseSchema).optional()
  })
  .strict();

export const artifactSchema = z
  .object({
    name: z.string(),
    path: z.string(),
    kind: z
      .enum(['summary', 'report', 'log', 'artifact', 'traceability', 'custom'])
      .optional(),
    mimeType: z.string().optional(),
    sizeBytes: z.number().int().nonnegative().optional(),
    checksum: z
      .object({
        algorithm: z.string(),
        value: z.string()
      })
      .optional()
  })
  .strict();

export const sessionIndexSchema = z
  .object({
    schema: z.literal('session-index/v2'),
    schemaVersion: z.string().regex(/^\d+\.\d+\.\d+$/),
    generatedAtUtc: z.string(),
    run: runSchema,
    environment: environmentSchema.optional(),
    branchProtection: branchProtectionSchema.optional(),
    tests: testsSchema.optional(),
    artifacts: z.array(artifactSchema).optional(),
    notes: z.array(z.string()).optional(),
    extra: z.record(z.unknown()).optional()
  })
  .strict();

export type SessionIndexV2 = z.infer<typeof sessionIndexSchema>;
export type SessionIndexTestCase = z.infer<typeof testCaseSchema>;
export type SessionIndexArtifact = z.infer<typeof artifactSchema>;
