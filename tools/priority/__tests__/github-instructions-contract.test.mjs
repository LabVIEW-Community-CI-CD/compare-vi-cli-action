import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const instructionsDir = path.join(repoRoot, '.github', 'instructions');
const agentsPath = path.join(repoRoot, 'AGENTS.md');

function readInstruction(name) {
  return fs.readFileSync(path.join(instructionsDir, name), 'utf8');
}

function normalizeWhitespace(value) {
  return value.replace(/\s+/g, ' ').trim();
}

test('draft-only GitHub instructions exist as a repo-owned surface', () => {
  assert.equal(fs.existsSync(instructionsDir), true, '.github/instructions must exist.');
  const instructionFiles = fs.readdirSync(instructionsDir)
    .filter((entry) => entry.endsWith('.instructions.md'))
    .sort();

  assert.deepEqual(instructionFiles, [
    'draft-only-copilot-review.instructions.md',
    'final-ready-validation.instructions.md',
  ]);
});

test('draft-only instruction content captures the required Copilot review contract', () => {
  const draftOnly = normalizeWhitespace(readInstruction('draft-only-copilot-review.instructions.md'));
  const readyValidation = normalizeWhitespace(readInstruction('final-ready-validation.instructions.md'));

  assert.match(draftOnly, /only while the pull request is draft/i);
  assert.match(draftOnly, /Do not use `ready_for_review` to solicit a second Copilot pass/i);
  assert.match(draftOnly, /Resolve current-head Copilot comments before leaving draft/i);

  assert.match(readyValidation, /Use `ready_for_review` only when the current head is locally reviewed/i);
  assert.match(readyValidation, /Do not request or wait for a second Copilot review after `ready_for_review`/i);
  assert.match(readyValidation, /return the pull request to draft and restart the local-plus-Copilot review loop/i);
});

test('AGENTS points future agents at the GitHub instructions surface', () => {
  const agents = fs.readFileSync(agentsPath, 'utf8');
  assert.match(agents, /\.github\/instructions\/\*\.instructions\.md/);
  assert.match(agents, /draft-only Copilot review contract/i);
});
