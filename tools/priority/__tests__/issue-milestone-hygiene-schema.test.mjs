#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runMilestoneHygiene, runMilestoneHygieneWithFailureReport } from '../check-issue-milestones.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function makeRunGhJson({ issues, milestones, createdMilestone }) {
  return (args) => {
    if (args[0] === 'issue' && args[1] === 'list') {
      return issues;
    }
    if (args[0] === 'api' && String(args[1]).includes('/milestones')) {
      if (args.includes('--method') && args.includes('POST')) {
        return [createdMilestone];
      }
      return milestones;
    }
    throw new Error(`Unexpected gh json invocation: ${args.join(' ')}`);
  };
}

test('issue milestone hygiene schema validates generated report and asserts labels/flags coverage', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'issue-milestone-hygiene-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'milestone-hygiene-schema-'));
  const outputPath = path.join(tmpDir, 'report.json');

  const result = await runMilestoneHygiene({
    argv: [
      '--repo',
      'example/repo',
      '--apply-default-milestone',
      '--default-milestone',
      'Program Q2',
      '--default-milestone-due-on',
      '2026-06-30T00:00:00Z',
      '--create-default-milestone',
      '--report',
      outputPath
    ],
    now: new Date('2026-03-06T12:00:00Z'),
    loadPolicyFn: async () => ({
      path: path.join(repoRoot, 'tools', 'policy', 'issue-milestone-hygiene.json'),
      required: {
        labels: ['standing-priority', 'program'],
        titlePriorityPattern: String.raw`\[(P0|P1)\]`,
        requireOpenMilestone: true
      },
      defaultMilestone: null,
      defaultMilestoneDueOn: null,
      warnOnly: false,
      createDefaultMilestone: false
    }),
    runGhJsonFn: makeRunGhJson({
      issues: [
        {
          number: 701,
          title: '[P1] milestone lane',
          milestone: null,
          labels: [{ name: 'program' }],
          url: 'https://example.test/issues/701'
        }
      ],
      milestones: [],
      createdMilestone: {
        number: 21,
        title: 'Program Q2',
        state: 'open',
        due_on: '2026-06-30T00:00:00Z'
      }
    }),
    runGhFn: () => ({ status: 0, stdout: '', stderr: '' })
  });

  assert.equal(result.exitCode, 0);

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(report.flags.createDefaultMilestone, true);
  assert.equal(report.flags.applyDefaultMilestone, true);
  assert.equal(report.execution.status, 'pass');
  assert.equal(report.policy.requiredLabels.includes('program'), true);
  assert.equal(report.reconciliations[0].triggers.includes('label:program'), true);
  assert.equal(report.summary.triggerCounts['label:program'], 1);
});

test('issue milestone hygiene schema validates generated error report when evaluation aborts early', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'issue-milestone-hygiene-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'milestone-hygiene-error-schema-'));
  const outputPath = path.join(tmpDir, 'report.json');

  const result = await runMilestoneHygieneWithFailureReport({
    argv: ['--repo', 'example/repo', '--report', outputPath],
    now: new Date('2026-03-06T12:00:00Z'),
    loadPolicyFn: async () => ({
      path: path.join(repoRoot, 'tools', 'policy', 'issue-milestone-hygiene.json'),
      required: {
        labels: ['standing-priority', 'program'],
        titlePriorityPattern: String.raw`\[(P0|P1)\]`,
        requireOpenMilestone: true
      },
      defaultMilestone: null,
      defaultMilestoneDueOn: null,
      warnOnly: false,
      createDefaultMilestone: false
    }),
    runGhJsonFn: () => {
      throw new Error('gh issue list failed: gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable.');
    }
  });

  assert.equal(result.exitCode, 1);

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.execution.status, 'error');
  assert.equal(report.summary.issueCount, 0);
});
