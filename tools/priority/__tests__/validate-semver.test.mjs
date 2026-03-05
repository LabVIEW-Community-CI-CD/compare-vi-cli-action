import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateVersionIntegrity, parseArgs } from '../validate-semver.mjs';

test('evaluateVersionIntegrity accepts valid semver without branch context', () => {
  const result = evaluateVersionIntegrity('1.2.3');
  assert.equal(result.valid, true);
  assert.deepEqual(result.issues, []);
});

test('evaluateVersionIntegrity rejects invalid semver version', () => {
  const result = evaluateVersionIntegrity('1.2');
  assert.equal(result.valid, false);
  assert.match(result.issues[0], /does not comply/i);
});

test('evaluateVersionIntegrity enforces release branch/version match', () => {
  const mismatch = evaluateVersionIntegrity('1.2.3', 'release/v1.2.4');
  assert.equal(mismatch.valid, false);
  assert.match(mismatch.issues.join(' '), /does not match release branch tag/i);

  const match = evaluateVersionIntegrity('1.2.3', 'release/v1.2.3');
  assert.equal(match.valid, true);
});

test('parseArgs resolves branch from cli flag or github env', () => {
  const cli = parseArgs(['--version', '1.2.3', '--branch', 'release/v1.2.3'], {});
  assert.equal(cli.versionArg, '1.2.3');
  assert.equal(cli.branch, 'release/v1.2.3');

  const env = parseArgs([], { GITHUB_HEAD_REF: 'release/v2.0.0' });
  assert.equal(env.branch, 'release/v2.0.0');
});
