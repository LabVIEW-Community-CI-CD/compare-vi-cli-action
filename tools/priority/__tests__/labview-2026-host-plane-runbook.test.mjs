import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const runbookPath = path.join(repoRoot, 'docs', 'SINGLE_HOST_LABVIEW_2026_PLANES.md');
const developerGuidePath = path.join(repoRoot, 'docs', 'DEVELOPER_GUIDE.md');
const manifestPath = path.join(repoRoot, 'docs', 'documentation-manifest.json');

function readFile(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

test('single-host runbook records the four explicit LabVIEW 2026 planes and the Docker exclusivity rule', () => {
  const runbook = readFile(runbookPath);

  assert.match(runbook, /docker-desktop\/windows-container-2026/);
  assert.match(runbook, /docker-desktop\/linux-container-2026/);
  assert.match(runbook, /native-labview-2026-64/);
  assert.match(runbook, /native-labview-2026-32/);
  assert.match(runbook, /The two Docker Desktop planes are mutually exclusive/i);
});

test('single-host runbook points to the authoritative commands and artifacts', () => {
  const runbook = readFile(runbookPath);

  assert.match(runbook, /node tools\/npm\/run-script\.mjs env:labview:2026:host-planes/);
  assert.match(runbook, /pwsh -NoLogo -NoProfile -File tools\/Test-DockerDesktopFastLoop\.ps1 -LaneScope linux -StepTimeoutSeconds 600/);
  assert.match(runbook, /pwsh -NoLogo -NoProfile -File tools\/Test-DockerDesktopFastLoop\.ps1 -LaneScope windows -StepTimeoutSeconds 600/);
  assert.match(runbook, /pwsh -NoLogo -NoProfile -File tools\/Test-DockerDesktopFastLoop\.ps1 -LaneScope both -StepTimeoutSeconds 600/);
  assert.match(runbook, /node tools\/npm\/run-script\.mjs history:diagnostics:show -- --ResultsRoot tests\/results\/local-parity\/windows/);
  assert.match(runbook, /labview-2026-host-plane-report\.json/);
  assert.match(runbook, /docker-runtime-fastloop-readiness\.json/);
});

test('developer guide and documentation manifest point back to the single-host runbook', () => {
  const developerGuide = readFile(developerGuidePath);
  const manifest = JSON.parse(readFile(manifestPath));
  const entries = Array.isArray(manifest) ? manifest : manifest.entries;

  assert.match(developerGuide, /docs\/SINGLE_HOST_LABVIEW_2026_PLANES\.md/);

  assert.ok(Array.isArray(entries), 'documentation manifest should expose an entries array');
  const entry = entries.find((item) => item.name === 'Host Plane Diagnostics Contracts');
  assert.ok(entry, 'documentation manifest should include the host-plane diagnostics entry');
  assert.ok(entry.files.includes('docs/SINGLE_HOST_LABVIEW_2026_PLANES.md'));
});
