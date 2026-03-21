import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..', '..');

function loadText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function loadJson(relativePath) {
  return JSON.parse(loadText(relativePath));
}

function compileValidator() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(loadJson('docs/schemas/mission-control-envelope-v1.schema.json'));
}

test('mission-control envelope fixture matches schema', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');
  const valid = validate(fixture);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(fixture.missionControl.standingPriority.upstreamLabel, 'standing-priority');
  assert.equal(fixture.missionControl.standingPriority.forkLabel, 'fork-standing-priority');
  assert.equal(fixture.missionControl.standingPriority.forkFallbackLabel, 'standing-priority');
  assert.equal(fixture.missionControl.standingPriority.queueEmptyBehavior, 'idle-repo');
  assert.equal(fixture.missionControl.standingPriority.branchCreationGate, 'restore-intake-before-branching');
  assert.equal(fixture.missionControl.mode, 'enforce');
  assert.ok(fixture.missionControl.stopConditions.includes('current-head-failure'));
  assert.equal(fixture.missionControl.copilotCli.usageMode, 'optional');
  assert.deepEqual(fixture.missionControl.copilotCli.purposes, ['iteration', 'review-acceleration']);
  assert.equal(fixture.missionControl.packageManagerPolicy.allowRawNpm, false);
  assert.deepEqual(fixture.missionControl.packageManagerPolicy.allowedWrappers, [
    'node tools/npm/cli.mjs <command>',
    'node tools/npm/run-script.mjs <script>'
  ]);
  assert.equal(fixture.missionControl.lanePolicy.mergeAuthority, 'live-lane-only');
  assert.equal(fixture.missionControl.worktreePolicy.cleanWorktreesRequired, true);
  assert.equal(fixture.missionControl.worktreePolicy.dirtyRootQuarantined, true);
  assert.equal(fixture.missionControl.worktreePolicy.worktreeBaseRef, 'upstream/develop');
  assert.equal(fixture.missionControl.remoteSyncPolicy.syncBeforeAndAfterMerge, true);
  assert.deepEqual(fixture.missionControl.remoteSyncPolicy.developParityRemotes, [
    'upstream/develop',
    'origin/develop',
    'personal/develop'
  ]);
  assert.equal(
    fixture.missionControl.repoHelpers.projectPortfolioCheck,
    'node tools/npm/run-script.mjs priority:project:portfolio:check'
  );
  assert.equal(
    fixture.missionControl.repoHelpers.safePrCheckPolling,
    'node tools/npm/run-script.mjs ci:watch:safe -- --PullRequest <pr-number> -IntervalSeconds 20'
  );
  assert.deepEqual(fixture.missionControl.stopConditions, [
    'current-head-failure',
    'destructive-ambiguity',
    'real-safety-boundary',
    'missing-source-of-truth',
    'user-override'
  ]);
  assert.equal(fixture.missionControl.lanePolicy.maxActiveCodingLanes, 4);
  assert.equal(fixture.missionControl.lanePolicy.maxParkedLaneCount, 3);
  assert.equal(fixture.missionControl.lanePolicy.parkedLaneRequiresGithubWait, false);
  assert.equal(fixture.missionControl.lanePolicy.requireDisjointFileScopes, true);
  assert.equal(fixture.missionControl.lanePolicy.allowThirdLane, true);
  assert.equal(fixture.missionControl.copilotCli.hostedReplacementAllowed, false);
});

test('mission-control envelope rejects contradictory lane and Copilot settings', () => {
  const validate = compileValidator();
  const fixture = loadJson('tools/priority/__fixtures__/mission-control/mission-control-envelope.json');

  const contradictoryLaneEnvelope = structuredClone(fixture);
  contradictoryLaneEnvelope.missionControl.lanePolicy.allowThirdLane = false;
  contradictoryLaneEnvelope.missionControl.lanePolicy.parkedLaneRequiresGithubWait = true;
  contradictoryLaneEnvelope.missionControl.lanePolicy.maxActiveCodingLanes = 2;
  contradictoryLaneEnvelope.missionControl.lanePolicy.maxParkedLaneCount = 1;

  assert.equal(validate(contradictoryLaneEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /allowThirdLane|maxActiveCodingLanes|maxParkedLaneCount|parkedLaneRequiresGithubWait/);

  const contradictoryCopilotEnvelope = structuredClone(fixture);
  contradictoryCopilotEnvelope.missionControl.copilotCli.purposes = ['iteration', 'continuous-integration'];
  contradictoryCopilotEnvelope.missionControl.copilotCli.hostedReplacementAllowed = true;

  assert.equal(validate(contradictoryCopilotEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /continuous-integration|hostedReplacementAllowed/);

  const contradictoryAntiIdleEnvelope = structuredClone(fixture);
  contradictoryAntiIdleEnvelope.missionControl.antiIdle.mergeGreenPrImmediately = false;
  contradictoryAntiIdleEnvelope.missionControl.repoHelpers.bootstrap = 'pwsh -File tools/priority/bootstrap.ps1 ; echo drift';
  contradictoryAntiIdleEnvelope.missionControl.mode = 'advisory';
  contradictoryAntiIdleEnvelope.missionControl.packageManagerPolicy.allowRawNpm = true;
  contradictoryAntiIdleEnvelope.missionControl.worktreePolicy.cleanWorktreesRequired = false;
  contradictoryAntiIdleEnvelope.missionControl.remoteSyncPolicy.developParityRemotes = ['upstream/develop'];

  assert.equal(validate(contradictoryAntiIdleEnvelope), false);
  assert.match(
    JSON.stringify(validate.errors),
    /mergeGreenPrImmediately|bootstrap|mode|allowRawNpm|cleanWorktreesRequired|developParityRemotes/
  );

  const contradictoryStopConditionsEnvelope = structuredClone(fixture);
  contradictoryStopConditionsEnvelope.missionControl.stopConditions = ['user-override'];

  assert.equal(validate(contradictoryStopConditionsEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /stopConditions/);

  const contradictoryOverrideEnvelope = structuredClone(fixture);
  contradictoryOverrideEnvelope.operator.overrides = [
    { key: 'allowAdminMerge', value: 'banana', reason: 'nonsensical type' },
    { key: 'copilotCliUsage', value: true, reason: 'nonsensical type' }
  ];

  assert.equal(validate(contradictoryOverrideEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /allowAdminMerge|copilotCliUsage|value/);

  const duplicateOverrideEnvelope = structuredClone(fixture);
  duplicateOverrideEnvelope.operator.overrides = [
    { key: 'allowParkedLane', value: true, reason: 'first' },
    { key: 'allowParkedLane', value: false, reason: 'conflict' }
  ];

  assert.equal(validate(duplicateOverrideEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /operator\/overrides|must NOT be valid|allOf\/2\/not/);

  const contradictoryIntentFocusEnvelope = structuredClone(fixture);
  contradictoryIntentFocusEnvelope.operator.intent = 'restore-intake';
  contradictoryIntentFocusEnvelope.operator.focus = 'standing-priority';

  assert.equal(validate(contradictoryIntentFocusEnvelope), false);
  assert.match(JSON.stringify(validate.errors), /operator\/focus|restore-intake|standing-priority/);
});

test('mission-control docs advertise the canonical prompt and envelope contract together', () => {
  const prompt = loadText('PROMPT_AUTONOMY.md');
  const manifest = loadJson('docs/documentation-manifest.json');

  assert.match(prompt, /docs\/schemas\/mission-control-envelope-v1\.schema\.json/);
  assert.match(prompt, /tools\/priority\/__fixtures__\/mission-control\/mission-control-envelope\.json/);
  assert.match(prompt, /queue-empty, do not invent implementation work\. Treat the repository as intentionally idle/i);
  assert.match(prompt, /current-head-failure/i);
  assert.match(prompt, /Stop conditions:\s*- `current-head-failure`\s*- `destructive-ambiguity`\s*- `real-safety-boundary`/i);
  assert.match(prompt, /fork contexts: `fork-standing-priority` with `standing-priority` fallback/i);
  assert.match(prompt, /Copilot CLI is local-only/i);
  assert.match(prompt, /Never use raw `npm`; use:/i);
  assert.match(prompt, /priority:project:portfolio:check/i);
  assert.match(prompt, /ci:watch:safe/i);
  assert.match(prompt, /Work only from clean worktrees\./i);
  assert.match(prompt, /Keep the dirty root workspace quarantined/i);
  assert.match(prompt, /aligned before and after each merge/i);
  assert.match(prompt, /Create worktrees from `upstream\/develop` only\./i);
  assert.match(prompt, /Maintain up to 4 proactive coding lanes when safe actionable work exists\./i);
  assert.match(prompt, /Start filling safe lane capacity from session start\./i);
  assert.match(prompt, /delivery-agent-state\.json/i);
  assert.match(prompt, /throughput-scorecard\.json/i);
  assert.match(prompt, /missionControl`: repo-owned law and execution invariants/i);
  assert.match(prompt, /operator\.intent` and `operator\.focus`: bounded operator input/i);
  assert.match(prompt, /operator\.overrides`: narrow, auditable exceptions/i);

  const rootEntry = manifest.entries.find((entry) => entry.name === 'Root Entry Points');
  assert.ok(rootEntry, 'Root Entry Points entry is missing from docs manifest.');
  assert.ok(rootEntry.files.includes('PROMPT_AUTONOMY.md'));

  const missionControlEntry = manifest.entries.find((entry) => entry.name === 'Mission Control Contracts');
  assert.ok(missionControlEntry, 'Mission Control Contracts entry is missing from docs manifest.');
  assert.ok(missionControlEntry.files.includes('docs/schemas/mission-control-envelope-v1.schema.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__fixtures__/mission-control/mission-control-envelope.json'));
  assert.ok(missionControlEntry.files.includes('tools/priority/__tests__/mission-control-envelope-schema.test.mjs'));
});
