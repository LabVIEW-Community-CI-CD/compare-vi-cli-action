import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('AGENT_HANDOFF stays bounded and points agents to live state artifacts', () => {
  const handoff = readText('AGENT_HANDOFF.txt');
  const lines = handoff.trimEnd().split(/\r?\n/);

  assert.ok(lines.length <= 80, `Expected AGENT_HANDOFF.txt to stay within 80 lines, found ${lines.length}.`);
  assert.equal(lines[0], '# Agent Handoff');
  assert.match(handoff, /stable handoff entrypoint/i);
  assert.match(handoff, /not a running\s+status log/i);
  assert.match(handoff, /^## First Actions$/m);
  assert.match(handoff, /^## Live State Surfaces$/m);
  assert.match(handoff, /^## Current-State Artifacts$/m);
  assert.match(handoff, /^## Working Rules$/m);
  assert.match(handoff, /^## When Handoff Looks Wrong$/m);
  assert.match(handoff, /\.agent_priority_cache\.json/);
  assert.match(handoff, /tests\/results\/_agent\/issue\/router\.json/);
  assert.match(handoff, /tests\/results\/_agent\/issue\/no-standing-priority\.json/);
  assert.match(handoff, /tests\/results\/_agent\/verification\/docker-review-loop-summary\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/continuity-summary\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/entrypoint-status\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/monitoring-mode\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/autonomous-governor-summary\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/autonomous-governor-portfolio-summary\.json/);
  assert.match(handoff, /tests\/results\/_agent\/handoff\/\*\.json/);
  assert.match(handoff, /tests\/results\/_agent\/sessions\/\*\.json/);
  assert.doesNotMatch(handoff, /^## 20\d{2}-\d{2}-\d{2}$/m);
});

test('handoff entrypoint contract is wired into automation and operator docs', () => {
  const packageJson = JSON.parse(readText('package.json'));
  const manifest = JSON.parse(readText('docs/documentation-manifest.json'));
  const runHandoffTests = readText('tools/priority/run-handoff-tests.mjs');
  const printHandoff = readText('tools/Print-AgentHandoff.ps1');
  const importHandoff = readText('tools/priority/Import-HandoffState.ps1');
  const agents = readText('AGENTS.md');
  const developerGuide = readText('docs/DEVELOPER_GUIDE.md');
  const handoffGuide = readText('docs/knowledgebase/Agent-Handoff-Surfaces.md');
  const docsEntry = manifest.entries.find((entry) => entry.name === 'Docs Tree');

  assert.equal(
    packageJson.scripts['handoff:entrypoint:check'],
    'pwsh -NoLogo -NoProfile -File tools/Test-AgentHandoffEntryPoint.ps1'
  );
  assert.ok(docsEntry);
  assert.ok(docsEntry.files.includes('docs/knowledgebase/Agent-Handoff-Surfaces.md'));
  assert.match(runHandoffTests, /handoff:entrypoint:check/);
  assert.match(runHandoffTests, /priority:continuity/);
  assert.match(printHandoff, /Test-AgentHandoffEntryPoint\.ps1/);
  assert.match(printHandoff, /-ResultsRoot \$ResultsRoot -Quiet/);
  assert.match(printHandoff, /continuity-telemetry\.mjs/);
  assert.match(printHandoff, /continuity-summary\.json/);
  assert.match(printHandoff, /handoff-monitoring-mode\.mjs/);
  assert.match(printHandoff, /monitoring-mode\.json/);
  assert.match(printHandoff, /release-published-bundle-observer\.mjs/);
  assert.match(printHandoff, /release-published-bundle-observer\.json/);
  assert.match(printHandoff, /release-signing-readiness\.mjs/);
  assert.match(printHandoff, /release-signing-readiness\.json/);
  assert.match(printHandoff, /autonomous-governor-summary\.mjs/);
  assert.match(printHandoff, /autonomous-governor-summary\.json/);
  assert.match(printHandoff, /autonomous-governor-portfolio-summary\.mjs/);
  assert.match(printHandoff, /autonomous-governor-portfolio-summary\.json/);
  assert.match(printHandoff, /docker-review-loop-summary\.json/);
  assert.match(importHandoff, /entrypoint-status\.json/);
  assert.match(importHandoff, /continuity-summary\.json/);
  assert.match(importHandoff, /monitoring-mode\.json/);
  assert.match(importHandoff, /autonomous-governor-summary\.json/);
  assert.match(importHandoff, /autonomous-governor-portfolio-summary\.json/);
  assert.match(importHandoff, /\[handoff\] Autonomous governor summary/);
  assert.match(importHandoff, /\[handoff\] Governor portfolio summary/);
  assert.match(importHandoff, /\[handoff\] Monitoring mode/);
  assert.match(importHandoff, /\[handoff\] Continuity summary/);
  assert.match(importHandoff, /docker-review-loop-summary\.json/);
  assert.match(importHandoff, /\[handoff\] Entrypoint index/);
  assert.match(agents, /handoff:entrypoint:check/);
  assert.match(agents, /priority:handoff/);
  assert.match(agents, /machine-readable index/i);
  assert.match(agents, /docker-review-loop-summary\.json/);
  assert.match(agents, /continuity-summary\.json/);
  assert.match(agents, /autonomous-governor-summary\.json/);
  assert.match(agents, /autonomous-governor-portfolio-summary\.json/);
  assert.match(developerGuide, /handoff:entrypoint:check/);
  assert.match(developerGuide, /priority:handoff/);
  assert.match(developerGuide, /machine-readable index/i);
  assert.match(handoffGuide, /AGENT_HANDOFF\.txt/);
  assert.match(handoffGuide, /entrypoint-status\.json/);
  assert.match(handoffGuide, /continuity-summary\.json/);
  assert.match(handoffGuide, /monitoring-mode\.json/);
  assert.match(handoffGuide, /autonomous-governor-summary\.json/);
  assert.match(handoffGuide, /autonomous-governor-portfolio-summary\.json/);
  assert.match(handoffGuide, /docker-review-loop-summary\.json/);
  assert.match(handoffGuide, /release-signing/i);
  assert.match(handoffGuide, /priority:handoff/);
  assert.match(handoffGuide, /queue-empty/);
  assert.match(handoffGuide, /future agents may pivot/i);
});
