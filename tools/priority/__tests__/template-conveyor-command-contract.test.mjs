import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'));
}

test('package scripts expose the pinned template conveyor entrypoints', () => {
  const packageJson = readJson('package.json');
  assert.equal(
    packageJson.scripts['priority:template:render:container'],
    'node tools/priority/template-cookiecutter-container.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:template:verify'],
    'node tools/priority/template-agent-verification-report.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:template:verify:sync'],
    'node tools/priority/sync-template-agent-verification-report.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:pivot:template'],
    'node tools/priority/template-pivot-gate.mjs'
  );
});
