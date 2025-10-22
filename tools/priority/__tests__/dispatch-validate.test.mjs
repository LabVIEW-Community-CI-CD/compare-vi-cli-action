import test from 'node:test';
import assert from 'node:assert/strict';
import { dispatchValidate, parseCliOptions } from '../dispatch-validate.mjs';

test('parseCliOptions respects env override', () => {
  const opts = parseCliOptions(['node', 'script'], { VALIDATE_DISPATCH_ALLOW_FORK: '1' });
  assert.equal(opts.allowFork, true);
  assert.equal(opts.ref, null);
});

test('dispatchValidate blocks fork by default', () => {
  assert.throws(
    () =>
      dispatchValidate({
        argv: ['node', 'script'],
        env: {},
        getRepoRootFn: () => 'repo',
        resolveContextFn: () => ({
          upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
          isFork: true
        }),
        getCurrentBranchFn: () => 'feature/x',
        ensureRemoteHasRefFn: () => {},
        runFn: () => '',
        ensureGhCliFn: () => {}
      }),
    /blocked: working copy points to a fork/i
  );
});

test('dispatchValidate allows fork when override set', () => {
  const calls = [];
  const result = dispatchValidate({
    argv: ['node', 'script', '--allow-fork', '--ref', 'feature/x'],
    env: {},
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: true
    }),
    getCurrentBranchFn: () => 'feature/x',
    ensureRemoteHasRefFn: () => {},
    runFn: (cmd, args) => {
      calls.push({ cmd, args });
      if (args[0] === 'run' && args[1] === 'list') {
        return '[]';
      }
      return '';
    },
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.ok(
    calls.some(
      (call) =>
        call.cmd === 'gh' &&
        call.args[0] === 'workflow' &&
        call.args[1] === 'run' &&
        call.args.includes('validate.yml')
    ),
    'should dispatch validate workflow via gh'
  );
});

test('dispatchValidate fails when ref missing on remote', () => {
  assert.throws(
    () =>
      dispatchValidate({
        argv: ['node', 'script', '--ref', 'missing'],
        env: { VALIDATE_DISPATCH_ALLOW_FORK: '1' },
        getRepoRootFn: () => 'repo',
        resolveContextFn: () => ({
          upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
          isFork: false
        }),
        getCurrentBranchFn: () => 'missing',
        ensureRemoteHasRefFn: () => {
          throw new Error('Ref missing');
        },
        runFn: () => '',
        ensureGhCliFn: () => {}
      }),
    /Ref missing/i
  );
});

