import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');

function loadJson(relativePath) {
  const fullPath = path.join(repoRoot, relativePath);
  return JSON.parse(fs.readFileSync(fullPath, 'utf8'));
}

function formatError(e) {
  const pathPart = e.instancePath && e.instancePath.length > 0 ? e.instancePath : '(root)';
  return pathPart + ' ' + e.message;
}

function validateFixture(name, schemaRelative, fixtureRelative) {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const schema = loadJson(schemaRelative);
  const validate = ajv.compile(schema);
  const data = loadJson(fixtureRelative);
  const valid = validate(data);
  if (!valid) {
    const errors = (validate.errors || []).map(formatError).join('\n');
    throw new Error('Schema validation failed for ' + fixtureRelative + ' (' + name + '):\n' + errors);
  }
}

test('handoff issue summary matches schema', () => {
  validateFixture('issue summary', 'docs/schemas/standing-priority-issue-v1.schema.json', 'tools/priority/__fixtures__/handoff/issue-summary.json');
});

test('handoff router matches schema', () => {
  validateFixture('router', 'docs/schemas/handoff-router-v1.schema.json', 'tools/priority/__fixtures__/handoff/router.json');
});

test('handoff hook summary matches schema', () => {
  validateFixture('hook summary', 'docs/schemas/handoff-hook-summary-v1.schema.json', 'tools/priority/__fixtures__/handoff/hook-summary.json');
});

test('handoff release summary matches schema', () => {
  validateFixture('release summary', 'docs/schemas/handoff-release-v1.schema.json', 'tools/priority/__fixtures__/handoff/release-summary.json');
});

test('handoff test summary matches schema', () => {
  validateFixture('test summary', 'docs/schemas/handoff-test-results-v1.schema.json', 'tools/priority/__fixtures__/handoff/test-summary.json');
});

test('handoff session capsule matches schema', () => {
  validateFixture('session capsule', 'docs/schemas/handoff-session-v1.schema.json', 'tools/priority/__fixtures__/handoff/session-capsule.json');
});
