import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import {
  MODE_DEFAULTS,
  SNAPSHOT_SCHEMA,
  runBackgroundAgentSaturation
} from '../background-agent-saturation.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('background agent saturation schema validates a generated receipt', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'background-agent-saturation-schema-'));
  const snapshotPath = path.join(root, 'tests', 'results', '_agent', 'runtime', 'background-agent-state.json');
  const outputPath = path.join(root, 'tests', 'results', '_agent', 'handoff', 'background-agent-saturation.json');

  writeJson(snapshotPath, {
    schema: SNAPSHOT_SCHEMA,
    generatedAt: '2026-03-25T19:50:00Z',
    owner: 'Sagan',
    mode: 'aggressive',
    targetSaturation: MODE_DEFAULTS.aggressive.target,
    acceptableBand: MODE_DEFAULTS.aggressive.band,
    measurementWindow: 'rolling-30m',
    availableAgents: 6,
    agents: [
      { id: 'a1', name: 'Alpha', state: 'productive', taskSummary: 'Validation prep', detail: null },
      { id: 'a2', name: 'Beta', state: 'awaiting instruction', taskSummary: 'Queued for next bounded slice', detail: null },
      { id: 'a3', name: 'Gamma', state: 'done', taskSummary: 'Completed issue draft', detail: null }
    ]
  });
  writeJson(path.join(root, '.agent_priority_cache.json'), { number: 1967, state: 'OPEN' });
  writeJson(path.join(root, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: 1967
  });

  const { report } = await runBackgroundAgentSaturation(
    {
      repoRoot: root,
      snapshotPath,
      outputPath
    },
    {
      now: new Date('2026-03-25T19:51:00Z')
    }
  );

  const schema = JSON.parse(
    fs.readFileSync(path.join(process.cwd(), 'docs', 'schemas', 'background-agent-saturation-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});
