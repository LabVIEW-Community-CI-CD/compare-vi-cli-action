import { z } from 'zod';

export type SchemaEntry = {
  id: string;
  fileName: string;
  description?: string;
  schema: z.ZodTypeAny;
};

const isoString = z.string().min(1);
const optionalIsoString = isoString.optional();

const agentRunContext = z
  .object({
    sha: z.string().nullish(),
    ref: z.string().nullish(),
    workflow: z.string().nullish(),
    job: z.string().nullish(),
    actor: z.string().nullish(),
  })
  .passthrough();

const agentWaitMarkerSchema = z.object({
  schema: z.literal('agent-wait/v1'),
  id: z.string().min(1),
  reason: z.string().min(1),
  expectedSeconds: z.number(),
  toleranceSeconds: z.number(),
  startedUtc: isoString,
  startedUnixSeconds: z.number(),
  workspace: z.string().min(1),
  sketch: z.string().min(1),
  runContext: agentRunContext,
});

const agentWaitResultSchema = z.object({
  schema: z.literal('agent-wait-result/v1'),
  id: z.string().min(1),
  reason: z.string().min(1),
  expectedSeconds: z.number(),
  startedUtc: isoString,
  endedUtc: isoString,
  elapsedSeconds: z.number(),
  toleranceSeconds: z.number(),
  differenceSeconds: z.number(),
  withinMargin: z.boolean(),
  markerPath: z.string().min(1),
  sketch: z.string().min(1),
  runContext: agentRunContext,
});

const compareExecSchema = z.object({
  schema: z.literal('compare-exec/v1'),
  generatedAt: isoString,
  cliPath: z.string().min(1),
  command: z.string().min(1),
  args: z.array(z.union([z.string(), z.number(), z.boolean(), z.record(z.any()), z.array(z.any())])).optional(),
  exitCode: z.number(),
  diff: z.boolean(),
  cwd: z.string().min(1),
  duration_s: z.number(),
  duration_ns: z.number(),
  base: z.string().min(1),
  head: z.string().min(1),
});

const pesterRunBlock = z
  .object({
    startTime: isoString.optional(),
    endTime: isoString.optional(),
    wallClockSeconds: z.number().optional(),
  })
  .partial();

const pesterSelectionBlock = z
  .object({
    totalDiscoveredFileCount: z.number().optional(),
    selectedTestFileCount: z.number().optional(),
    maxTestFilesApplied: z.boolean().optional(),
  })
  .partial();

const pesterTimingBlock = z
  .object({
    count: z.number(),
    totalMs: z.number(),
    minMs: z.number().nullable(),
    maxMs: z.number().nullable(),
    meanMs: z.number().nullable(),
    medianMs: z.number().nullable(),
    stdDevMs: z.number().nullable(),
    p50Ms: z.number().nullable().optional(),
    p75Ms: z.number().nullable().optional(),
    p90Ms: z.number().nullable().optional(),
    p95Ms: z.number().nullable().optional(),
    p99Ms: z.number().nullable().optional(),
  })
  .partial();

const pesterSummarySchema = z.object({
  total: z.number(),
  passed: z.number(),
  failed: z.number(),
  errors: z.number(),
  skipped: z.number(),
  duration_s: z.number(),
  timestamp: isoString,
  pesterVersion: z.string().min(1),
  includeIntegration: z.boolean(),
  meanTest_ms: z.number().optional(),
  p95Test_ms: z.number().optional(),
  maxTest_ms: z.number().optional(),
  schemaVersion: z.string().min(1),
  timedOut: z.boolean(),
  discoveryFailures: z.number().optional(),
  environment: z
    .object({
      osPlatform: z.string().optional(),
      psVersion: z.string().optional(),
      pesterModulePath: z.string().optional(),
    })
    .optional(),
  run: pesterRunBlock.optional(),
  selection: pesterSelectionBlock.optional(),
  timing: pesterTimingBlock.optional(),
  stability: z
    .object({
      supportsRetries: z.boolean().optional(),
      retryAttempts: z.number().optional(),
      initialFailed: z.number().optional(),
      finalFailed: z.number().optional(),
      recovered: z.boolean().optional(),
      flakySuspects: z.array(z.string()).optional(),
      retriedTestFiles: z.array(z.string()).optional(),
    })
    .optional(),
  discovery: z
    .object({
      failureCount: z.number(),
      patterns: z.array(z.string()),
      sampleLimit: z.number(),
      samples: z.array(
        z.object({
          index: z.number(),
          snippet: z.string(),
        })
      ),
      truncated: z.boolean().optional(),
    })
    .optional(),
  outcome: z
    .object({
      overallStatus: z.enum(['Success', 'Failed', 'Timeout', 'DiscoveryFailure', 'Partial']),
      severityRank: z.number(),
      flags: z.array(z.string()),
      counts: z.object({
        total: z.number(),
        passed: z.number(),
        failed: z.number(),
        errors: z.number(),
        skipped: z.number(),
        discoveryFailures: z.number().optional(),
      }),
    })
    .optional(),
});

const pesterLeakReportSchema = z.object({
  schema: z.literal('pester-leak-report/v1'),
  schemaVersion: z.string().min(1),
  generatedAt: isoString,
  targets: z.array(z.string()),
  graceSeconds: z.number(),
  waitedMs: z.number(),
  procsBefore: z.array(z.any()),
  procsAfter: z.array(z.any()),
  runningJobs: z.array(z.any()),
  allJobs: z.array(z.any()),
  jobsBefore: z.array(z.any()),
  leakDetected: z.boolean(),
  actions: z.array(z.string()),
  killedProcs: z.array(z.any()),
  stoppedJobs: z.array(z.any()),
  notes: z.array(z.string()).optional(),
});

const singleCompareStateSchema = z.object({
  schema: z.literal('single-compare-state/v1'),
  handled: z.boolean(),
  since: isoString,
  metadata: z.record(z.any()).optional(),
  runId: z.string().optional(),
});

const testStandCompareSessionSchema = z.object({
  schema: z.literal('teststand-compare-session/v1'),
  at: isoString,
  warmup: z.object({
    events: z.string().min(1),
  }),
  compare: z.object({
    events: z.string().min(1),
    capture: z.string().min(1),
    report: z.boolean(),
  }),
  outcome: z
    .object({
      exitCode: z.number(),
      seconds: z.number().optional(),
      command: z.string().optional(),
      diff: z.boolean().optional(),
    })
    .nullable(),
  error: z.string().optional(),
});

const invokerEventSchema = z.object({
  timestamp: isoString,
  schema: z.literal('pester-invoker/v1'),
  type: z.string().min(1),
  runId: z.string().optional(),
  file: z.string().optional(),
  slug: z.string().optional(),
  category: z.string().optional(),
  durationMs: z.number().optional(),
  counts: z
    .object({
      passed: z.number().optional(),
      failed: z.number().optional(),
      skipped: z.number().optional(),
      errors: z.number().optional(),
    })
    .optional(),
});

export const schemas: SchemaEntry[] = [
  {
    id: 'agent-wait-marker',
    fileName: 'agent-wait-marker.schema.json',
    description: 'Marker emitted when an Agent wait window starts.',
    schema: agentWaitMarkerSchema,
  },
  {
    id: 'agent-wait-result',
    fileName: 'agent-wait-result.schema.json',
    description: 'Result emitted when an Agent wait window closes.',
    schema: agentWaitResultSchema,
  },
  {
    id: 'compare-exec',
    fileName: 'compare-exec.schema.json',
    description: 'Execution metadata captured for a single LVCompare invocation.',
    schema: compareExecSchema,
  },
  {
    id: 'pester-summary',
    fileName: 'pester-summary.schema.json',
    description: 'Summary produced by Invoke-PesterTests.ps1 for a test run.',
    schema: pesterSummarySchema,
  },
  {
    id: 'pester-leak-report',
    fileName: 'pester-leak-report.schema.json',
    description: 'Leak detection report emitted after Invoke-PesterTests.ps1 completes.',
    schema: pesterLeakReportSchema,
  },
  {
    id: 'single-compare-state',
    fileName: 'single-compare-state.schema.json',
    description: 'State file used to gate single compare invocations.',
    schema: singleCompareStateSchema,
  },
  {
    id: 'teststand-compare-session',
    fileName: 'teststand-compare-session.schema.json',
    description: 'Session index emitted by tools/TestStand-CompareHarness.ps1.',
    schema: testStandCompareSessionSchema,
  },
  {
    id: 'pester-invoker-event',
    fileName: 'pester-invoker-event.schema.json',
    description: 'Event crumb written by the TypeScript/PowerShell invoker loop.',
    schema: invokerEventSchema,
  },
];
