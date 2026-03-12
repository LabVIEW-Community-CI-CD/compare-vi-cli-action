#!/usr/bin/env node
// @ts-nocheck

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const sourceModulePath = path.resolve(path.dirname(modulePath), '../../../tools/priority/runtime-supervisor.mjs');
const sourceModule = await import(pathToFileURL(sourceModulePath).href);

export const ACTIONS = sourceModule.ACTIONS;
export const BLOCKER_CLASSES = sourceModule.BLOCKER_CLASSES;
export const BLOCKER_SCHEMA = sourceModule.BLOCKER_SCHEMA;
export const DEFAULT_LEASE_SCOPE = sourceModule.DEFAULT_LEASE_SCOPE;
export const DEFAULT_RUNTIME_DIR = sourceModule.DEFAULT_RUNTIME_DIR;
export const EVENT_SCHEMA = sourceModule.EVENT_SCHEMA;
export const LANE_SCHEMA = sourceModule.LANE_SCHEMA;
export const REPORT_SCHEMA = sourceModule.REPORT_SCHEMA;
export const STATE_SCHEMA = sourceModule.STATE_SCHEMA;
export const STOP_REQUEST_SCHEMA = sourceModule.STOP_REQUEST_SCHEMA;
export const TASK_PACKET_SCHEMA = sourceModule.TASK_PACKET_SCHEMA;
export const TURN_SCHEMA = sourceModule.TURN_SCHEMA;
export const WORKER_CHECKOUT_SCHEMA = sourceModule.WORKER_CHECKOUT_SCHEMA;
export const WORKER_READY_SCHEMA = sourceModule.WORKER_READY_SCHEMA;
export const EXECUTION_RECEIPT_SCHEMA = sourceModule.EXECUTION_RECEIPT_SCHEMA;
export const __test = sourceModule.__test;
export const createRuntimeAdapter = sourceModule.createRuntimeAdapter;
export const parseArgs = sourceModule.parseArgs;
export const compareviRuntimeAdapter = sourceModule.compareviRuntimeAdapter;
export const compareviRuntimeTest = sourceModule.compareviRuntimeTest;
export const runRuntimeSupervisor = (...args) => sourceModule.runRuntimeSupervisor(...args);
export const runCli = (...args) => sourceModule.runCli(...args);

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await runCli(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({ schema: REPORT_SCHEMA, status: 'error', outcome: 'error', message: error?.message || String(error) }, null, 2)}\n`,
    );
    process.exit(1);
  }
}
