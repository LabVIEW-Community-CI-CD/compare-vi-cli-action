#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runHumanGoNoGoLatest, parseArgs } from '../human-go-no-go-latest.mjs';

const repoRoot = process.cwd();

const decisionFixture = {
  schema: 'human-go-no-go-decision@v1',
  schemaVersion: '1.0.0',
  generatedAt: '2026-03-14T11:20:00.000Z',
  workflow: {
    name: 'Human Go/No-Go Feedback',
    path: '.github/workflows/human-go-no-go-feedback.yml',
  },
  target: {
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    context: 'issue/personal-982-manual-disposition-workflow',
    ref: 'issue/personal-982-manual-disposition-workflow',
    runId: '23090000001',
    issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/982',
    pullRequestUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/pull/1141',
  },
  decision: {
    value: 'nogo',
    feedback: 'Wait for the latest artifact reader before continuing implementation.',
    recordedBy: 'svelderrainruiz',
    transcribedFor: null,
  },
  links: {
    runUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23090000001',
    evidenceUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/964#issuecomment-3',
  },
  artifacts: {
    artifactName: 'human-go-no-go-decision',
    decisionPath: 'tests/results/_agent/handoff/human-go-no-go-decision.json',
    eventsPath: 'tests/results/_agent/handoff/human-go-no-go-events.ndjson',
  },
  nextIteration: {
    recommendedAction: 'revise',
    seed: 'Fetch the latest decision artifact instead of scraping comments.',
  },
};

async function loadSchema(fileName) {
  return JSON.parse(await readFile(path.join(repoRoot, 'docs', 'schemas', fileName), 'utf8'));
}

test('runHumanGoNoGoLatest resolves the latest successful run and writes a schema-valid summary', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'human-go-no-go-latest-'));
  const destinationRoot = path.join(tempRoot, 'downloads');
  const downloadReportPath = path.join(tempRoot, 'download-report.json');
  const reportPath = path.join(tempRoot, 'human-go-no-go-latest.json');

  const result = await runHumanGoNoGoLatest({
    argv: [
      'node',
      'tools/priority/human-go-no-go-latest.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--ref',
      'issue/personal-982-manual-disposition-workflow',
      '--destination-root',
      destinationRoot,
      '--download-report',
      downloadReportPath,
      '--out',
      reportPath,
    ],
    repoRoot,
    now: new Date('2026-03-14T11:30:00.000Z'),
    runGhJsonFn: (args) => {
      if (args[0] === 'run' && args[1] === 'list') {
        return [
          {
            databaseId: 23090000000,
            name: 'Human Go/No-Go Feedback',
            displayTitle: 'older go decision',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23090000000',
            headBranch: 'issue/personal-982-manual-disposition-workflow',
            headSha: 'aaaabbbb',
            event: 'workflow_dispatch',
            status: 'completed',
            conclusion: 'success',
            createdAt: '2026-03-14T11:00:00Z',
            updatedAt: '2026-03-14T11:01:00Z',
          },
          {
            databaseId: 23090000001,
            name: 'Human Go/No-Go Feedback',
            displayTitle: 'latest nogo decision',
            url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23090000001',
            headBranch: 'issue/personal-982-manual-disposition-workflow',
            headSha: 'ccccdddd',
            event: 'workflow_dispatch',
            status: 'completed',
            conclusion: 'success',
            createdAt: '2026-03-14T11:10:00Z',
            updatedAt: '2026-03-14T11:11:00Z',
          },
        ];
      }
      throw new Error(`Unexpected gh args: ${args.join(' ')}`);
    },
    downloadArtifactsFn: ({ reportPath: artifactReportPath, destinationRoot: artifactDestinationRoot }) => {
      const destination = path.join(artifactDestinationRoot, 'human-go-no-go-decision');
      fs.mkdirSync(destination, { recursive: true });
      fs.writeFileSync(
        path.join(destination, 'human-go-no-go-decision.json'),
        `${JSON.stringify(decisionFixture, null, 2)}\n`,
        'utf8',
      );
      const report = {
        status: 'pass',
        errors: [],
        downloads: [
          {
            name: 'human-go-no-go-decision',
            destination,
          },
        ],
      };
      fs.writeFileSync(artifactReportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
      return { report, reportPath: artifactReportPath };
    },
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.latestDecision.value, 'nogo');
  assert.equal(result.report.latestDecision.blocking, true);
  assert.equal(result.report.sourceRun.id, 23090000001);
  assert.equal(result.report.selection.mode, 'latest-successful-run');

  const schema = await loadSchema('human-go-no-go-latest-v1.schema.json');
  const decisionSchema = await loadSchema('human-go-no-go-decision-v1.schema.json');
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(decisionSchema, decisionSchema.$id);
  const validate = ajv.compile(schema);

  assert.equal(validate(JSON.parse(fs.readFileSync(reportPath, 'utf8'))), true, JSON.stringify(validate.errors, null, 2));
});

test('runHumanGoNoGoLatest fails closed on nogo when requested', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'human-go-no-go-block-'));
  const result = await runHumanGoNoGoLatest({
    argv: [
      'node',
      'tools/priority/human-go-no-go-latest.mjs',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--run-id',
      '23090000001',
      '--fail-on-nogo',
      '--destination-root',
      path.join(tempRoot, 'downloads'),
      '--download-report',
      path.join(tempRoot, 'download-report.json'),
      '--out',
      path.join(tempRoot, 'human-go-no-go-latest.json'),
    ],
    repoRoot,
    runGhJsonFn: () => ({
      id: 23090000001,
      name: 'Human Go/No-Go Feedback',
      display_title: 'latest nogo decision',
      html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23090000001',
      head_branch: 'issue/personal-982-manual-disposition-workflow',
      head_sha: 'ccccdddd',
      event: 'workflow_dispatch',
      status: 'completed',
      conclusion: 'success',
      created_at: '2026-03-14T11:10:00Z',
      updated_at: '2026-03-14T11:11:00Z',
    }),
    downloadArtifactsFn: ({ reportPath: artifactReportPath, destinationRoot: artifactDestinationRoot }) => {
      const destination = path.join(artifactDestinationRoot, 'human-go-no-go-decision');
      fs.mkdirSync(destination, { recursive: true });
      fs.writeFileSync(
        path.join(destination, 'human-go-no-go-decision.json'),
        `${JSON.stringify(decisionFixture, null, 2)}\n`,
        'utf8',
      );
      const report = {
        status: 'pass',
        errors: [],
        downloads: [
          {
            name: 'human-go-no-go-decision',
            destination,
          },
        ],
      };
      fs.writeFileSync(artifactReportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
      return { report, reportPath: artifactReportPath };
    },
  });

  assert.equal(result.exitCode, 2);
  assert.equal(result.report.latestDecision.blocking, true);
});

test('parseArgs rejects an empty repository when no environment fallback exists', () => {
  assert.throws(
    () => parseArgs(['node', 'tools/priority/human-go-no-go-latest.mjs', '--repo'], {}, repoRoot),
    /Missing value for --repo/,
  );
});
