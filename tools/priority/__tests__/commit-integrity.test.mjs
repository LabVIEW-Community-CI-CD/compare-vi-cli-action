import test from 'node:test';
import assert from 'node:assert/strict';
import { __test, evaluateCommitIntegrity, normalizeCommitRecords, parseArgs } from '../commit-integrity.mjs';

function createRawCommit({
  sha,
  verified = true,
  reason = 'valid',
  authorLogin = 'octocat',
  committerLogin = 'octocat',
  authorEmail = 'octocat@example.com',
  committerEmail = 'octocat@example.com',
  message = 'test commit'
}) {
  return {
    sha,
    html_url: `https://github.com/example/repo/commit/${sha}`,
    author: authorLogin ? { login: authorLogin } : null,
    committer: committerLogin ? { login: committerLogin } : null,
    commit: {
      message,
      author: authorEmail ? { email: authorEmail } : null,
      committer: committerEmail ? { email: committerEmail } : null,
      verification: {
        verified,
        reason,
        signature: verified ? 'sig' : null,
        payload: verified ? 'payload' : null
      }
    }
  };
}

const sourceResolution = {
  botLoginRegexes: [/\[bot\]$/i],
  botEmailRegexes: [/\[bot\]@users\.noreply\.github\.com$/i]
};
const requiredTrailerRules = [
  { key: 'Issue', valuePattern: '^#\\d+$' },
  { key: 'Refs', valuePattern: '^#\\d+$' }
];

test('parseArgs supports observe-only and pull-request selection', () => {
  const options = parseArgs([
    'node',
    'tools/priority/commit-integrity.mjs',
    '--pr',
    '42',
    '--observe-only'
  ]);
  assert.equal(options.pr, 42);
  assert.equal(options.observeOnly, true);
});

test('normalizeCommitRecords applies deterministic sha ordering', () => {
  const commits = normalizeCommitRecords(
    [
      createRawCommit({ sha: 'bb', message: 'second' }),
      createRawCommit({ sha: 'aa', message: 'first' })
    ],
    sourceResolution
  );
  assert.deepEqual(
    commits.map((entry) => entry.sha),
    ['aa', 'bb']
  );
});

test('classifySourceKind honors policy-driven bot patterns', () => {
  const human = __test.normalizeCommitRecord(
    createRawCommit({ sha: 'aa01', authorLogin: 'alice', authorEmail: 'alice@example.com' }),
    sourceResolution
  );
  const bot = __test.normalizeCommitRecord(
    createRawCommit({
      sha: 'aa02',
      authorLogin: 'dependabot[bot]',
      authorEmail: '49699333+dependabot[bot]@users.noreply.github.com'
    }),
    sourceResolution
  );
  assert.equal(human.sourceKind, 'human');
  assert.equal(bot.sourceKind, 'bot');
});

test('evaluateCommitIntegrity fails on unverified commits with explicit categories', () => {
  const commits = normalizeCommitRecords(
    [createRawCommit({ sha: 'cc', verified: false, reason: 'unsigned' })],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits);
  assert.equal(evaluation.result, 'fail');
  assert.ok(
    evaluation.violations.some((violation) => violation.category === 'unverified-commit' && violation.reason === 'unsigned')
  );
});

test('evaluateCommitIntegrity detects attribution and unknown-reason gaps when enabled', () => {
  const commits = normalizeCommitRecords(
    [
      createRawCommit({
        sha: 'dd',
        verified: false,
        reason: 'unknown',
        authorLogin: null,
        committerLogin: null,
        authorEmail: null,
        committerEmail: null
      })
    ],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireAuthorAttribution: true,
      requireCommitterAttribution: true,
      requireKnownReasonForUnverified: true
    }
  });
  assert.ok(evaluation.violations.some((violation) => violation.category === 'unknown-unverified-reason'));
  assert.ok(evaluation.violations.some((violation) => violation.category === 'missing-author-attribution'));
  assert.ok(evaluation.violations.some((violation) => violation.category === 'missing-committer-attribution'));
});

test('evaluateCommitIntegrity detects duplicate SHAs and headline quality issues', () => {
  const commits = [
    {
      sha: 'ee',
      url: 'https://github.com/example/repo/commit/ee',
      messageHeadline: '',
      verified: true,
      verificationReason: 'valid',
      verificationSignaturePresent: true,
      verificationPayloadPresent: true,
      authorLogin: 'alice',
      committerLogin: 'alice',
      authorEmail: 'alice@example.com',
      committerEmail: 'alice@example.com',
      sourceKind: 'human'
    },
    {
      sha: 'ee',
      url: 'https://github.com/example/repo/commit/ee',
      messageHeadline: 'x'.repeat(130),
      verified: true,
      verificationReason: 'valid',
      verificationSignaturePresent: true,
      verificationPayloadPresent: true,
      authorLogin: 'alice',
      committerLogin: 'alice',
      authorEmail: 'alice@example.com',
      committerEmail: 'alice@example.com',
      sourceKind: 'human'
    }
  ];

  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireUniqueShas: true,
      requireNonEmptyHeadline: true,
      maxHeadlineLength: 120
    }
  });

  assert.ok(evaluation.violations.some((violation) => violation.category === 'duplicate-commit-sha'));
  assert.ok(evaluation.violations.some((violation) => violation.category === 'empty-headline'));
  assert.ok(evaluation.violations.some((violation) => violation.category === 'headline-too-long'));
});

test('evaluateCommitIntegrity checks signature material for verified commits when enabled', () => {
  const commits = [
    {
      sha: 'ff',
      url: 'https://github.com/example/repo/commit/ff',
      messageHeadline: 'verified commit',
      verified: true,
      verificationReason: 'valid',
      verificationSignaturePresent: false,
      verificationPayloadPresent: false,
      authorLogin: 'alice',
      committerLogin: 'alice',
      authorEmail: 'alice@example.com',
      committerEmail: 'alice@example.com',
      sourceKind: 'human'
    }
  ];

  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireSignatureMaterialForVerified: true
    }
  });
  assert.ok(evaluation.violations.some((violation) => violation.category === 'missing-signature-material'));
});

test('resolveScope supports pull_request and merge_group payloads', () => {
  const pullRequestScope = __test.resolveScope(
    { pr: null, baseSha: null, headSha: null },
    { GITHUB_EVENT_NAME: 'pull_request' },
    { pull_request: { number: 77 } }
  );
  assert.equal(pullRequestScope.mode, 'pull_request');
  assert.equal(pullRequestScope.pullRequest, 77);

  const mergeGroupScope = __test.resolveScope(
    { pr: null, baseSha: null, headSha: null },
    { GITHUB_EVENT_NAME: 'merge_group' },
    { merge_group: { base_sha: 'abc123', head_sha: 'def456' } }
  );
  assert.equal(mergeGroupScope.mode, 'compare');
  assert.equal(mergeGroupScope.baseSha, 'abc123');
  assert.equal(mergeGroupScope.headSha, 'def456');
});

test('evaluateCommitIntegrity enforces required trailer contract (missing trailer fails)', () => {
  const commits = normalizeCommitRecords(
    [createRawCommit({ sha: 'aa03', message: 'feat: add deterministic flow' })],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });
  assert.equal(evaluation.result, 'fail');
  assert.ok(evaluation.violations.some((violation) => violation.category === 'missing-required-trailer'));
});

test('evaluateCommitIntegrity passes required trailer contract when Issue trailer matches policy', () => {
  const commits = normalizeCommitRecords(
    [createRawCommit({ sha: 'aa04', message: 'feat: add deterministic flow\n\nIssue: #770' })],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });
  assert.equal(evaluation.result, 'pass');
  assert.ok(!evaluation.violations.some((violation) => violation.category === 'missing-required-trailer'));
});

test('evaluateCommitIntegrity fails required trailer contract when trailer value is malformed', () => {
  const commits = normalizeCommitRecords(
    [createRawCommit({ sha: 'aa05', message: 'feat: add deterministic flow\n\nIssue: 770' })],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });
  assert.equal(evaluation.result, 'fail');
  assert.ok(evaluation.violations.some((violation) => violation.category === 'invalid-required-trailer-format'));
});

test('evaluateCommitIntegrity reports empty-range issue deterministically', () => {
  const evaluation = evaluateCommitIntegrity([], {
    checks: {
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });
  assert.equal(evaluation.result, 'fail');
  assert.ok(evaluation.issues.includes('no-commits-found'));
});
