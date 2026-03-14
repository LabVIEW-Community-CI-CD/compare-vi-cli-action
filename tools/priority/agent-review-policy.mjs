#!/usr/bin/env node

export * from '../local-collab/providers/agent-review-policy.mjs';

import { main } from '../local-collab/providers/agent-review-policy.mjs';
import { isEntrypoint } from '../local-collab/providers/shim-utils.mjs';

if (isEntrypoint(import.meta.url)) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}