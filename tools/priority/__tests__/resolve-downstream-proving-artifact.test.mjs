#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  buildWorkflowRunsApiPath,
  parseArgs,
  runResolveDownstreamProvingArtifact
} from '../resolve-downstream-proving-artifact.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs enforces expected source sha and supports workflow overrides', () => {
  const options = parseArgs([
    'node',
    'resolve-downstream-proving-artifact.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--workflow',
    'downstream-promotion.yml',
    '--branch',
    'develop',
    '--expected-source-sha',
    '1234567890abcdef1234567890abcdef12345678',
    '--artifact-prefix',
    'downstream-promotion-',
    '--destination-root',
    'tmp/artifacts',
    '--output',
    'tmp/report.json'
  ]);

  assert.equal(options.workflow, 'downstream-promotion.yml');
  assert.equal(options.branch, 'develop');
  assert.equal(options.expectedSourceSha, '1234567890abcdef1234567890abcdef12345678');
  assert.equal(options.artifactPrefix, 'downstream-promotion-');
  assert.equal(options.destinationRoot, 'tmp/artifacts');
  assert.equal(options.outputPath, 'tmp/report.json');
});

test('buildWorkflowRunsApiPath targets successful workflow runs on the proving branch filter', () => {
  const apiPath = buildWorkflowRunsApiPath(
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    'downstream-promotion.yml',
    { page: 2, branch: 'develop', status: 'success' }
  );

  assert.match(apiPath, /^repos\/LabVIEW-Community-CI-CD\/compare-vi-cli-action\/actions\/workflows\/downstream-promotion.yml\/runs\?/);
  assert.match(apiPath, /per_page=20/);
  assert.match(apiPath, /page=2/);
  assert.match(apiPath, /branch=develop/);
  assert.match(apiPath, /status=success/);
});

test('runResolveDownstreamProvingArtifact selects the first pass scorecard that matches the expected source sha', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-proving-selection-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const expectedSourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const result = await runResolveDownstreamProvingArtifact(
    {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      workflow: 'downstream-promotion.yml',
      branch: 'develop',
      expectedSourceSha,
      destinationRoot: path.join(tmpDir, 'artifacts'),
      outputPath: path.join(tmpDir, 'selection.json')
    },
    {
      async runGhJsonFn(args) {
        if (args[0] !== 'api') {
          throw new Error(`Unexpected command: ${args.join(' ')}`);
        }
        return {
          workflow_runs: [
            {
              id: 201,
              name: 'Downstream Promotion',
              html_url: 'https://example.test/runs/201',
              head_branch: 'develop',
              head_sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              status: 'completed',
              conclusion: 'success'
            },
            {
              id: 202,
              name: 'Downstream Promotion',
              html_url: 'https://example.test/runs/202',
              head_branch: 'develop',
              head_sha: expectedSourceSha,
              status: 'completed',
              conclusion: 'success'
            }
          ]
        };
      },
      async downloadNamedArtifactsFn({ runId, destinationRoot, reportPath }) {
        const scorecardPath = path.join(destinationRoot, 'downstream-develop-promotion-scorecard.json');
        const templateAgentVerificationReportPath = path.join(destinationRoot, 'template-agent-verification-report.json');
        const sourceCommitSha = runId === '201'
          ? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
          : expectedSourceSha;
        writeJson(scorecardPath, {
          schema: 'priority/downstream-promotion-scorecard@v1',
          gates: {
            manifestReport: {
              status: 'pass',
              targetBranch: 'downstream/develop'
            },
            feedbackReport: {
              downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
            }
          },
          summary: {
            status: 'pass',
            blockerCount: 0,
            provenance: {
              sourceCommitSha
            }
          }
        });
        writeJson(templateAgentVerificationReportPath, {
          schema: 'priority/template-agent-verification-report@v1',
          summary: {
            status: 'pass',
            blockerCount: 0,
            recommendation: 'continue-template-agent-loop'
          },
          iteration: {
            label: 'downstream promotion',
            headSha: sourceCommitSha
          },
          lane: {
            targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
            consumerRailBranch: 'downstream/develop'
          },
          verification: {
            provider: 'hosted-github-workflow',
            status: 'pass',
            runUrl: `https://example.test/runs/${runId}`
          },
          provenance: {
            templateDependency: {
              repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
              version: 'v0.1.1',
              ref: 'v0.1.1',
              cookiecutterVersion: '2.7.1'
            }
          }
        });
        writeJson(reportPath, {
          schema: 'run-artifact-download@v1',
          status: 'pass'
        });
        return {
          report: {
            status: 'pass'
          },
          reportPath
        };
      }
    }
  );

  assert.equal(result.status, 'pass');
  assert.equal(result.selected.run.id, 202);
  assert.equal(result.selected.templateAgentVerificationStatus, 'pass');
  assert.equal(result.selected.scorecardStatus, 'pass');
  assert.equal(result.selected.scorecard.sourceCommitSha, expectedSourceSha);
  assert.equal(
    path.basename(result.selected.templateAgentVerificationReportPath),
    'template-agent-verification-report.json'
  );
  assert.equal(result.selected.templateAgentVerification.matchedExpectedSourceSha, true);
  assert.equal(result.report.selected.run.id, 202);
  assert.equal(result.report.selected.scorecard.matchedExpectedSourceSha, true);
  assert.ok(fs.existsSync(result.reportPath));
});

test('runResolveDownstreamProvingArtifact fails closed when no downloaded scorecard matches the expected source sha', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-proving-selection-fail-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const result = await runResolveDownstreamProvingArtifact(
    {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      workflow: 'downstream-promotion.yml',
      branch: 'develop',
      expectedSourceSha: 'cccccccccccccccccccccccccccccccccccccccc',
      destinationRoot: path.join(tmpDir, 'artifacts'),
      outputPath: path.join(tmpDir, 'selection.json')
    },
    {
      async runGhJsonFn() {
        return {
          workflow_runs: [
            {
              id: 301,
              name: 'Downstream Promotion',
              html_url: 'https://example.test/runs/301',
              head_branch: 'develop',
              head_sha: 'dddddddddddddddddddddddddddddddddddddddd',
              status: 'completed',
              conclusion: 'success'
            }
          ]
        };
      },
      async downloadNamedArtifactsFn({ destinationRoot, reportPath }) {
        writeJson(path.join(destinationRoot, 'downstream-develop-promotion-scorecard.json'), {
          schema: 'priority/downstream-promotion-scorecard@v1',
          gates: {
            manifestReport: {
              status: 'pass',
              targetBranch: 'downstream/develop'
            },
            feedbackReport: {
              downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
            }
          },
          summary: {
            status: 'pass',
            blockerCount: 0,
            provenance: {
              sourceCommitSha: 'dddddddddddddddddddddddddddddddddddddddd'
            }
          }
        });
        writeJson(path.join(destinationRoot, 'template-agent-verification-report.json'), {
          schema: 'priority/template-agent-verification-report@v1',
          summary: {
            status: 'pass',
            blockerCount: 0,
            recommendation: 'continue-template-agent-loop'
          },
          iteration: {
            label: 'downstream promotion',
            headSha: 'dddddddddddddddddddddddddddddddddddddddd'
          },
          lane: {
            targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
            consumerRailBranch: 'downstream/develop'
          },
          verification: {
            provider: 'hosted-github-workflow',
            status: 'pass',
            runUrl: 'https://example.test/runs/301'
          },
          provenance: {
            templateDependency: {
              repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
              version: 'v0.1.1',
              ref: 'v0.1.1',
              cookiecutterVersion: '2.7.1'
            }
          }
        });
        writeJson(reportPath, {
          schema: 'run-artifact-download@v1',
          status: 'pass'
        });
        return {
          report: {
            status: 'pass'
          },
          reportPath
        };
      }
    }
  );

  assert.equal(result.status, 'fail');
  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.selected, null);
  assert.equal(result.report.candidates.length, 1);
  assert.equal(result.report.candidates[0].scorecard.matchedExpectedSourceSha, false);
  assert.equal(result.report.candidates[0].templateAgentVerification.matchedExpectedSourceSha, false);
});
