#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  collectParity,
  parseCliArgs,
  parseFileList,
  parseRevListCounts,
  renderSummaryMarkdown
} from '../report-origin-upstream-parity.mjs';

test('parseRevListCounts parses left/right counters', () => {
  assert.deepEqual(parseRevListCounts('3\t12\n'), { baseOnly: 3, headOnly: 12 });
  assert.deepEqual(parseRevListCounts('0 0'), { baseOnly: 0, headOnly: 0 });
});

test('parseRevListCounts rejects invalid payloads', () => {
  assert.throws(() => parseRevListCounts(''), /Invalid rev-list count output/);
  assert.throws(() => parseRevListCounts('abc\t2'), /Invalid rev-list count output/);
});

test('parseFileList removes blanks and trims entries', () => {
  assert.deepEqual(parseFileList('\n a.txt \r\n\r\nb.txt\n'), ['a.txt', 'b.txt']);
});

test('parseCliArgs accepts parity options', () => {
  const parsed = parseCliArgs([
    '--base-ref',
    'upstream/develop',
    '--head-ref',
    'origin/develop',
    '--sample-limit',
    '5',
    '--strict',
    '--fail-on-tree-diff'
  ]);
  assert.equal(parsed.baseRef, 'upstream/develop');
  assert.equal(parsed.headRef, 'origin/develop');
  assert.equal(parsed.sampleLimit, 5);
  assert.equal(parsed.strict, true);
  assert.equal(parsed.failOnTreeDiff, true);
});

test('collectParity returns ok payload when git commands succeed', () => {
  const calls = [];
  const fakeRunner = (_cmd, args) => {
    calls.push(args.join(' '));
    if (args[0] === 'rev-parse' && args[1] === '--verify') {
      return { status: 0, stdout: `${args[2]}-commit\n`, stderr: '' };
    }
    if (args[0] === 'rev-parse' && String(args[1]).endsWith('^{tree}')) {
      return { status: 0, stdout: 'tree-shared\n', stderr: '' };
    }
    if (args[0] === 'rev-list') {
      return { status: 0, stdout: '2\t5\n', stderr: '' };
    }
    if (args[0] === 'diff') {
      return { status: 0, stdout: 'a.ps1\nb.ps1\n', stderr: '' };
    }
    if (args[0] === 'remote' && args[1] === 'get-url') {
      return { status: 0, stdout: `https://example/${args.at(-1)}.git\n`, stderr: '' };
    }
    return { status: 1, stdout: '', stderr: 'unexpected command' };
  };

  const report = collectParity(
    {
      baseRef: 'upstream/develop',
      headRef: 'origin/develop',
      sampleLimit: 1
    },
    fakeRunner
  );

  assert.equal(report.status, 'ok');
  assert.equal(report.tipDiff.fileCount, 2);
  assert.deepEqual(report.tipDiff.sample, ['a.ps1']);
  assert.deepEqual(report.commitDivergence, { baseOnly: 2, headOnly: 5 });
  assert.equal(report.treeParity.status, 'equal');
  assert.equal(report.treeParity.equal, true);
  assert.equal(report.historyParity.status, 'diverged');
  assert.equal(report.recommendation.code, 'history-diverged-tree-equal');
  assert.equal(report.remoteManagement.baseRemote, 'upstream');
  assert.equal(report.remoteManagement.headRemote, 'origin');
  assert.equal(calls.length >= 6, true);
});

test('collectParity returns unavailable payload when refs are missing (non-strict)', () => {
  const fakeRunner = (_cmd, args) => {
    if (args[0] === 'rev-parse') {
      return {
        status: 128,
        stdout: '',
        stderr: 'fatal: bad revision'
      };
    }
    if (args[0] === 'rev-list') {
      return {
        status: 128,
        stdout: '',
        stderr: 'fatal: ambiguous argument upstream/develop...origin/develop'
      };
    }
    return { status: 0, stdout: '', stderr: '' };
  };

  const report = collectParity(
    {
      baseRef: 'upstream/develop',
      headRef: 'origin/develop'
    },
    fakeRunner
  );

  assert.equal(report.status, 'unavailable');
  assert.match(report.reason, /git rev-parse --verify/);
});

test('collectParity throws in strict mode when git fails', () => {
  const fakeRunner = () => ({ status: 1, stdout: '', stderr: 'boom' });
  assert.throws(
    () =>
      collectParity(
        {
          baseRef: 'upstream/develop',
          headRef: 'origin/develop',
          strict: true
        },
        fakeRunner
      ),
    /git rev-parse --verify/
  );
});

test('renderSummaryMarkdown includes parity metrics for ok status', () => {
  const markdown = renderSummaryMarkdown({
    status: 'ok',
    baseRef: 'upstream/develop',
    headRef: 'origin/develop',
    treeParity: { status: 'equal', equal: true },
    historyParity: { status: 'diverged', equal: false },
    tipDiff: { fileCount: 3, sample: ['a.txt'], sampleLimit: 20 },
    commitDivergence: { baseOnly: 1, headOnly: 4 },
    recommendation: {
      code: 'history-diverged-tree-equal',
      summary: 'Tree is aligned but history diverges.',
      nextActions: ['No code sync required.']
    }
  });
  assert.match(markdown, /Tree Parity \| equal/);
  assert.match(markdown, /History Parity \| diverged/);
  assert.match(markdown, /Tip Diff File Count \| 3/);
  assert.match(markdown, /Commit Divergence \(base-only\/head-only\) \| 1\/4/);
  assert.match(markdown, /Recommendation \| history-diverged-tree-equal/);
  assert.match(markdown, /`a.txt`/);
});
