import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { __test } from '../commit-integrity.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function makeCommit({
  sha,
  verified = true,
  reason = 'valid',
  sourceKind = 'human'
}) {
  return {
    sha,
    url: `https://github.com/example/repo/commit/${sha}`,
    messageHeadline: `commit-${sha}`,
    trailers: [{ key: 'Issue', value: '#770' }],
    verified,
    verificationReason: reason,
    verificationSignaturePresent: verified,
    verificationPayloadPresent: verified,
    authorLogin: sourceKind === 'bot' ? 'dependabot[bot]' : 'alice',
    committerLogin: sourceKind === 'bot' ? 'dependabot[bot]' : 'alice',
    authorEmail:
      sourceKind === 'bot' ? '49699333+dependabot[bot]@users.noreply.github.com' : 'alice@example.com',
    committerEmail:
      sourceKind === 'bot' ? '49699333+dependabot[bot]@users.noreply.github.com' : 'alice@example.com',
    sourceKind
  };
}

test('commit integrity report schema validates generated report payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'commit-integrity-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const commits = [makeCommit({ sha: 'aa', verified: true }), makeCommit({ sha: 'bb', verified: false, reason: 'unsigned' })];
  const evaluation = __test.evaluateCommitIntegrity(commits, {
    checks: {
      requireAuthorAttribution: true,
      requireCommitterAttribution: true,
      requireKnownReasonForUnverified: true
    }
  });

  const report = __test.buildReport({
    repository: 'example/repo',
    scope: {
      mode: 'pull_request',
      pullRequest: 123,
      baseSha: null,
      headSha: null
    },
    policy: {
      schema: 'commit-integrity-policy/v1',
      path: path.join(repoRoot, 'tools', 'policy', 'commit-integrity-policy.json'),
      failOnUnverified: true,
      checks: {
        requireAuthorAttribution: true,
        requireCommitterAttribution: true,
        requireKnownReasonForUnverified: true,
        requireUniqueShas: true,
        requireNonEmptyHeadline: true,
        maxHeadlineLength: 120,
        requireSignatureMaterialForVerified: false,
        requireRequiredTrailer: true,
        requiredTrailerRules: [
          { key: 'Issue', keyLower: 'issue', valuePattern: '^#\\d+$', valueRegex: /^#\d+$/ },
          { key: 'Refs', keyLower: 'refs', valuePattern: '^#\\d+$', valueRegex: /^#\d+$/ }
        ]
      },
      sourceResolution: {
        botLoginRegexes: [/\[bot\]$/i],
        botEmailRegexes: [/\[bot\]@users\.noreply\.github\.com$/i]
      },
      trailerContract: {
        requiredAny: [
          { key: 'Issue', valuePattern: '^#\\d+$' },
          { key: 'Refs', valuePattern: '^#\\d+$' }
        ]
      }
    },
    observeOnly: false,
    commits,
    evaluation,
    generatedAt: '2026-03-06T00:00:00.000Z'
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
