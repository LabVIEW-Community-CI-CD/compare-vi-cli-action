#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import {
  describeFile,
  relativeOrAbsolute,
  resolveRunContext,
  toPortablePath,
  writeJsonFile
} from './pester-service-model-provenance.mjs';

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    repoRoot: process.cwd(),
    baseDir: null,
    version: 'v0.1.0',
    outputDir: null,
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
    if (token === '--repo-root') {
      options.repoRoot = path.resolve(next);
      i += 1;
      continue;
    }
    if (token === '--base-dir') {
      options.baseDir = path.resolve(next);
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
  const repoRoot = optionsCache.repoRoot;
  const result = spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || `git ${args.join(' ')} failed`);
  }
  return result.stdout.trim();
}

const optionsCache = { repoRoot: process.cwd() };

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
  optionsCache.repoRoot = options.repoRoot;
  const defaultBase = path.join(options.repoRoot, 'tests', 'results', '_agent', 'pester-service-model');
  const baseDir = options.baseDir ?? defaultBase;
  const outputDir = options.outputDir ?? path.join(baseDir, 'release-evidence');
  await fs.mkdir(outputDir, { recursive: true });

  const coverageXml = path.join(baseDir, 'coverage.xml');
  const docsLinkCheck = path.join(baseDir, 'docs-link-check.json');
  const requirementsPath = path.join(options.repoRoot, 'docs', 'requirements-pester-service-model-srs.md');
  const comparisonPath = path.join(options.repoRoot, 'docs', 'pester-service-model-promotion-comparison.json');
  const rtmPath = path.join(options.repoRoot, 'docs', 'rtm-pester-service-model.csv');
  const qualityReportPath = path.join(options.repoRoot, 'docs', 'pester-service-model-quality-report.md');

  await Promise.all([
    ensureFile(coverageXml),
    ensureFile(docsLinkCheck),
    ensureFile(requirementsPath),
    ensureFile(comparisonPath),
    ensureFile(rtmPath),
    ensureFile(qualityReportPath)
  ]);

  await Promise.all([
    copyIntoBundle(coverageXml, outputDir),
    copyIntoBundle(docsLinkCheck, outputDir),
    copyIntoBundle(requirementsPath, outputDir),
    copyIntoBundle(comparisonPath, outputDir),
    copyIntoBundle(rtmPath, outputDir),
    copyIntoBundle(qualityReportPath, outputDir)
  ]);

  const recordPath = path.join(outputDir, `release-record-${options.version}.md`);
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
    '- `pester-service-model-promotion-comparison.json`',
    '- `rtm-pester-service-model.csv`',
    '- `pester-service-model-quality-report.md`',
    '- `release-evidence-provenance.json`',
    ''
  ];
  await fs.writeFile(recordPath, `${lines.join('\n')}\n`, 'utf8');

  const provenancePath = path.join(outputDir, 'release-evidence-provenance.json');
  const sourceInputs = await Promise.all([
    describeFile(options.repoRoot, coverageXml, { kind: 'hosted-quality-input', role: 'coverage-xml', artifactName: 'coverage.xml' }),
    describeFile(options.repoRoot, docsLinkCheck, { kind: 'hosted-quality-input', role: 'docs-link-check', artifactName: 'docs-link-check.json' }),
    describeFile(options.repoRoot, requirementsPath, { kind: 'packet-document', role: 'requirements-srs' }),
    describeFile(options.repoRoot, comparisonPath, { kind: 'packet-document', role: 'promotion-comparison' }),
    describeFile(options.repoRoot, rtmPath, { kind: 'packet-document', role: 'rtm' }),
    describeFile(options.repoRoot, qualityReportPath, { kind: 'packet-document', role: 'quality-report' })
  ]);
  const derivedOutputs = await Promise.all([
    describeFile(options.repoRoot, path.join(outputDir, 'coverage.xml'), { kind: 'release-evidence-output', role: 'coverage-xml' }),
    describeFile(options.repoRoot, path.join(outputDir, 'docs-link-check.json'), { kind: 'release-evidence-output', role: 'docs-link-check' }),
    describeFile(options.repoRoot, path.join(outputDir, 'requirements-pester-service-model-srs.md'), { kind: 'release-evidence-output', role: 'requirements-srs' }),
    describeFile(options.repoRoot, path.join(outputDir, 'pester-service-model-promotion-comparison.json'), { kind: 'release-evidence-output', role: 'promotion-comparison' }),
    describeFile(options.repoRoot, path.join(outputDir, 'rtm-pester-service-model.csv'), { kind: 'release-evidence-output', role: 'rtm' }),
    describeFile(options.repoRoot, path.join(outputDir, 'pester-service-model-quality-report.md'), { kind: 'release-evidence-output', role: 'quality-report' }),
    describeFile(options.repoRoot, recordPath, { kind: 'release-evidence-output', role: 'release-record' })
  ]);
  await writeJsonFile(provenancePath, {
    schema: 'pester-derived-provenance@v1',
    schemaVersion: '1.0.0',
    generatedAtUtc: new Date().toISOString(),
    provenanceKind: 'release-evidence',
    producer: {
      id: 'materialize-pester-service-model-release-evidence.mjs',
      version: '1.0.0'
    },
    subject: {
      id: 'pester-service-model-release-evidence',
      baselineVersion: options.version,
      upstreamIssue: options.upstreamIssue,
      forkIssue: options.forkIssue,
      forkBasisCommit: options.forkBasisCommit || null,
      forkBasisUrl: options.forkBasisUrl || null,
      bundleDir: toPortablePath(outputDir),
      bundleDirRepoPath: relativeOrAbsolute(options.repoRoot, outputDir)
    },
    runContext: resolveRunContext(options.repoRoot, 'Pester service-model release evidence'),
    sourceInputs,
    derivedOutputs
  });

  console.log(`release_evidence_dir=${outputDir}`);
  console.log(`release_evidence_provenance=${provenancePath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
