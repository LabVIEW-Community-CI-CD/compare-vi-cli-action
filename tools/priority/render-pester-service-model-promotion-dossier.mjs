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
    releaseEvidenceDir: null,
    outputPath: null,
    upstreamIssue: '2069',
    forkIssue: '2078',
    forkBasisCommit: '',
    forkBasisUrl: ''
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = argv[i + 1];
    if (token === '--upstream-issue') {
      options.upstreamIssue = next;
      i += 1;
      continue;
    }
    if (token === '--repo-root') {
      options.repoRoot = path.resolve(next);
      i += 1;
      continue;
    }
    if (token === '--release-evidence-dir') {
      options.releaseEvidenceDir = path.resolve(next);
      i += 1;
      continue;
    }
    if (token === '--output') {
      options.outputPath = path.resolve(next);
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

async function main() {
  const options = parseArgs();
  optionsCache.repoRoot = options.repoRoot;
  const baseDir = path.join(options.repoRoot, 'tests', 'results', '_agent', 'pester-service-model');
  const releaseEvidenceDir = options.releaseEvidenceDir ?? path.join(baseDir, 'release-evidence');
  const outputPath = options.outputPath ?? path.join(releaseEvidenceDir, 'promotion-dossier.md');
  const coveragePath = path.join(releaseEvidenceDir, 'coverage.xml');
  const docsPath = path.join(releaseEvidenceDir, 'docs-link-check.json');
  const comparisonBundlePath = path.join(releaseEvidenceDir, 'pester-service-model-promotion-comparison.json');
  const requirementsPath = path.join(options.repoRoot, 'docs', 'requirements-pester-service-model-srs.md');
  const rtmPath = path.join(options.repoRoot, 'docs', 'rtm-pester-service-model.csv');
  const qualityReportPath = path.join(options.repoRoot, 'docs', 'pester-service-model-quality-report.md');
  const releaseProvenancePath = path.join(releaseEvidenceDir, 'release-evidence-provenance.json');
  const rtm = await fs.readFile(rtmPath, 'utf8');
  const comparison = JSON.parse(await fs.readFile(comparisonBundlePath, 'utf8'));

  await fs.mkdir(releaseEvidenceDir, { recursive: true });
  await Promise.all([ensureFile(coveragePath), ensureFile(docsPath), ensureFile(comparisonBundlePath), ensureFile(releaseProvenancePath)]);

  const comparisonLines = [];
  for (const item of comparison.comparisons ?? []) {
    comparisonLines.push(`### ${item.packId}`);
    comparisonLines.push('');
    comparisonLines.push(`- Comparison: \`${item.comparisonId}\``);
    comparisonLines.push(`- Representativeness: ${item.representativeness}`);
    comparisonLines.push(`- Requirement coverage: ${(item.requirementCoverage ?? []).join(', ')}`);
    comparisonLines.push(`- Baseline: [run ${item.baseline.runId}](${item.baseline.runUrl}) on \`${item.baseline.ref}\` (${item.baseline.conclusion}; pack=\`${item.baseline.packIdentity}\`)`);
    comparisonLines.push(`- Candidate: [run ${item.candidate.runId}](${item.candidate.runUrl}) on \`${item.candidate.ref}\` (${item.candidate.conclusion}; pack=\`${item.candidate.packIdentity}\`)`);
    comparisonLines.push(`- Decision: ${item.decision}`);
    comparisonLines.push(`- Next action: ${item.nextAction}`);
    if ((item.observedDeltas ?? []).length > 0) {
      comparisonLines.push('- Observed deltas:');
      for (const delta of item.observedDeltas) {
        comparisonLines.push(`  - ${delta}`);
      }
    }
    comparisonLines.push('');
  }

  const lines = [
    '# Pester Service Model Promotion Dossier',
    '',
    `- Upstream slice commit: ${runGit(['rev-parse', 'HEAD'])}`,
    `- Upstream epic: \`#${options.upstreamIssue}\``,
    `- Fork basis issue: \`#${options.forkIssue}\``,
    `- Fork basis commit: ${options.forkBasisCommit || 'unspecified'}`,
    `- Fork basis reference: ${options.forkBasisUrl || 'unspecified'}`,
    '- Hosted promotion evidence retained: yes',
    '',
    '## Promotion Basis',
    '',
    '- This upstream slice is derived from the retained fork promotion dossier and requirement packet.',
    '- It promotes only hosted quality and release-evidence surfaces.',
    '- It does not change the self-hosted execution boundary or required gate ownership.',
    '',
    '## Requirement Traceability',
    '',
    '```csv',
    rtm.trim(),
    '```',
    '',
    '## Promotion Evidence',
    '',
    '- the service-model requirement packet is now present on the upstream slice',
    '- hosted packet quality retains `coverage.xml`',
    '- hosted docs integrity retains `docs-link-check.json`',
    '- the release-evidence bundle retains the upstream quality report and RTM alongside the evidence artifacts',
    '- the release-evidence bundle retains `pester-service-model-promotion-comparison.json` for requirement-to-run comparison evidence',
    '- provenance is retained in `release-evidence-provenance.json` and `promotion-dossier-provenance.json`',
    '',
    '## Representative Pack Comparisons',
    '',
    `- Decision state: ${comparison.decisionState}`,
    `- Summary: ${comparison.summary}`,
    '',
    ...comparisonLines,
    '',
    '## Minimal Upstream Slice',
    '',
    '1. Keep the slice hosted-only: quality, packet docs, and retained promotion evidence.',
    '2. Re-prove the mounted slice on the upstream integration rail before widening self-hosted behavior.',
    '3. Use this dossier to justify the next service-model promotion step under `#2069`.',
    ''
  ];

  await fs.writeFile(outputPath, `${lines.join('\n')}\n`, 'utf8');
  const releaseRecordPaths = (await fs.readdir(releaseEvidenceDir))
    .filter((entry) => /^release-record-.*\.md$/.test(entry))
    .sort()
    .map((entry) => path.join(releaseEvidenceDir, entry));
  const provenanceOutputPath = path.join(releaseEvidenceDir, 'promotion-dossier-provenance.json');
  const sourceInputs = await Promise.all([
    describeFile(options.repoRoot, coveragePath, { kind: 'release-evidence-input', role: 'coverage-xml' }),
    describeFile(options.repoRoot, docsPath, { kind: 'release-evidence-input', role: 'docs-link-check' }),
    describeFile(options.repoRoot, requirementsPath, { kind: 'release-evidence-input', role: 'requirements-srs' }),
    describeFile(options.repoRoot, comparisonBundlePath, { kind: 'release-evidence-input', role: 'promotion-comparison' }),
    describeFile(options.repoRoot, rtmPath, { kind: 'release-evidence-input', role: 'rtm' }),
    describeFile(options.repoRoot, qualityReportPath, { kind: 'release-evidence-input', role: 'quality-report' }),
    describeFile(options.repoRoot, releaseProvenancePath, { kind: 'release-evidence-input', role: 'release-evidence-provenance' }),
    ...releaseRecordPaths.map((filePath, index) => describeFile(options.repoRoot, filePath, { kind: 'release-evidence-input', role: `release-record-${index + 1}` }))
  ]);
  const derivedOutputs = await Promise.all([
    describeFile(options.repoRoot, outputPath, { kind: 'promotion-output', role: 'promotion-dossier' })
  ]);
  await writeJsonFile(provenanceOutputPath, {
    schema: 'pester-derived-provenance@v1',
    schemaVersion: '1.0.0',
    generatedAtUtc: new Date().toISOString(),
    provenanceKind: 'promotion-dossier',
    producer: {
      id: 'render-pester-service-model-promotion-dossier.mjs',
      version: '1.0.0'
    },
    subject: {
      id: 'pester-service-model-promotion-dossier',
      upstreamIssue: options.upstreamIssue,
      forkIssue: options.forkIssue,
      forkBasisCommit: options.forkBasisCommit || null,
      forkBasisUrl: options.forkBasisUrl || null,
      releaseEvidenceDir: toPortablePath(releaseEvidenceDir),
      releaseEvidenceDirRepoPath: relativeOrAbsolute(options.repoRoot, releaseEvidenceDir)
    },
    runContext: resolveRunContext(options.repoRoot, 'Pester service-model release evidence'),
    sourceInputs,
    derivedOutputs
  });
  console.log(`promotion_dossier=${outputPath}`);
  console.log(`promotion_dossier_provenance=${provenanceOutputPath}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
