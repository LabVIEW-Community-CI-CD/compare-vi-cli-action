import '../../tools/bootstrap/node-deprecations.js';

import { randomUUID } from 'node:crypto';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

type Strategy = 'matrix' | 'single';

export interface DerivedEnv {
  includeIntegration: boolean;
  strategy: Strategy;
  sampleId: string;
  wireProbes: boolean;
  docsOnly: boolean;
  runner: {
    os: string | null;
    arch: string | null;
    environment: string | null;
  };
  gh: {
    runId: string | null;
    runAttempt: string | null;
    workflow: string | null;
    repository: string | null;
    eventName: string | null;
    ref: string | null;
    refName: string | null;
  };
  raw: Record<string, string | undefined>;
}

export interface DeriveOptions {
  defaults?: Partial<Pick<DerivedEnv, 'includeIntegration' | 'strategy' | 'sampleId' | 'wireProbes' | 'docsOnly'>>;
}

const TRUE_PATTERN = /^(1|true|yes|on)$/i;

function coalesce(...values: Array<string | undefined | null>): string | undefined {
  for (const value of values) {
    if (value && value.trim().length > 0) {
      return value.trim();
    }
  }
  return undefined;
}

function toBoolean(value: string | undefined, fallback: boolean): boolean {
  if (typeof value !== 'string') {
    return fallback;
  }
  return TRUE_PATTERN.test(value.trim());
}

function normalizeStrategy(value: string | undefined, fallback: Strategy): Strategy {
  if (!value) {
    return fallback;
  }
  const lowered = value.trim().toLowerCase();
  if (lowered === 'matrix') {
    return 'matrix';
  }
  if (lowered === 'single') {
    return 'single';
  }
  return fallback;
}

function ensureSampleId(value: string | undefined, defaults: DeriveOptions['defaults']): string {
  const fromEnv = value && value.trim();
  if (fromEnv) {
    return fromEnv;
  }
  if (defaults?.sampleId) {
    return defaults.sampleId;
  }
  const runId = process.env.GITHUB_RUN_ID;
  if (runId && runId.trim()) {
    return `run-${runId.trim()}`;
  }
  const timestamp = new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0, 14);
  return `ts-${timestamp}-${randomUUID().slice(0, 4)}`;
}

export function derive(options?: DeriveOptions): DerivedEnv {
  const defaults = options?.defaults ?? {};
  const includeIntegrationEnv = coalesce(
    process.env.INCLUDE_INTEGRATION,
    process.env.INPUT_INCLUDE_INTEGRATION,
    process.env.GITHUB_INPUT_INCLUDE_INTEGRATION,
    process.env.EV_INCLUDE_INTEGRATION
  );
  const strategyEnv = coalesce(
    process.env.STRATEGY,
    process.env.INPUT_STRATEGY,
    process.env.GITHUB_INPUT_STRATEGY,
    process.env.EV_STRATEGY
  );
  const sampleEnv = coalesce(
    process.env.SAMPLE_ID,
    process.env.INPUT_SAMPLE_ID,
    process.env.GITHUB_INPUT_SAMPLE_ID,
    process.env.EV_SAMPLE_ID
  );
  const wireProbesEnv = coalesce(
    process.env.WIRE_PROBES,
    process.env.INPUT_WIRE_PROBES,
    process.env.GITHUB_INPUT_WIRE_PROBES
  );
  const docsOnlyEnv = coalesce(
    process.env.DOCS_ONLY,
    process.env.INPUT_DOCS_ONLY,
    process.env.GITHUB_INPUT_DOCS_ONLY
  );

  const includeIntegration = toBoolean(includeIntegrationEnv, defaults.includeIntegration ?? true);
  const strategy = normalizeStrategy(strategyEnv, defaults.strategy ?? 'single');
  const sampleId = ensureSampleId(sampleEnv, defaults);
  const wireProbes = toBoolean(wireProbesEnv, defaults.wireProbes ?? true);
  const docsOnly = toBoolean(docsOnlyEnv, defaults.docsOnly ?? false);

  const derived: DerivedEnv = {
    includeIntegration,
    strategy,
    sampleId,
    wireProbes,
    docsOnly,
    runner: {
      os: process.env.RUNNER_OS ?? null,
      arch: process.env.RUNNER_ARCH ?? null,
      environment: process.env.RUNNER_ENVIRONMENT ?? null,
    },
    gh: {
      runId: process.env.GITHUB_RUN_ID ?? null,
      runAttempt: process.env.GITHUB_RUN_ATTEMPT ?? null,
      workflow: process.env.GITHUB_WORKFLOW ?? null,
      repository: process.env.GITHUB_REPOSITORY ?? null,
      eventName: process.env.GITHUB_EVENT_NAME ?? null,
      ref: process.env.GITHUB_REF ?? null,
      refName: process.env.GITHUB_REF_NAME ?? null,
    },
    raw: {
      INCLUDE_INTEGRATION: includeIntegrationEnv,
      STRATEGY: strategyEnv,
      SAMPLE_ID: sampleEnv,
      WIRE_PROBES: wireProbesEnv,
      DOCS_ONLY: docsOnlyEnv,
    },
  };

  return derived;
}

function runCli() {
  const args = new Set(process.argv.slice(2));
  const derived = derive();

  if (args.has('--json')) {
    const pretty = args.has('--pretty') ? 2 : undefined;
    process.stdout.write(`${JSON.stringify(derived, null, pretty)}\n`);
    return;
  }

  // Human-readable output
  const lines = [
    `includeIntegration: ${derived.includeIntegration}`,
    `strategy          : ${derived.strategy}`,
    `sampleId          : ${derived.sampleId}`,
    `wireProbes        : ${derived.wireProbes}`,
    `docsOnly          : ${derived.docsOnly}`,
    `runner.os         : ${derived.runner.os ?? 'n/a'}`,
    `gh.workflow       : ${derived.gh.workflow ?? 'n/a'}`,
    `gh.repository     : ${derived.gh.repository ?? 'n/a'}`,
    `gh.runId          : ${derived.gh.runId ?? 'n/a'}`,
  ];
  process.stdout.write(`${lines.join('\n')}\n`);
}

const invokedPath = (() => {
  try {
    return pathToFileURL(process.argv[1] ?? '').href;
  } catch {
    return undefined;
  }
})();

if (invokedPath && import.meta.url === invokedPath) {
  runCli();
}

export default derive;
