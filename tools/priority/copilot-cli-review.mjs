#!/usr/bin/env node

export * from '../local-collab/providers/copilot-cli-review.mjs';

import { main } from '../local-collab/providers/copilot-cli-review.mjs';
import { isEntrypoint } from '../local-collab/providers/shim-utils.mjs';

if (isEntrypoint(import.meta.url)) {
  const exitCode = await main(process.argv);
  process.exit(exitCode);
}
