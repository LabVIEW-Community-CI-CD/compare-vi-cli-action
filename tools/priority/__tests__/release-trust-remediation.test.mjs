#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { buildReleaseTrustRemediationMarkdown, runReleaseTrustRemediation } from '../release-trust-remediation.mjs';

test('buildReleaseTrustRemediationMarkdown emits repair guidance for unsigned or lightweight tags', () => {
  const markdown = buildReleaseTrustRemediationMarkdown({
    tagRef: 'v0.6.4-rc.1',
    trustReport: {
      failures: [{ code: 'tag-signature-unverified' }],
      tagSignature: {
        refName: 'v0.6.4-rc.1'
      }
    }
  });

  assert.match(markdown, /repair-eligible tag failures/);
  assert.match(markdown, /`version = 0\.6\.4-rc\.1`/);
  assert.match(markdown, /`repair_existing_tag = true`/);
  assert.match(markdown, /Preserve tag identity and asset names/);
});

test('buildReleaseTrustRemediationMarkdown reports not-needed when no repair failures exist', () => {
  const markdown = buildReleaseTrustRemediationMarkdown({
    tagRef: 'v0.6.4-rc.1',
    trustReport: {
      failures: [{ code: 'checksum-mismatch' }]
    }
  });

  assert.match(markdown, /No repair-mode remediation is required/);
  assert.doesNotMatch(markdown, /repair_existing_tag/);
});

test('runReleaseTrustRemediation writes markdown artifact and appends to workflow summary', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'release-trust-remediation-'));
  const trustPath = path.join(tempRoot, 'release-trust-gate.json');
  const outputPath = path.join(tempRoot, 'release-trust-remediation.md');
  const summaryPath = path.join(tempRoot, 'step-summary.md');

  await writeFile(
    trustPath,
    JSON.stringify(
      {
        failures: [{ code: 'tag-not-annotated' }],
        tagSignature: {
          refName: 'v0.6.4-rc.1'
        }
      },
      null,
      2
    )
  );

  const result = await runReleaseTrustRemediation({
    args: {
      trustReportPath: trustPath,
      outputPath,
      summaryPath,
      tagRef: 'v0.6.4-rc.1'
    }
  });

  assert.equal(result.wroteSummary, true);
  const output = await readFile(outputPath, 'utf8');
  const summary = await readFile(summaryPath, 'utf8');
  assert.match(output, /`repair_existing_tag = true`/);
  assert.match(summary, /`repair_existing_tag = true`/);
});
