const test = require('node:test');
const assert = require('node:assert/strict');
const {
  slugifyTitle,
  buildBranchName,
  versionBumpFromType,
} = require('./utils.js');

test('slugifyTitle sanitizes and truncates', () => {
  assert.equal(slugifyTitle('Add new feature!'), 'add-new-feature');
  assert.equal(
    slugifyTitle('This is a very long title that should be truncated after thirty characters'),
    'this-is-a-very-long-title-that'
  );
  assert.equal(slugifyTitle('???'), 'issue');
});

test('buildBranchName formats correctly', () => {
  assert.equal(buildBranchName(42, 'Fix bug'), 'issue-42-fix-bug');
});

test('versionBumpFromType maps labels', () => {
  assert.equal(versionBumpFromType('feature'), 'major');
  assert.equal(versionBumpFromType('bug'), 'minor');
  assert.equal(versionBumpFromType('task'), 'none');
  assert.equal(versionBumpFromType('other'), 'none');
});
