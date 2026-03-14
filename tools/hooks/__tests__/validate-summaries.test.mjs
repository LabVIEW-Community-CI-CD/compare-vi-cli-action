import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isHookSummaryFileName } from '../core/validate-summaries.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('isHookSummaryFileName keeps hook summary artifacts and ignores provider receipts', () => {
  assert.equal(isHookSummaryFileName('pre-commit.json'), true);
  assert.equal(isHookSummaryFileName('pre-commit.shell.json'), true);
  assert.equal(isHookSummaryFileName('pre-push.pwsh.json'), true);

  assert.equal(isHookSummaryFileName('pre-commit-agent-review-policy.json'), false);
  assert.equal(isHookSummaryFileName('pre-commit-copilot-cli-review.json'), false);
  assert.equal(isHookSummaryFileName('pre-push-codex-cli-review.json'), false);
});

test('hook summary schema allows raw hook step state mirrors', () => {
  const schema = JSON.parse(
    readFileSync(path.join(repoRoot, 'docs', 'schemas', 'hooks-summary-v1.schema.json'), 'utf8')
  );
  const stepProperties = schema.properties.steps.items.properties;

  assert.deepEqual(stepProperties.rawStatus.enum, ['ok', 'warn', 'failed', 'skipped']);
  assert.equal(stepProperties.rawExitCode.type, 'integer');
});
