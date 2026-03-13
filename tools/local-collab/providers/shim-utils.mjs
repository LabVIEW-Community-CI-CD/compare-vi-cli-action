#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export function isEntrypoint(importMetaUrl, argv = process.argv) {
  const entrypointPath = argv[1] ? path.resolve(argv[1]) : null;
  const modulePath = fileURLToPath(importMetaUrl);
  return Boolean(entrypointPath && modulePath === entrypointPath);
}