#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('release conductor workflow keeps workflow_run proposal-only when apply mode is disabled', async () => {
  const workflowPath = path.join(repoRoot, '.github', 'workflows', 'release-conductor.yml');
  const workflow = await readFile(workflowPath, 'utf8');

  assert.match(workflow, /RELEASE_CONDUCTOR_ENABLED:\s+\$\{\{\s*vars\.RELEASE_CONDUCTOR_ENABLED \|\| '0'\s*\}\}/);
  assert.match(
    workflow,
    /elseif \(\$eventName -eq 'workflow_run'\) \{\s+\$apply = \$conductorEnabled\s+if \(-not \$apply\) \{\s+Write-Host 'Release conductor apply mode disabled; workflow_run will remain proposal-only\.'\s+\}\s+\}/ms
  );
});
