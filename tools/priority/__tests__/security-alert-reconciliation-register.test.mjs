import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('security alert reconciliation register is checked in and anchored to the live intake receipt', () => {
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  const register = readText('docs/knowledgebase/Security-Alert-Reconciliation-Register.md');
  const report = JSON.parse(readText('tests/results/_agent/security/security-intake-report.json'));

  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Security-Alert-Reconciliation-Register.md'));
  assert.match(register, /security-intake-report\.json/);
  assert.match(register, /platform-stale/);
  assert.match(register, /#1426/);
  assert.match(register, /security-intake\.mjs/);
  assert.match(register, /security-intake\.test\.mjs/);
  assert.match(register, /security-intake-schema\.test\.mjs/);
  assert.equal(report.status, 'platform-stale');
  assert.equal(report.verification.platformStale, true);
  assert.deepEqual(report.verification.verifiedAlertNumbers, [3, 4]);
});
