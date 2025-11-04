#!/usr/bin/env node
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { HookRunner, info } from './runner.mjs';

const runner = new HookRunner('pre-push');

const scriptPath = path.join('tools', 'hooks', 'scripts', 'pre-push.ps1');
info('[pre-push] Running core pre-push checks');
runner.runPwshStep('pre-push-checks', scriptPath, [], {
  env: {
    HOOKS_PRESERVE_FIXTURE_REPORT: '1',
  },
});

const fixtureReportRel = path.join('tests', 'results', '_agent', 'icon-editor', 'fixture-report.json');
const fixtureReportAbs = path.join(runner.repoRoot, fixtureReportRel);
const fixtureMeta = {
  path: fixtureReportRel.replace(/\\/g, '/'),
  exists: false,
};

if (existsSync(fixtureReportAbs)) {
  fixtureMeta.exists = true;
  const stats = statSync(fixtureReportAbs);
  fixtureMeta.sizeBytes = stats.size;
  fixtureMeta.modifiedAt = 'normalized';
  try {
    const report = JSON.parse(readFileSync(fixtureReportAbs, 'utf8'));
    if (report && Array.isArray(report.fixtureOnlyAssets)) {
      const counts = new Map();
      for (const asset of report.fixtureOnlyAssets) {
        const key = asset?.category ?? 'unknown';
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
      fixtureMeta.categoryCounts = Array.from(counts.entries())
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([category, count]) => ({ category, count }));
    }
  } catch (err) {
    fixtureMeta.parseError = err.message;
  }
} else {
  fixtureMeta.missing = true;
}

runner.environment.fixtureReport = fixtureMeta;

runner.writeSummary();

if (runner.exitCode !== 0) {
  info('[pre-push] Hook failed; inspect tests/results/_hooks/pre-push.json for details.');
} else {
  info('[pre-push] OK');
}

process.exit(runner.exitCode);
