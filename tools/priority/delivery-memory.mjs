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
export * from '../../dist/tools/priority/delivery-memory.js';

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath && typeof imported.main === 'function') {
  try {
    const exitCode = await imported.main(process.argv);
    if (Number.isInteger(exitCode)) {
      process.exit(exitCode);
    }
  } catch (error) {
    process.stderr.write(`${error?.stack || error?.message || String(error)}\n`);
    process.exit(1);
  }
}
