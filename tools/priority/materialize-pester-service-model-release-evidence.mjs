#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

const repoRoot = process.cwd();
const defaultBase = path.join(repoRoot, 'tests', 'results', '_agent', 'pester-service-model');
const defaultOutputDir = path.join(defaultBase, 'release-evidence');

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    version: 'v0.1.0',
    outputDir: defaultOutputDir,
    upstreamIssue: '2069',
    forkIssue: '2078',
    forkBasisCommit: '',
    forkBasisUrl: ''
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = argv[i + 1];
    if (token === '--version') {
      options.version = next;
      i += 1;
      continue;
    }
    if (token === '--output-dir') {
      options.outputDir = path.resolve(next);
      i += 1;
      continue;
    }
    if (token === '--upstream-issue') {
      options.upstreamIssue = next;
      i += 1;
      continue;
    }
    if (token === '--fork-issue') {
      options.forkIssue = next;
      i += 1;
      continue;
    }
    if (token === '--fork-basis-commit') {
      options.forkBasisCommit = next;
      i += 1;
      continue;
    }
    if (token === '--fork-basis-url') {
      options.forkBasisUrl = next;
      i += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function runGit(args) {
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || `git ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

async function ensureFile(filePath) {
  await fs.access(filePath);
}

async function copyIntoBundle(source, bundleRoot, name = path.basename(source)) {
  const destination = path.join(bundleRoot, name);
  await fs.copyFile(source, destination);
  return destination;
}

async function main() {
  const options = parseArgs();
  await fs.mkdir(options.outputDir, { recursive: true });

  const coverageXml = path.join(defaultBase, 'coverage.xml');
  const docsLinkCheck = path.join(defaultBase, 'docs-link-check.json');
  const requirementsPath = path.join(repoRoot, 'docs', 'requirements-pester-service-model-srs.md');
  const rtmPath = path.join(repoRoot, 'docs', 'rtm-pester-service-model.csv');
  const qualityReportPath = path.join(repoRoot, 'docs', 'pester-service-model-quality-report.md');

  await Promise.all([
    ensureFile(coverageXml),
    ensureFile(docsLinkCheck),
    ensureFile(requirementsPath),
    ensureFile(rtmPath),
    ensureFile(qualityReportPath)
  ]);

  await Promise.all([
    copyIntoBundle(coverageXml, options.outputDir),
    copyIntoBundle(docsLinkCheck, options.outputDir),
    copyIntoBundle(requirementsPath, options.outputDir),
    copyIntoBundle(rtmPath, options.outputDir),
    copyIntoBundle(qualityReportPath, options.outputDir)
  ]);

  const recordPath = path.join(options.outputDir, `release-record-${options.version}.md`);
  const headSha = runGit(['rev-parse', 'HEAD']);
  const branch = runGit(['rev-parse', '--abbrev-ref', 'HEAD']);

  const lines = [
    `# Pester Service Model Release Record ${options.version}`,
    '',
    `- Baseline: ${options.version}`,
    `- Branch: ${branch}`,
    `- Commit: ${headSha}`,
    `- Upstream epic: #${options.upstreamIssue}`,
    `- Fork basis issue: #${options.forkIssue}`,
    `- Fork basis commit: ${options.forkBasisCommit || 'unspecified'}`,
    `- Fork basis reference: ${options.forkBasisUrl || 'unspecified'}`,
    '- Change control: retained fork dossier plus upstream-hosted promotion evidence',
    '- Status accounting: retained through the bundle files below',
    '',
    '## Retained Evidence',
    '',
    '- `coverage.xml`',
    '- `docs-link-check.json`',
    '- `requirements-pester-service-model-srs.md`',
    '- `rtm-pester-service-model.csv`',
    '- `pester-service-model-quality-report.md`',
    ''
  ];
  await fs.writeFile(recordPath, `${lines.join('\n')}\n`, 'utf8');

  console.log(`release_evidence_dir=${options.outputDir}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
