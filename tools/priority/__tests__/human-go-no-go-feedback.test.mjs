#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { readFile } from 'node:fs/promises';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import {
  buildHumanGoNoGoDecisionPayload,
  parseArgs,
  runHumanGoNoGoFeedback,
} from '../human-go-no-go-feedback.mjs';

const repoRoot = process.cwd();

async function loadDecisionSchema() {
  return JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'human-go-no-go-decision-v1.schema.json'), 'utf8'),
  );
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('runHumanGoNoGoFeedback writes a schema-valid decision receipt, NDJSON event, and step summary', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'human-go-no-go-'));
  const decisionPath = path.join(tempRoot, 'handoff', 'human-go-no-go-decision.json');
  const eventsPath = path.join(tempRoot, 'handoff', 'human-go-no-go-events.ndjson');
  const stepSummaryPath = path.join(tempRoot, 'handoff', 'step-summary.md');
  const now = new Date('2026-03-14T11:05:00.000Z');

  const result = await runHumanGoNoGoFeedback({
    argv: [
      'node',
      'tools/priority/human-go-no-go-feedback.mjs',
      '--repository',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--decision',
      'nogo',
      '--feedback',
      'Tighten the manual disposition workflow before continuing.',
      '--context',
      'issue/personal-982-manual-disposition-workflow',
      '--run-id',
      '22900123456',
      '--issue-url',
      'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/982',
      '--evidence-url',
      'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/964#issuecomment-2',
      '--recorded-by',
      'svelderrainruiz',
      '--recommended-action',
      'revise',
      '--seed',
      'Add the actual workflow file and a deterministic writer helper.',
      '--decision-out',
      decisionPath,
      '--events-out',
      eventsPath,
      '--step-summary',
      stepSummaryPath,
    ],
    environment: {
      GITHUB_SERVER_URL: 'https://github.com',
    },
    repoRoot,
    now,
  });

  assert.equal(result.exitCode, 0);
  const payload = readJson(decisionPath);
  const events = fs
    .readFileSync(eventsPath, 'utf8')
    .trim()
    .split(/\r?\n/)
    .map((line) => JSON.parse(line));
  const stepSummary = fs.readFileSync(stepSummaryPath, 'utf8');

  const schema = await loadDecisionSchema();
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.schema, 'human-go-no-go-decision@v1');
  assert.equal(payload.target.runId, '22900123456');
  assert.equal(
    payload.links.runUrl,
    'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22900123456',
  );
  assert.equal(payload.nextIteration.recommendedAction, 'revise');
  assert.equal(events.length, 1);
  assert.equal(events[0].schema, 'human-go-no-go-event@v1');
  assert.equal(events[0].decision, 'nogo');
  assert.match(stepSummary, /### Human Go\/No-Go Decision/);
  assert.match(stepSummary, /decision: `nogo`/);
});

test('parseArgs defaults recommended action from the decision when not supplied', () => {
  const options = parseArgs(
    [
      'node',
      'tools/priority/human-go-no-go-feedback.mjs',
      '--decision',
      'go',
      '--feedback',
      'Proceed to the next lane.',
      '--context',
      'issue/personal-982-manual-disposition-workflow',
    ],
    {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      GITHUB_ACTOR: 'svelderrainruiz',
    },
    repoRoot,
  );

  const payload = buildHumanGoNoGoDecisionPayload(options, { GITHUB_SERVER_URL: 'https://github.com' }, new Date('2026-03-14T11:10:00.000Z'));

  assert.equal(options.recommendedAction, 'continue');
  assert.equal(payload.nextIteration.recommendedAction, 'continue');
  assert.equal(payload.decision.recordedBy, 'svelderrainruiz');
  assert.equal(payload.target.ref, 'issue/personal-982-manual-disposition-workflow');
});

test('parseArgs rejects invalid evidence URLs', () => {
  assert.throws(
    () =>
      parseArgs(
        [
          'node',
          'tools/priority/human-go-no-go-feedback.mjs',
          '--repository',
          'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          '--decision',
          'go',
          '--feedback',
          'Looks good.',
          '--context',
          'issue/personal-982-manual-disposition-workflow',
          '--evidence-url',
          'not-a-url',
        ],
        {},
        repoRoot,
      ),
    /--evidence-url must be a valid absolute URI/,
  );
});
