import { z } from 'zod';
const isoString = z.string().min(1);
export const cliCompareExpectedDiffSchema = z.union([z.literal('true'), z.literal('false'), z.literal('unknown')]);
export const cliCompareQueueCaseSchema = z
    .object({
    id: z.string().min(1),
    name: z.string().min(1),
    base: z.string().min(1),
    head: z.string().min(1),
    tags: z.array(z.string().min(1)).optional(),
    expected: z.object({
        diff: cliCompareExpectedDiffSchema,
        exitCodes: z.array(z.number().int()).optional(),
    }),
    cli: z
        .object({
        format: z.enum(['XML', 'HTML', 'TXT', 'DOCX']).optional(),
        extraArgs: z.array(z.string()).optional(),
    })
        .partial()
        .optional(),
    overrides: z
        .object({
        labviewCliPath: z.string().min(1).optional(),
    })
        .partial()
        .optional(),
    notes: z.string().optional(),
    disabled: z.boolean().optional(),
})
    .passthrough();
export const cliCompareQueueSchema = z
    .object({
    schema: z.literal('cli-compare-queue/v1'),
    generatedAt: isoString.optional(),
    updatedAt: isoString.optional(),
    cases: z.array(cliCompareQueueCaseSchema),
})
    .passthrough();
export const cliCompareQueueSummaryEntrySchema = z
    .object({
    index: z.number().int().min(1),
    id: z.string().min(1),
    name: z.string().min(1),
    tags: z.array(z.string().min(1)).optional(),
    base: z.string().min(1),
    head: z.string().min(1),
    expectedDiff: cliCompareExpectedDiffSchema,
    expectedExitCodes: z.array(z.number().int()).optional(),
    status: z.enum(['pending', 'passed', 'failed', 'error']),
    notes: z.string().optional(),
    nunit: z.string().optional(),
    exec: z.string().optional(),
    exitCode: z.number().optional(),
    diff: z.boolean().optional(),
    diffUnknown: z.boolean().optional(),
    validator: z.enum(['skipped', 'passed', 'failed']).optional(),
    validatorMessage: z.string().optional(),
    report: z.string().optional(),
})
    .passthrough();
export const cliCompareQueueSummarySchema = z
    .object({
    schema: z.literal('cli-compare-queue-summary/v1'),
    generatedAt: isoString,
    casesPath: z.string().min(1),
    resultsRoot: z.string().min(1),
    selection: z.object({
        filter: z.string().optional().nullable(),
        indexes: z.array(z.number().int().min(1)),
    }),
    cases: z.array(cliCompareQueueSummaryEntrySchema),
    success: z.boolean(),
})
    .passthrough();
