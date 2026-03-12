#!/usr/bin/env node
// @ts-nocheck

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const sourceModulePath = path.resolve(path.dirname(modulePath), '../../../tools/priority/runtime-daemon.mjs');
const sourceModule = await import(pathToFileURL(sourceModulePath).href);

export const DEFAULT_POLL_INTERVAL_SECONDS = sourceModule.DEFAULT_POLL_INTERVAL_SECONDS;
export const OBSERVER_HEARTBEAT_SCHEMA = sourceModule.OBSERVER_HEARTBEAT_SCHEMA;
export const OBSERVER_REPORT_SCHEMA = sourceModule.OBSERVER_REPORT_SCHEMA;
export const parseObserverArgs = sourceModule.parseObserverArgs;
export const runRuntimeObserverLoop = (...args) => sourceModule.runRuntimeObserverLoop(...args);
export const runCli = (...args) => sourceModule.runCli(...args);

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({ schema: OBSERVER_REPORT_SCHEMA, status: 'error', outcome: 'error', message: error?.message || String(error) }, null, 2)}\n`,
    );
    process.exit(1);
  }
}
