import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

test('repo root markdown surface stays minimal while keeping the canonical autonomy prompt at root', () => {
  const rootMarkdown = readdirSync(repoRoot)
    .filter((entry) => entry.endsWith('.md'))
    .sort();

  assert.deepEqual(rootMarkdown, [
    'AGENTS.md',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'PROMPT_AUTONOMY.md',
    'README.md',
    'SECURITY.md',
  ]);
});

test('historical markdown lives under docs/release and docs/archive', () => {
  const requiredPaths = [
    'docs/release/PR_NOTES.md',
    'docs/release/TAG_PREP_CHECKLIST.md',
    'docs/release/POST_RELEASE_FOLLOWUPS.md',
    'docs/release/ROLLBACK_PLAN.md',
    'docs/archive/project-history/CI-FIX-SUMMARY.md',
    'docs/archive/project-history/IMPLEMENTATION_STATUS.md',
    'docs/archive/releases/RELEASE_NOTES_v0.6.3.md',
  ];

  for (const relPath of requiredPaths) {
    assert.equal(existsSync(path.join(repoRoot, relPath)), true, `${relPath} should exist`);
  }
});
