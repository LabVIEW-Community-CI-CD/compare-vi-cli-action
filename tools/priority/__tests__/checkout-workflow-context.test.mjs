#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveCheckoutContext } from '../../../.github/actions/checkout-workflow-context/resolve.mjs';

test('pr-head mode resolves PR head repository and SHA on pull_request events', () => {
  const result = resolveCheckoutContext({
    mode: 'pr-head',
    eventName: 'pull_request',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    sha: 'base-sha',
    prHeadRepository: 'fork-owner/compare-vi-cli-action',
    prHeadSha: 'head-sha'
  });

  assert.deepEqual(result, {
    repository: 'fork-owner/compare-vi-cli-action',
    ref: 'head-sha',
    effectiveMode: 'pr-head'
  });
});

test('base-safe mode resolves the base SHA for pull_request_target and pull_request_review events', () => {
  for (const eventName of ['pull_request_target', 'pull_request_review']) {
    const result = resolveCheckoutContext({
      mode: 'base-safe',
      eventName,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      sha: 'workflow-sha',
      prBaseSha: 'base-sha'
    });

    assert.deepEqual(result, {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      ref: 'base-sha',
      effectiveMode: 'base-safe'
    });
  }
});

test('merge_group and workflow_dispatch fall back to the workflow repository and SHA', () => {
  for (const eventName of ['merge_group', 'workflow_dispatch']) {
    const result = resolveCheckoutContext({
      mode: 'pr-head',
      eventName,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      sha: 'workflow-sha'
    });

    assert.deepEqual(result, {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      ref: 'workflow-sha',
      effectiveMode: 'pr-head'
    });
  }
});

test('explicit repository and ref overrides win over inferred context', () => {
  const result = resolveCheckoutContext({
    mode: 'base-safe',
    eventName: 'pull_request_target',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    sha: 'workflow-sha',
    prBaseSha: 'base-sha',
    overrideRepository: 'override/repo',
    overrideRef: 'override-ref'
  });

  assert.deepEqual(result, {
    repository: 'override/repo',
    ref: 'override-ref',
    effectiveMode: 'base-safe'
  });
});
