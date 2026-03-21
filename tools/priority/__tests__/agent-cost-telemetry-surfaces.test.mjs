#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('agent cost telemetry knowledgebase points at the checked-in precursor surfaces instead of hidden billing assumptions', () => {
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');
  const contractEntry = manifest.entries.find((entry) => entry.name === 'Agent Cost Telemetry Contracts');
  const guide = readText('docs/knowledgebase/Agent-Cost-Telemetry-Surfaces.md');

  assert.ok(docsEntry);
  assert.ok(contractEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Agent-Cost-Telemetry-Surfaces.md'));
  assert.ok(contractEntry.files.includes('docs/schemas/agent-cost-private-invoice-metadata-v1.schema.json'));
  assert.ok(contractEntry.files.includes('docs/schemas/agent-cost-invoice-turn-v1.schema.json'));
  assert.ok(contractEntry.files.includes('tools/priority/agent-cost-invoice-normalize.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/agent-cost-invoice-turn.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/agent-cost-turn.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/agent-cost-rollup.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/__fixtures__/agent-cost-rollup/private-invoice-metadata-sample.json'));
  assert.ok(contractEntry.files.includes('tools/priority/__tests__/agent-cost-invoice-normalize.test.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/__tests__/agent-cost-invoice-normalize-schema.test.mjs'));
  assert.ok(contractEntry.files.includes('tools/priority/__fixtures__/agent-cost-rollup/invoice-turn-next-baseline.json'));
  assert.ok(contractEntry.files.includes('tools/priority/__fixtures__/agent-cost-rollup/invoice-turn-baseline-reconciled.json'));
  assert.match(guide, /tools\/local-collab\/ledger\/local-review-ledger\.mjs/);
  assert.match(guide, /tests\/results\/_agent\/local-collab\/ledger\/receipts\/<phase>\/<head-sha>\.json/);
  assert.match(guide, /requestedModel/);
  assert.match(guide, /effectiveModel/);
  assert.match(guide, /inputTokens/);
  assert.match(guide, /cachedInputTokens/);
  assert.match(guide, /outputTokens/);
  assert.match(guide, /tools\/local-collab\/providers\/copilot-cli-review\.mjs/);
  assert.match(guide, /tests\/results\/docker-tools-parity\/copilot-cli-review\/receipt\.json/);
  assert.match(guide, /docs\/schemas\/runtime-delivery-task-packet-v1\.schema\.json/);
  assert.match(guide, /docs\/schemas\/delivery-agent-runtime-state-v1\.schema\.json/);
  assert.match(guide, /tests\/results\/_agent\/runtime\/delivery-agent-state\.json/);
  assert.match(guide, /tools\/local-collab\/kpi\/rollup-local-collab-kpi\.mjs/);
  assert.match(guide, /tests\/results\/_agent\/local-collab\/kpi\/summary\.json/);
  assert.match(guide, /tests\/results\/_agent\/throughput\/throughput-scorecard\.json/);
  assert.match(guide, /tests\/results\/_agent\/runtime\/delivery-memory\.json/);
  assert.match(guide, /docs\/schemas\/mission-control-envelope-v1\.schema\.json/);
  assert.match(guide, /docs\/schemas\/codex-state-hygiene-v1\.schema\.json/);
  assert.match(guide, /Unsafe uses:/);
  assert.match(guide, /exact token billing/);
  assert.match(guide, /amountKind = exact \| estimated/);
  assert.match(guide, /rateCardSource/);
  assert.match(guide, /First Implemented Invoice-Turn Slice/);
  assert.match(guide, /docs\/schemas\/agent-cost-private-invoice-metadata-v1\.schema\.json/);
  assert.match(guide, /tools\/priority\/agent-cost-invoice-normalize\.mjs/);
  assert.match(guide, /private-invoice-metadata-sample\.json/);
  assert.match(guide, /docs\/schemas\/agent-cost-invoice-turn-v1\.schema\.json/);
  assert.match(guide, /tools\/priority\/agent-cost-invoice-turn\.mjs/);
  assert.match(guide, /priority:cost:invoice-normalize/);
  assert.match(guide, /priority:cost:invoice-turn/);
  assert.match(guide, /priority:cost:turn/);
  assert.match(guide, /priority:cost:rollup/);
  assert.match(guide, /xhigh/);
  assert.match(guide, /Sticky Calibration Funding-Window Mode/);
  assert.match(guide, /selection\.mode = sticky-calibration/);
  assert.match(guide, /--selection-mode sticky-calibration --selection-reason <text>/);
  assert.match(guide, /multiple invoice-turn receipts may coexist/);
  assert.match(guide, /--invoice-turn-id/);
  assert.match(guide, /policy\.activationState = hold/);
  assert.match(guide, /heuristic drift directly/);
});
