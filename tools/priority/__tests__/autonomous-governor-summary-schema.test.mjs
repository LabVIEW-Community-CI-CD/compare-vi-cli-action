import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { runAutonomousGovernorSummary } from '../autonomous-governor-summary.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function toGlobPath(filePath) {
  return path.resolve(filePath).replace(/\\/g, '/');
}

function resolveValidatorRepoRoot(repoRoot) {
  const localValidatorOk =
    fs.existsSync(path.join(repoRoot, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'ajv', 'package.json')) &&
    fs.existsSync(path.join(repoRoot, 'node_modules', 'argparse', 'package.json'));
  if (localValidatorOk) {
    return repoRoot;
  }
  const candidates = [
    path.resolve(repoRoot, '..', 'compare-monitoring-canonical'),
    path.resolve(repoRoot, '..', '1843-wake-lifecycle-state-machine')
  ];
  return (
    candidates.find(
      (candidate) =>
        fs.existsSync(path.join(candidate, 'dist', 'tools', 'schemas', 'validate-json.js')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'ajv', 'package.json')) &&
        fs.existsSync(path.join(candidate, 'node_modules', 'argparse', 'package.json'))
    ) || repoRoot
  );
}

function runSchemaValidate(repoRoot, schemaPath, dataPath) {
  const validatorRepoRoot = resolveValidatorRepoRoot(repoRoot);
  execFileSync('node', ['dist/tools/schemas/validate-json.js', '--schema', toGlobPath(schemaPath), '--data', toGlobPath(dataPath)], {
    cwd: validatorRepoRoot,
    stdio: 'pipe'
  });
}

test('autonomous governor summary report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'governor-summary-schema-'));

  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 11
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json'), {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        supervisionState: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  });
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json'), {
    schema: 'agent-handoff/monitoring-mode-v1',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    compare: {
      queueState: { status: 'queue-empty', detail: 'queue-empty', ready: true },
      continuity: { status: 'maintained', detail: 'safe-idle', ready: true }
    },
    summary: {
      status: 'active',
      futureAgentAction: 'future-agent-may-pivot',
      wakeConditionCount: 0
    }
  });

  const outputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'autonomous-governor-summary.json');
  const { report } = await runAutonomousGovernorSummary({ repoRoot: tmpDir, outputPath });

  runSchemaValidate(repoRoot, path.join(repoRoot, 'docs', 'schemas', 'autonomous-governor-summary-report-v1.schema.json'), outputPath);
  assert.equal(report.schema, 'priority/autonomous-governor-summary-report@v1');
});
