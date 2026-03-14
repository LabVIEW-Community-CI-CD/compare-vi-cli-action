#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as priorityCopilot from '../../../priority/copilot-cli-review.mjs';
import * as localCopilot from '../copilot-cli-review.mjs';
import * as prioritySimulation from '../../../priority/simulation-review.mjs';
import * as localSimulation from '../simulation-review.mjs';

const THIS_FILE = fileURLToPath(import.meta.url);
const PROVIDERS_DIR = path.dirname(THIS_FILE);
const TOOLS_DIR = path.resolve(PROVIDERS_DIR, '..', '..', '..');

test('priority copilot shim re-exports the local provider contract', () => {
  assert.equal(priorityCopilot.REVIEW_PROVIDER_ID, localCopilot.REVIEW_PROVIDER_ID);
  assert.equal(priorityCopilot.COPILOT_CLI_REVIEW_SCHEMA, localCopilot.COPILOT_CLI_REVIEW_SCHEMA);
  assert.equal(priorityCopilot.runCopilotCliReview, localCopilot.runCopilotCliReview);
  assert.equal(priorityCopilot.resolveRepoGitState, localCopilot.resolveRepoGitState);
  assert.equal(typeof priorityCopilot.main, 'function');
});

test('priority simulation shim re-exports the local provider contract', () => {
  assert.equal(prioritySimulation.SIMULATION_REVIEW_SCHEMA, localSimulation.SIMULATION_REVIEW_SCHEMA);
  assert.equal(prioritySimulation.normalizeSimulationReviewPolicy, localSimulation.normalizeSimulationReviewPolicy);
  assert.equal(prioritySimulation.runSimulationReview, localSimulation.runSimulationReview);
});

test('local providers no longer point back into tools/priority', async () => {
  const copilotSource = await readFile(path.join(TOOLS_DIR, 'local-collab', 'providers', 'copilot-cli-review.mjs'), 'utf8');
  const simulationSource = await readFile(path.join(TOOLS_DIR, 'local-collab', 'providers', 'simulation-review.mjs'), 'utf8');

  assert.doesNotMatch(copilotSource, /from ['"][^'"]*priority[^'"]*['"]/);
  assert.doesNotMatch(simulationSource, /from ['"][^'"]*priority[^'"]*['"]/);
});

test('priority compatibility files stay as thin shims', async () => {
  const copilotShim = await readFile(path.join(TOOLS_DIR, 'priority', 'copilot-cli-review.mjs'), 'utf8');
  const simulationShim = await readFile(path.join(TOOLS_DIR, 'priority', 'simulation-review.mjs'), 'utf8');

  assert.match(copilotShim, /export \* from '\.\.\/local-collab\/providers\/copilot-cli-review\.mjs'/);
  assert.match(copilotShim, /isEntrypoint/);
  assert.match(simulationShim, /export \* from '\.\.\/local-collab\/providers\/simulation-review\.mjs'/);
  assert.doesNotMatch(simulationShim, /runSimulationReview\(/);
});
