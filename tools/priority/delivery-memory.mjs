#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(path.dirname(modulePath), '..', '..');
const distPath = path.resolve(path.dirname(modulePath), '../../dist/tools/priority/delivery-memory.js');
if (!existsSync(distPath)) {
  const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if ((buildResult.status ?? 1) !== 0) {
    throw new Error([buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
  }
}

const imported = await import(pathToFileURL(distPath).href);
export const DELIVERY_MEMORY_REPORT_SCHEMA = imported.DELIVERY_MEMORY_REPORT_SCHEMA;
export const DEFAULT_RUNTIME_DIR = imported.DEFAULT_RUNTIME_DIR;
export const DEFAULT_REPORT_FILENAME = imported.DEFAULT_REPORT_FILENAME;
export const buildDeliveryMemoryReport = imported.buildDeliveryMemoryReport;
export const refreshDeliveryMemory = imported.refreshDeliveryMemory;
export const parseArgs = imported.parseArgs;
export const main = imported.main;

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath && typeof main === 'function') {
  try {
    const exitCode = await main(process.argv);
    if (Number.isInteger(exitCode)) {
      process.exit(exitCode);
    }
  } catch (error) {
    process.stderr.write(`${error?.stack || error?.message || String(error)}\n`);
    process.exit(1);
  }
}
