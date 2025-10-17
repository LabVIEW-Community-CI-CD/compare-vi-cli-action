import { z } from 'zod';

const isoString = z.string().min(1);
const optionalIsoString = isoString.optional();
const nonNegativeInteger = z.number().int().min(0);

const hexSha256 = z.string().regex(/^[A-Fa-f0-9]{64}$/);

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

const cliArtifactsImageSchema = z
  .object({
    index: nonNegativeInteger.optional(),
    mimeType: z.string().min(1).optional(),
    dataLength: nonNegativeInteger.optional(),
    byteLength: nonNegativeInteger.optional(),
    savedPath: z.string().min(1).optional(),
    source: z.string().min(1).optional(),
    decodeError: z.string().min(1).optional(),
  })
  .passthrough();

const cliArtifactsSchema = z
  .object({
    reportSizeBytes: nonNegativeInteger.optional(),
    imageCount: nonNegativeInteger.optional(),
    exportDir: z.string().min(1).optional(),
    images: z.array(cliArtifactsImageSchema).optional(),
  })
  .passthrough();

const cliInfoSchema = z.object({
  path: z.string().min(1).optional(),
  version: z.string().min(1).optional(),
  reportType: z.string().min(1).optional(),
  reportPath: z.string().min(1).optional(),
  status: z.string().min(1).optional(),
  message: z.string().min(1).optional(),
  artifacts: cliArtifactsSchema.optional(),
});

const lvCompareEnvironmentSchema = z
  .object({
    lvcompareVersion: z.string().min(1).optional(),
    labviewVersion: z.string().min(1).optional(),
    bitness: z.enum(['x86', 'x64']).optional(),
    osVersion: z.string().min(1).optional(),
    arch: z.string().min(1).optional(),
    compareMode: z.string().min(1).optional(),
    comparePolicy: z.string().min(1).optional(),
    cli: cliInfoSchema.optional(),
    runner: z
      .object({
        labels: z.array(z.string().min(1)).optional(),
        identityHash: z.string().min(1).optional(),
      })
      .optional(),
  })
  .passthrough();

const lvCompareCaptureSchema = z
  .object({
    schema: z.literal('lvcompare-capture-v1'),
    timestamp: isoString,
    base: z.string().min(1),
    head: z.string().min(1),
    cliPath: z.string().min(1),
    args: z.array(z.string()),
    exitCode: z.number(),
    seconds: z.number(),
    stdoutLen: z.number(),
    stderrLen: z.number(),
    command: z.string().min(1),
    stdout: z.union([z.string(), z.null()]).optional(),
    stderr: z.union([z.string(), z.null()]).optional(),
    environment: lvCompareEnvironmentSchema.optional(),
  })
  .passthrough();

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
  integrationMode: z.enum(['include', 'exclude', 'auto']).nullable().optional(),
  integrationSource: z.string().min(1).nullable().optional(),
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
          file: z.string(),
          reason: z.string().optional(),
        }),
      ),
    })
    .optional(),
  manifest: z
    .object({
      discovered: z.array(z.string()),
      selected: z.array(z.string()),
    })
    .optional(),
  summary: z
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

const childProcItemSchema = z.object({
  pid: nonNegativeInteger,
  ws: nonNegativeInteger,
  pm: nonNegativeInteger,
  title: z.string().nullable().optional(),
  cmd: z.string().nullable().optional(),
});

const childProcGroupSchema = z.object({
  count: nonNegativeInteger,
  memory: z.object({
    ws: nonNegativeInteger,
    pm: nonNegativeInteger,
  }),
  items: z.array(childProcItemSchema),
});

const childProcSnapshotSchema = z.object({
  schema: z.literal('child-procs-snapshot/v1'),
  at: isoString,
  groups: z.record(childProcGroupSchema),
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

const dispatcherResultsGuardSchema = z
  .object({
    schema: z.literal('dispatcher-results-guard/v1'),
    at: isoString,
    path: z.string().min(1),
    message: z.string().min(1),
  })
  .passthrough();

const warmupModeSchema = z.enum(['detect', 'spawn', 'skip']);
const warmupEventsSchema = z.union([z.string().min(1), z.null()]);

const compareCliSchema = cliInfoSchema;

const comparePolicySchema = z.enum(['lv-first', 'cli-first', 'cli-only', 'lv-only']);

const testStandCompareSessionSchema = z.object({
  schema: z.literal('teststand-compare-session/v1'),
  at: isoString,
  warmup: z.object({
    mode: warmupModeSchema,
    events: warmupEventsSchema,
  }),
  compare: z.object({
    events: z.string().min(1),
    capture: z.union([z.string().min(1), z.null()]),
    report: z.boolean(),
    command: z.string().min(1).optional(),
    cliPath: z.string().min(1).optional(),
    cli: compareCliSchema.optional(),
    policy: comparePolicySchema.optional(),
    mode: z.string().min(1).optional(),
    autoCli: z.boolean().optional(),
    sameName: z.boolean().optional(),
    timeoutSeconds: z.number().min(0).optional(),
  }),
  outcome: z
    .object({
      exitCode: z.number(),
      seconds: z.number().optional(),
      command: z.string().optional(),
      diff: z.boolean().optional(),
    })
    .nullable(),
  error: z.union([z.string().min(1), z.null()]).optional(),
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

const invokerCurrentRunSchema = z.object({
  schema: z.literal('pester-invoker-current-run/v1'),
  runId: z.string().min(1),
  startedAt: isoString,
});

export const cliVersionSchema = z
  .object({
    name: z.string().min(1),
    assemblyVersion: z.string().min(1),
    informationalVersion: z.string().min(1),
    framework: z.string().min(1),
    os: z.string().min(1),
  })
  .passthrough();

export const cliTokenizeSchema = z.object({
  raw: z.array(z.string()),
  normalized: z.array(z.string()),
});

export const cliQuoteSchema = z.object({
  input: z.string().nullable(),
  quoted: z.string(),
});

export const cliProcsSchema = z.object({
  labviewPids: z.array(nonNegativeInteger),
  lvcomparePids: z.array(nonNegativeInteger),
  labviewCliPids: z.array(nonNegativeInteger),
  gcliPids: z.array(nonNegativeInteger),
});

const cliOperationsDefaultValue = z.union([z.string(), z.number(), z.boolean(), z.null()]);

export const cliOperationsParameterSchema = z
  .object({
    id: z.string().min(1),
    type: z.string().min(1).optional(),
    required: z.boolean().optional(),
    env: z.array(z.string().min(1)).optional(),
    default: cliOperationsDefaultValue.optional(),
    description: z.string().optional(),
  })
  .passthrough();

const ensureCountMatches = <
  TObject extends Record<TCountKey, number> & Record<TArrayKey, readonly unknown[]>,
  TCountKey extends keyof TObject,
  TArrayKey extends keyof TObject
>(
  countKey: TCountKey,
  arrayKey: TArrayKey,
  message: string,
): z.SuperRefinement<TObject> => {
  return (value, ctx) => {
    if (value[countKey] !== value[arrayKey].length) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message,
      });
    }
  };
};

const cliOperationsBaseSchema = z.object({
  schema: z.literal('comparevi-cli/operations@v1'),
  operationCount: nonNegativeInteger,
  operations: z
    .array(
      z
        .object({
          name: z.string().min(1),
          parameters: z.array(cliOperationsParameterSchema).optional(),
        })
        .passthrough(),
    )
    .min(1),
});

const ensureCliOperationCountMatches = ensureCountMatches<
  z.infer<typeof cliOperationsBaseSchema>,
  'operationCount',
  'operations'
>(
  'operationCount',
  'operations',
  'operationCount must equal operations.length',
);

export const cliOperationsSchema = cliOperationsBaseSchema.superRefine(ensureCliOperationCountMatches);

const cliOperationNamesBaseSchema = z.object({
  schema: z.literal('comparevi-cli/operation-names@v1'),
  operationCount: nonNegativeInteger,
  names: z.array(z.string().min(1)).min(1),
});

const ensureCliOperationNameCountMatches = ensureCountMatches<
  z.infer<typeof cliOperationNamesBaseSchema>,
  'operationCount',
  'names'
>(
  'operationCount',
  'names',
  'operationCount must equal names.length',
);

export const cliOperationNamesSchema = cliOperationNamesBaseSchema.superRefine(
  ensureCliOperationNameCountMatches,
);

const cliProviderBinarySchema = z
  .object({
    env: z.array(z.string().min(1)).optional(),
  })
  .passthrough();

const cliProviderSpecSchema = z
  .object({
    id: z.string().min(1),
    displayName: z.string().min(1).optional(),
    description: z.string().min(1).optional(),
    binary: cliProviderBinarySchema.optional(),
    operations: z.array(z.string().min(1)).optional(),
  })
  .passthrough();

const cliProvidersBaseSchema = z.object({
  schema: z.literal('comparevi-cli/providers@v1'),
  providerCount: nonNegativeInteger,
  providers: z.array(cliProviderSpecSchema).min(1),
});

const ensureCliProviderCountMatches = ensureCountMatches<
  z.infer<typeof cliProvidersBaseSchema>,
  'providerCount',
  'providers'
>(
  'providerCount',
  'providers',
  'providerCount must equal providers.length',
);

export const cliProvidersSchema = cliProvidersBaseSchema.superRefine(ensureCliProviderCountMatches);

const cliProviderBaseSchema = z.object({
  schema: z.literal('comparevi-cli/provider@v1'),
  providerId: z.string().min(1),
  provider: cliProviderSpecSchema,
});

const ensureCliProviderIdMatches = ((value, ctx) => {
  if (value.providerId.localeCompare(value.provider.id, undefined, { sensitivity: 'accent' }) !== 0) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      message: 'providerId must match provider.id (case-insensitive)',
    });
  }
}) satisfies z.SuperRefinement<z.infer<typeof cliProviderBaseSchema>>;

export const cliProviderSchema = cliProviderBaseSchema.superRefine(ensureCliProviderIdMatches);

const cliProviderNamesBaseSchema = z.object({
  schema: z.literal('comparevi-cli/provider-names@v1'),
  providerCount: nonNegativeInteger,
  names: z.array(z.string().min(1)).min(1),
});

const ensureCliProviderNameCountMatches = ensureCountMatches<
  z.infer<typeof cliProviderNamesBaseSchema>,
  'providerCount',
  'names'
>(
  'providerCount',
  'names',
  'providerCount must equal names.length',
);

export const cliProviderNamesSchema = cliProviderNamesBaseSchema.superRefine(
  ensureCliProviderNameCountMatches,
);

const cliArtifactFileSchema = z.object({
  path: z.string().min(1),
  sha256: hexSha256,
  bytes: nonNegativeInteger,
});

export const cliArtifactMetaSchema = z.object({
  gitSha: z.string().min(1).optional(),
  branch: z.string().min(1).optional(),
  generatedAt: isoString.optional(),
  files: z.array(cliArtifactFileSchema).min(1),
});

export const watcherRestSchema = z.object({
  schema: z.literal('ci-watch/rest-v1'),
  repo: z.string().min(1),
  runId: nonNegativeInteger.min(1),
  branch: z.string().optional(),
  headSha: z.string().optional(),
  status: z.string().optional(),
  conclusion: z.string().optional(),
  htmlUrl: z.string().optional(),
  displayTitle: z.string().optional(),
  polledAtUtc: isoString,
  jobs: z.array(
    z.object({
      id: nonNegativeInteger.min(1),
      name: z.string().min(1),
      status: z.string().min(1),
      conclusion: z.string().nullable().optional(),
      htmlUrl: z.string().nullable().optional(),
    }),
  ),
});

export const schemas = [
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
    id: 'lvcompare-capture',
    fileName: 'lvcompare-capture.schema.json',
    description: 'Result capture emitted by the LVCompare driver.',
    schema: lvCompareCaptureSchema,
  },
  {
    id: 'child-procs-snapshot',
    fileName: 'child-procs-snapshot.schema.json',
    description: 'Snapshot of target processes and memory usage.',
    schema: childProcSnapshotSchema,
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
    id: 'dispatcher-results-guard',
    fileName: 'dispatcher-results-guard.schema.json',
    description: 'Guard crumb emitted when Invoke-PesterTests detects an invalid results directory.',
    schema: dispatcherResultsGuardSchema,
  },
  {
    id: 'teststand-compare-session',
    fileName: 'teststand-compare-session.schema.json',
    description: 'Session index emitted by tools/TestStand-CompareHarness.ps1.',
    schema: testStandCompareSessionSchema,
  },
  {
    id: 'cli-version',
    fileName: 'cli-version.schema.json',
    description: 'Output emitted by comparevi-cli version.',
    schema: cliVersionSchema,
  },
  {
    id: 'cli-tokenize',
    fileName: 'cli-tokenize.schema.json',
    description: 'Output emitted by comparevi-cli tokenize.',
    schema: cliTokenizeSchema,
  },
  {
    id: 'cli-quote',
    fileName: 'cli-quote.schema.json',
    description: 'Output emitted by comparevi-cli quote.',
    schema: cliQuoteSchema,
  },
  {
    id: 'cli-procs',
    fileName: 'cli-procs.schema.json',
    description: 'Output emitted by comparevi-cli procs.',
    schema: cliProcsSchema,
  },
  {
    id: 'cli-operations',
    fileName: 'cli-operations.schema.json',
    description: 'Operations catalog exposed by comparevi-cli operations.',
    schema: cliOperationsSchema,
  },
  {
    id: 'cli-operation-names',
    fileName: 'cli-operation-names.schema.json',
    description: 'Sorted operation names exposed by comparevi-cli operations --names-only.',
    schema: cliOperationNamesSchema,
  },
  {
    id: 'cli-providers',
    fileName: 'cli-providers.schema.json',
    description: 'Providers catalog exposed by comparevi-cli providers.',
    schema: cliProvidersSchema,
  },
  {
    id: 'cli-provider',
    fileName: 'cli-provider.schema.json',
    description: 'Single provider payload emitted by comparevi-cli providers --name <provider>.',
    schema: cliProviderSchema,
  },
  {
    id: 'cli-provider-names',
    fileName: 'cli-provider-names.schema.json',
    description: 'Sorted provider identifiers exposed by comparevi-cli providers --names-only.',
    schema: cliProviderNamesSchema,
  },
  {
    id: 'cli-artifact-meta',
    fileName: 'cli-artifact-meta.schema.json',
    description: 'Metadata describing published comparevi-cli artifacts.',
    schema: cliArtifactMetaSchema,
  },
  {
    id: 'watcher-rest',
    fileName: 'watcher-rest.schema.json',
    description: 'Summary produced by the REST watcher for GitHub Actions runs.',
    schema: watcherRestSchema,
  },
  {
    id: 'pester-invoker-event',
    fileName: 'pester-invoker-event.schema.json',
    description: 'Event crumb written by the TypeScript/PowerShell invoker loop.',
    schema: invokerEventSchema,
  },
  {
    id: 'pester-invoker-current-run',
    fileName: 'pester-invoker-current-run.schema.json',
    description: 'Metadata describing the active RunnerInvoker execution context.',
    schema: invokerCurrentRunSchema,
  },
];
