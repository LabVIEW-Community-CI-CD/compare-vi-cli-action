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
const allowedBotLogins = ['dependabot[bot]', 'github-actions[bot]'];
const allowedBotEmailPatterns = [
  '^[0-9]+\\+dependabot\\[bot\\]@users\\.noreply\\.github\\.com$',
  '^41898282\\+github-actions\\[bot\\]@users\\.noreply\\.github\\.com$'
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

test('parseArgs captures bypass metadata options', () => {
  const options = parseArgs([
    'node',
    'tools/priority/commit-integrity.mjs',
    '--pr',
    '42',
    '--ledger',
    'tests/results/ledger.json',
    '--bypass-reason',
    'temporary-incident-mitigation',
    '--bypass-owner',
    '@octocat',
    '--bypass-expires-at',
    '2026-03-31T00:00:00Z',
    '--bypass-ticket',
    '#775',
    '--bypass-labels',
    'ci,governance'
  ]);
  assert.equal(options.ledgerPath, 'tests/results/ledger.json');
  assert.equal(options.bypassReason, 'temporary-incident-mitigation');
  assert.equal(options.bypassOwner, '@octocat');
  assert.equal(options.bypassExpiresAt, '2026-03-31T00:00:00Z');
  assert.equal(options.bypassTicket, '#775');
  assert.deepEqual(options.bypassLabels, ['ci', 'governance']);
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

test('evaluateCommitIntegrity covers verified, unsigned, unknown, and signature-unavailable reasons', () => {
  const commits = normalizeCommitRecords(
    [
      createRawCommit({ sha: 'sig1', verified: true, reason: 'valid', message: 'feat: verified\n\nIssue: #771' }),
      createRawCommit({ sha: 'sig2', verified: false, reason: 'unsigned', message: 'feat: unsigned\n\nIssue: #771' }),
      createRawCommit({ sha: 'sig3', verified: false, reason: 'unknown', message: 'feat: unknown\n\nIssue: #771' }),
      createRawCommit({
        sha: 'sig4',
        verified: false,
        reason: 'gpgverify_unavailable',
        message: 'feat: service unavailable\n\nIssue: #771'
      })
    ],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireKnownReasonForUnverified: true,
      requireSignatureVerificationAvailable: true
    }
  });

  assert.ok(!evaluation.violations.some((violation) => violation.sha === 'sig1' && violation.category === 'unverified-commit'));
  assert.ok(evaluation.violations.some((violation) => violation.sha === 'sig2' && violation.category === 'unverified-commit'));
  assert.ok(evaluation.violations.some((violation) => violation.sha === 'sig3' && violation.category === 'unknown-unverified-reason'));
  assert.ok(
    evaluation.violations.some(
      (violation) => violation.sha === 'sig4' && violation.category === 'signature-verification-unavailable'
    )
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

test('evaluateCommitIntegrity allows allowlisted bot identities', () => {
  const commits = normalizeCommitRecords(
    [
      createRawCommit({
        sha: 'bot01',
        authorLogin: 'dependabot[bot]',
        committerLogin: 'dependabot[bot]',
        authorEmail: '49699333+dependabot[bot]@users.noreply.github.com',
        committerEmail: '49699333+dependabot[bot]@users.noreply.github.com',
        message: 'chore: update deps\n\nIssue: #772'
      })
    ],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireBotAllowlist: true,
      allowedBotLogins,
      allowedBotEmailPatterns,
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });

  assert.equal(evaluation.result, 'pass');
  assert.ok(!evaluation.violations.some((violation) => violation.category === 'unauthorized-bot-identity'));
});

test('evaluateCommitIntegrity fails on non-allowlisted bot identities', () => {
  const commits = normalizeCommitRecords(
    [
      createRawCommit({
        sha: 'bot02',
        authorLogin: 'renovate[bot]',
        committerLogin: 'renovate[bot]',
        authorEmail: 'renovate[bot]@users.noreply.github.com',
        committerEmail: 'renovate[bot]@users.noreply.github.com',
        message: 'chore: update deps\n\nIssue: #772'
      })
    ],
    sourceResolution
  );
  const evaluation = evaluateCommitIntegrity(commits, {
    checks: {
      requireBotAllowlist: true,
      allowedBotLogins,
      allowedBotEmailPatterns,
      requireRequiredTrailer: true,
      requiredTrailerRules
    }
  });

  assert.equal(evaluation.result, 'fail');
  assert.ok(evaluation.violations.some((violation) => violation.category === 'unauthorized-bot-identity'));
});

test('resolveBypassRequest requires explicit metadata when bypass is requested', () => {
  const bypass = __test.resolveBypassRequest(
    {
      bypassReason: 'temporary bypass',
      bypassOwner: null,
      bypassExpiresAt: null,
      bypassTicket: null,
      bypassLabels: []
    },
    {},
    {
      exceptionGovernance: {
        allowBypass: true,
        remediationLabels: ['ci', 'governance', 'supply-chain']
      }
    },
    new Date('2026-03-06T00:00:00Z')
  );

  assert.equal(bypass.requested, true);
  assert.equal(bypass.status, 'invalid');
  assert.ok(bypass.metadataErrors.includes('missing-bypass-owner'));
  assert.ok(bypass.metadataErrors.includes('missing-bypass-expiry'));
});

test('resolveBypassRequest classifies active versus expired metadata deterministically', () => {
  const expired = __test.resolveBypassRequest(
    {
      bypassReason: 'incident',
      bypassOwner: '@octocat',
      bypassExpiresAt: '2026-03-01T00:00:00Z',
      bypassTicket: '#775',
      bypassLabels: []
    },
    {},
    {
      exceptionGovernance: {
        allowBypass: true,
        remediationLabels: ['ci', 'governance', 'supply-chain']
      }
    },
    new Date('2026-03-06T00:00:00Z')
  );
  assert.equal(expired.status, 'expired');
  assert.equal(expired.active, false);

  const active = __test.resolveBypassRequest(
    {
      bypassReason: 'incident',
      bypassOwner: '@octocat',
      bypassExpiresAt: '2026-03-20T00:00:00Z',
      bypassTicket: '#775',
      bypassLabels: []
    },
    {},
    {
      exceptionGovernance: {
        allowBypass: true,
        remediationLabels: ['ci', 'governance', 'supply-chain']
      }
    },
    new Date('2026-03-06T00:00:00Z')
  );
  assert.equal(active.status, 'active');
  assert.equal(active.active, true);
});

test('buildBypassLedger records bypass usage and remediation state', () => {
  const ledger = __test.buildBypassLedger({
    repository: 'example/repo',
    scope: {
      mode: 'pull_request',
      pullRequest: 775,
      baseSha: null,
      headSha: null
    },
    policy: {
      path: 'tools/policy/commit-integrity-policy.json',
      schema: 'commit-integrity-policy/v1',
      failOnUnverified: true,
      exceptionGovernance: {
        allowBypass: true,
        requireReasonOwnerExpiry: true,
        remediationLabels: ['ci', 'governance', 'supply-chain'],
        remediationTitlePrefix: '[Commit Integrity] Expired bypass remediation',
        remediationIssueMarker: '<!-- commit-integrity-bypass-remediation@v1 -->'
      }
    },
    observeOnly: false,
    bypass: {
      requested: true,
      status: 'expired',
      active: false,
      bypassEnabled: true,
      reason: 'incident',
      owner: '@octocat',
      expiresAt: '2026-03-01T00:00:00.000Z',
      ticket: '#775',
      labels: ['ci', 'governance', 'supply-chain'],
      metadataErrors: []
    },
    remediation: {
      action: 'create',
      issueNumber: 800
    },
    evaluation: {
      result: 'fail',
      violations: [{ category: 'unverified-commit' }],
      issues: ['bypass-expired']
    },
    reportPath: 'tests/results/_agent/commit-integrity/commit-integrity-report.json',
    generatedAt: '2026-03-06T00:00:00.000Z'
  });

  assert.equal(ledger.schema, 'commit-integrity/bypass-ledger@v1');
  assert.equal(ledger.bypass.status, 'expired');
  assert.equal(ledger.remediation.action, 'create');
  assert.equal(ledger.evaluation.violationCount, 1);
});

test('routeExpiredBypassRemediationIssue opens remediation issue for expired bypass metadata', async () => {
  const calls = [];
  const createResponse = (payload, status = 200, statusText = 'OK') => ({
    ok: status >= 200 && status < 300,
    status,
    statusText,
    text: async () => (payload === null ? '' : JSON.stringify(payload))
  });
  const fetchMock = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    calls.push({ url, method, body: options.body ?? null });
    if (method === 'GET' && String(url).includes('/issues?')) {
      return createResponse([]);
    }
    if (method === 'POST' && String(url).endsWith('/issues')) {
      return createResponse({
        number: 901,
        html_url: 'https://github.com/example/repo/issues/901'
      });
    }
    throw new Error(`Unexpected request: ${method} ${url}`);
  };

  const route = await __test.routeExpiredBypassRemediationIssue({
    repository: 'example/repo',
    token: 'test-token',
    policy: {
      exceptionGovernance: {
        remediationTitlePrefix: '[Commit Integrity] Expired bypass remediation',
        remediationIssueMarker: '<!-- commit-integrity-bypass-remediation@v1 -->',
        remediationLabels: ['ci', 'governance', 'supply-chain']
      }
    },
    scope: {
      mode: 'pull_request',
      pullRequest: 775,
      baseSha: null,
      headSha: null
    },
    bypass: {
      owner: '@octocat',
      reason: 'incident',
      expiresAt: '2026-03-01T00:00:00.000Z',
      ticket: '#775',
      labels: ['ci', 'governance', 'supply-chain']
    },
    evaluation: {
      violations: [{ category: 'unverified-commit' }],
      issues: ['bypass-expired']
    },
    generatedAt: '2026-03-06T00:00:00.000Z',
    fetchFn: fetchMock
  });

  assert.equal(route.action, 'create');
  assert.equal(route.issueNumber, 901);
  assert.equal(
    calls.filter((entry) => entry.method === 'POST' && String(entry.url).endsWith('/issues')).length,
    1
  );
});
