import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('package.json exposes queue:update as a first-class alias to queue-refresh-pr', async () => {
  const packageJson = JSON.parse(await readFile(path.join(repoRoot, 'package.json'), 'utf8'));
  assert.equal(packageJson.scripts['priority:queue:refresh'], 'node tools/priority/queue-refresh-pr.mjs');
  assert.equal(packageJson.scripts['priority:queue:update'], 'node tools/priority/queue-refresh-pr.mjs');
});

