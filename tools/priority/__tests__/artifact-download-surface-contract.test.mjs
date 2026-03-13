import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('maintained operator surfaces use the checked-in artifact download helper instead of raw gh run download', () => {
  const oneButton = fs.readFileSync(path.join(repoRoot, 'tools', 'OneButton-CI.ps1'), 'utf8');
  const validationProof = fs.readFileSync(path.join(repoRoot, 'tools', 'priority', 'validation-approval-proof.mjs'), 'utf8');

  assert.doesNotMatch(oneButton, /\bgh run download\b/i);
  assert.match(oneButton, /priority:artifact:download/);

  assert.doesNotMatch(validationProof, /\bgh run download\b/i);
  assert.match(validationProof, /priority:artifact:download/);
});
