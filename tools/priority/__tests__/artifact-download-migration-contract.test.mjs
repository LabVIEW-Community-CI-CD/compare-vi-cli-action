import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('OneButton-CI uses the checked-in artifact download helper instead of raw gh run download', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'OneButton-CI.ps1');
  const raw = fs.readFileSync(scriptPath, 'utf8');

  assert.doesNotMatch(raw, /\bgh\s+run\s+download\b/i);
  assert.match(raw, /priority:artifact:download/);
  assert.match(raw, /--all/);
});
