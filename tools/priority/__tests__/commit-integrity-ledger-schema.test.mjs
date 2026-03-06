import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { __test } from '../commit-integrity.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('commit integrity bypass ledger schema validates generated payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'commit-integrity-bypass-ledger-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const ledger = __test.buildBypassLedger({
    repository: 'example/repo',
    scope: {
      mode: 'pull_request',
      pullRequest: 775,
      baseSha: null,
      headSha: null
    },
    policy: {
      path: path.join(repoRoot, 'tools', 'policy', 'commit-integrity-policy.json'),
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
      status: 'active',
      active: true,
      bypassEnabled: true,
      reason: 'temporary incident mitigation',
      owner: '@octocat',
      expiresAt: '2026-03-31T00:00:00.000Z',
      ticket: '#775',
      labels: ['ci', 'governance', 'supply-chain'],
      metadataErrors: []
    },
    remediation: {
      action: 'none'
    },
    evaluation: {
      result: 'fail',
      violations: [{ category: 'unverified-commit' }],
      issues: []
    },
    reportPath: 'tests/results/_agent/commit-integrity/commit-integrity-report.json',
    generatedAt: '2026-03-06T00:00:00.000Z'
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(ledger);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
