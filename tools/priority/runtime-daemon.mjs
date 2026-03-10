#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_POLL_INTERVAL_SECONDS,
  OBSERVER_HEARTBEAT_SCHEMA,
  OBSERVER_REPORT_SCHEMA,
  parseObserverArgs,
  runObserverCli as runCoreObserverCli,
  runRuntimeObserverLoop as runCoreRuntimeObserverLoop
} from '../../packages/runtime-harness/observer.mjs';
import { compareviRuntimeAdapter } from './runtime-supervisor.mjs';

export {
  DEFAULT_POLL_INTERVAL_SECONDS,
  OBSERVER_HEARTBEAT_SCHEMA,
  OBSERVER_REPORT_SCHEMA,
  parseObserverArgs
};

export async function runRuntimeObserverLoop(options = {}, deps = {}) {
  return runCoreRuntimeObserverLoop(options, {
    ...deps,
    adapter: deps.adapter ?? compareviRuntimeAdapter
  });
}

export async function runCli(argv = process.argv, deps = {}) {
  return runCoreObserverCli(argv, {
    ...deps,
    adapter: deps.adapter ?? compareviRuntimeAdapter
  });
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify(
        {
          schema: OBSERVER_REPORT_SCHEMA,
          status: 'error',
          outcome: 'error',
          message: error?.message || String(error)
        },
        null,
        2
      )}\n`
    );
    process.exit(1);
  }
}
