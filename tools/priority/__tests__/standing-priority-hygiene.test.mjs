#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  issueHasLabel,
  parseCliArgs,
  shouldRemoveStandingPriorityLabel
} from '../standing-priority-hygiene.mjs';

test('issueHasLabel matches label names across string/object labels', () => {
  assert.equal(issueHasLabel({ labels: ['standing-priority'] }), true);
  assert.equal(issueHasLabel({ labels: [{ name: 'standing-priority' }] }), true);
  assert.equal(issueHasLabel({ labels: [{ name: 'enhancement' }] }), false);
});

test('shouldRemoveStandingPriorityLabel requires closed state and standing label', () => {
  assert.equal(
    shouldRemoveStandingPriorityLabel({
      state: 'closed',
      labels: [{ name: 'standing-priority' }]
    }),
    true
  );
  assert.equal(
    shouldRemoveStandingPriorityLabel({
      state: 'open',
      labels: [{ name: 'standing-priority' }]
    }),
    false
  );
  assert.equal(
    shouldRemoveStandingPriorityLabel({
      state: 'closed',
      labels: [{ name: 'enhancement' }]
    }),
    false
  );
});

test('parseCliArgs reads issue, label and dry-run options', () => {
  const parsed = parseCliArgs(['--issue', '141', '--label', 'standing-priority', '--dry-run']);
  assert.equal(parsed.issue, 141);
  assert.equal(parsed.label, 'standing-priority');
  assert.equal(parsed.dryRun, true);
});

test('parseCliArgs rejects missing issue', () => {
  assert.throws(() => parseCliArgs([]), /Missing required --issue/);
});

