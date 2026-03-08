import test from 'node:test';
import assert from 'node:assert/strict';
import { dispatchValidate, parseCliOptions } from '../dispatch-validate.mjs';

function createRunStub({
  fullRef = 'refs/heads/feature/x',
  sha = 'abc1234',
  statusOutput = '',
  ghList = '[]',
  onPush = () => {}
} = {}) {
  const calls = [];
  const stub = (cmd, args) => {
    calls.push({ cmd, args });
    if (cmd === 'git') {
      if (args[0] === 'rev-parse' && args[1] === '--symbolic-full-name') {
        return fullRef;
      }
      if (args[0] === 'rev-parse' && args[1] === '--verify') {
        return sha;
      }
      if (args[0] === 'status' && args[1] === '--porcelain') {
        return statusOutput;
      }
      if (args[0] === 'push') {
        onPush(args);
        return '';
      }
    }
    if (cmd === 'gh' && args[0] === 'run' && args[1] === 'list') {
      return ghList;
    }
    return '';
  };
  stub.calls = calls;
  return stub;
}

test('parseCliOptions respects env override', () => {
  const opts = parseCliOptions(['node', 'script'], {
    VALIDATE_DISPATCH_ALLOW_FORK: '1',
    VALIDATE_DISPATCH_PUSH: '1',
    VALIDATE_DISPATCH_FORCE_PUSH: '1',
    VALIDATE_DISPATCH_ALLOW_NONCANONICAL_VI_HISTORY: '1',
    VALIDATE_DISPATCH_ALLOW_NONCANONICAL_HISTORY_CORE: '1',
  });
  assert.equal(opts.allowFork, true);
  assert.equal(opts.pushMissing, true);
  assert.equal(opts.forcePushOk, true);
  assert.equal(opts.historyScenarioSet, 'smoke');
  assert.equal(opts.allowNonCanonicalViHistory, true);
  assert.equal(opts.allowNonCanonicalHistoryCore, true);
  assert.equal(opts.ref, null);
});

test('parseCliOptions accepts cli flags', () => {
  const opts = parseCliOptions([
    'node',
    'script',
    '--ref',
    'feature/x',
    '--sample-id',
    'ts-20260308-000000-abcd',
    '--history-scenario-set',
    'history-core',
    '--push-missing',
    '--force-push-ok',
    '--allow-noncanonical-vi-history',
    '--allow-noncanonical-history-core',
  ]);
  assert.equal(opts.ref, 'feature/x');
  assert.equal(opts.sampleId, 'ts-20260308-000000-abcd');
  assert.equal(opts.historyScenarioSet, 'history-core');
  assert.equal(opts.pushMissing, true);
  assert.equal(opts.forcePushOk, true);
  assert.equal(opts.allowNonCanonicalViHistory, true);
  assert.equal(opts.allowNonCanonicalHistoryCore, true);
});

test('parseCliOptions treats blank history scenario input as smoke', () => {
  const opts = parseCliOptions([
    'node',
    'script',
    '--history-scenario-set',
    '   ',
  ]);

  assert.equal(opts.historyScenarioSet, 'smoke');
});

test('parseCliOptions trims non-empty sample ids', () => {
  const opts = parseCliOptions([
    'node',
    'script',
    '--sample-id',
    '  ts-20260308-000000-abcd  ',
  ]);

  assert.equal(opts.sampleId, 'ts-20260308-000000-abcd');
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
        runFn: createRunStub(),
        ensureGhCliFn: () => {}
      }),
    /blocked: working copy points to a fork/i
  );
});

test('dispatchValidate allows fork when override set', () => {
  const runStub = createRunStub();
  const result = dispatchValidate({
    argv: [
      'node',
      'script',
      '--allow-fork',
      '--ref',
      'feature/x',
      '--sample-id',
      'ts-20260308-000000-abcd',
      '--history-scenario-set',
      'history-core',
      '--allow-noncanonical-vi-history',
      '--allow-noncanonical-history-core',
    ],
    env: {},
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: true
    }),
    getCurrentBranchFn: () => 'feature/x',
    findRemoteRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureRemoteHasRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureCleanWorkingTreeFn: () => {},
    runFn: runStub,
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.ok(
    runStub.calls.some(
      (call) =>
        call.cmd === 'gh' &&
        call.args[0] === 'workflow' &&
        call.args[1] === 'run' &&
        call.args.includes('validate.yml') &&
        call.args.includes('sample_id=ts-20260308-000000-abcd') &&
        call.args.includes('history_scenario_set=history-core') &&
        call.args.includes('allow_noncanonical_vi_history=true') &&
        call.args.includes('allow_noncanonical_history_core=true')
    ),
    'should dispatch validate workflow via gh'
  );
});

test('dispatchValidate generates and forwards a sample_id when not provided', () => {
  const runStub = createRunStub();

  const result = dispatchValidate({
    argv: ['node', 'script', '--allow-fork', '--ref', 'feature/x'],
    env: {},
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: false
    }),
    getCurrentBranchFn: () => 'feature/x',
    findRemoteRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureRemoteHasRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureCleanWorkingTreeFn: () => {},
    runFn: runStub,
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.match(result.sampleId, /^ts-\d{8}-\d{6}-[0-9a-z]{4}$/);
  const workflowCall = runStub.calls.find(
    (call) => call.cmd === 'gh' && call.args[0] === 'workflow' && call.args[1] === 'run'
  );
  assert.ok(workflowCall, 'should invoke gh workflow run');
  const sampleArg = workflowCall.args.find((arg) => arg.startsWith('sample_id='));
  assert.ok(sampleArg, 'should pass sample_id input');
  assert.equal(sampleArg, `sample_id=${result.sampleId}`);
  assert.ok(workflowCall.args.includes('history_scenario_set=smoke'));
  assert.ok(workflowCall.args.includes('allow_noncanonical_vi_history=false'));
  assert.ok(workflowCall.args.includes('allow_noncanonical_history_core=false'));
});

test('dispatchValidate generates a sample_id when --sample-id is blank', () => {
  const runStub = createRunStub();

  const result = dispatchValidate({
    argv: ['node', 'script', '--allow-fork', '--ref', 'feature/x', '--sample-id', '   '],
    env: {},
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: false
    }),
    getCurrentBranchFn: () => 'feature/x',
    findRemoteRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureRemoteHasRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'abc1234' }),
    ensureCleanWorkingTreeFn: () => {},
    runFn: runStub,
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.match(result.sampleId, /^ts-\d{8}-\d{6}-[0-9a-z]{4}$/);
  const workflowCall = runStub.calls.find(
    (call) => call.cmd === 'gh' && call.args[0] === 'workflow' && call.args[1] === 'run'
  );
  assert.ok(workflowCall, 'should invoke gh workflow run');
  const sampleArg = workflowCall.args.find((arg) => arg.startsWith('sample_id='));
  assert.ok(sampleArg, 'should pass sample_id input');
  assert.equal(sampleArg, `sample_id=${result.sampleId}`);
  assert.notEqual(sampleArg, 'sample_id=');
});

test('dispatchValidate fails when ref missing on remote without auto-push', () => {
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
        findRemoteRefFn: () => null,
        ensureRemoteHasRefFn: () => {
          throw new Error('should not push');
        },
        ensureCleanWorkingTreeFn: () => {
          throw new Error('should not check cleanliness');
        },
        runFn: createRunStub({ fullRef: 'refs/heads/missing' }),
        ensureGhCliFn: () => {}
      }),
    /Push it first/i
  );
});

test('dispatchValidate pushes missing refs when flag set', () => {
  let published = false;
  let cleanChecked = false;
  let pushArgs = null;
  const runStub = createRunStub({
    onPush: (args) => {
      pushArgs = args;
    }
  });
  const result = dispatchValidate({
    argv: ['node', 'script', '--ref', 'feature/x', '--push-missing'],
    env: { VALIDATE_DISPATCH_ALLOW_FORK: '1' },
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: false
    }),
    getCurrentBranchFn: () => 'feature/x',
    findRemoteRefFn: () => (published ? { pattern: 'refs/heads/feature/x', sha: 'abc1234' } : null),
    ensureRemoteHasRefFn: () => {
      published = true;
      return { pattern: 'refs/heads/feature/x', sha: 'abc1234' };
    },
    ensureCleanWorkingTreeFn: (runOverride) => {
      cleanChecked = true;
      assert.equal(runOverride('git', ['status', '--porcelain']), '');
    },
    runFn: runStub,
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.equal(cleanChecked, true);
  assert.ok(pushArgs, 'should invoke git push');
  assert.ok(!pushArgs.includes('--force-with-lease'), 'should not force push by default');
});

test('dispatchValidate refuses to overwrite upstream without force flag', () => {
  const runStub = createRunStub();
  assert.throws(
    () =>
      dispatchValidate({
        argv: ['node', 'script', '--ref', 'feature/x', '--push-missing'],
        env: { VALIDATE_DISPATCH_ALLOW_FORK: '1' },
        getRepoRootFn: () => 'repo',
        resolveContextFn: () => ({
          upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
          isFork: false
        }),
        getCurrentBranchFn: () => 'feature/x',
        findRemoteRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'deadbeef' }),
        ensureRemoteHasRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: 'deadbeef' }),
        ensureCleanWorkingTreeFn: () => {
          throw new Error('should not force push');
        },
        runFn: runStub,
        ensureGhCliFn: () => {}
      }),
    /Pass --force-push-ok/i
  );
});

test('dispatchValidate force pushes when override present', () => {
  let remoteSha = 'deadbeef';
  let cleanChecked = false;
  let forcePushInvoked = false;
  const runStub = createRunStub({
    onPush: (args) => {
      if (args.includes('--force-with-lease')) {
        forcePushInvoked = true;
      }
      remoteSha = 'abc1234';
    }
  });
  const result = dispatchValidate({
    argv: ['node', 'script', '--ref', 'feature/x', '--push-missing', '--force-push-ok'],
    env: { VALIDATE_DISPATCH_ALLOW_FORK: '1' },
    getRepoRootFn: () => 'repo',
    resolveContextFn: () => ({
      upstream: { owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' },
      isFork: false
    }),
    getCurrentBranchFn: () => 'feature/x',
    findRemoteRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: remoteSha }),
    ensureRemoteHasRefFn: () => ({ pattern: 'refs/heads/feature/x', sha: remoteSha }),
    ensureCleanWorkingTreeFn: (runOverride) => {
      cleanChecked = true;
      assert.equal(runOverride('git', ['status', '--porcelain']), '');
    },
    runFn: runStub,
    ensureGhCliFn: () => {}
  });

  assert.equal(result.dispatched, true);
  assert.equal(cleanChecked, true);
  assert.equal(forcePushInvoked, true);
  assert.ok(
    runStub.calls.some((call) => call.cmd === 'gh' && call.args[0] === 'workflow' && call.args[1] === 'run')
  );
});
