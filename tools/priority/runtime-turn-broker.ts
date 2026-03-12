#!/usr/bin/env node
// @ts-nocheck

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const sourceModulePath = path.resolve(path.dirname(modulePath), '../../../tools/priority/runtime-turn-broker.mjs');
const sourceModule = await import(pathToFileURL(sourceModulePath).href);

export const parseArgs = sourceModule.parseArgs;
export const main = (...args) => sourceModule.main(...args);

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await main(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(`${error?.message || String(error)}\n`);
    process.exit(1);
  }
}
