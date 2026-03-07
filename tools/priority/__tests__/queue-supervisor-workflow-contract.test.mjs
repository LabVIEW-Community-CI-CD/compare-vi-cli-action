#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('queue supervisor workflow wires remediation governor before enqueue apply', async () => {
  const workflowPath = path.join(repoRoot, '.github', 'workflows', 'queue-supervisor.yml');
  const workflow = await readFile(workflowPath, 'utf8');

  assert.match(workflow, /Evaluate remediation SLO governor state/);
  assert.match(workflow, /priority:remediation:slo/);
  assert.match(workflow, /--governor-state/);
  assert.match(workflow, /QUEUE_GOVERNOR_STATE_PATH/);
  assert.match(workflow, /priority:queue:supervisor/);
});
