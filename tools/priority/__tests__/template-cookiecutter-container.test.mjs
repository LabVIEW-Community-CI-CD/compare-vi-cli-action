#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  buildContainerName,
  buildCookiecutterPythonScript,
  buildTemplateCookiecutterContainerPlan,
  parseArgs,
  resolveContainerUser,
  runTemplateCookiecutterContainer,
  slugifySegment
} from '../template-cookiecutter-container.mjs';

test('parseArgs captures helper overrides and explicit dry-run flags', () => {
  const parsed = parseArgs([
    'node',
    'template-cookiecutter-container.mjs',
    '--policy-path',
    'tools/policy/template-dependency.json',
    '--output',
    'tests/results/_agent/template-cookiecutter/template-cookiecutter-container.json',
    '--workspace-root',
    'E:\\comparevi-template-consumers',
    '--lane-id',
    'issue/origin-1743-template-cookiecutter-conveyor',
    '--run-id',
    'run-1743',
    '--context-file',
    'tests/fixtures/cookiecutter/template-context.json',
    '--container-image',
    'comparevi-tools:cookiecutter',
    '--dry-run',
    '--no-fail-on-error'
  ]);

  assert.equal(parsed.policyPath, 'tools/policy/template-dependency.json');
  assert.equal(parsed.outputPath, 'tests/results/_agent/template-cookiecutter/template-cookiecutter-container.json');
  assert.equal(parsed.workspaceRoot, 'E:\\comparevi-template-consumers');
  assert.equal(parsed.laneId, 'issue/origin-1743-template-cookiecutter-conveyor');
  assert.equal(parsed.runId, 'run-1743');
  assert.equal(parsed.contextFilePath, 'tests/fixtures/cookiecutter/template-context.json');
  assert.equal(parsed.containerImage, 'comparevi-tools:cookiecutter');
  assert.equal(parsed.dryRun, true);
  assert.equal(parsed.failOnError, false);
});

test('build helpers produce deterministic container and workspace identities', () => {
  assert.equal(slugifySegment('Issue/Origin 1743: Template Cookiecutter!'), 'issue-origin-1743-template-cookiecutter');
  assert.equal(slugifySegment('', 'fallback-name'), 'fallback-name');

  const policy = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'), 'utf8'));
  assert.equal(buildContainerName(policy, 'issue/origin-1743-template-cookiecutter-conveyor', 'run-1743'), 'comparevi-template-issue-origin-1743-template-cookiecutter-conveyor-run-1743');
  const planA = buildTemplateCookiecutterContainerPlan(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      workspaceRoot: 'C:\\comparevi-template-consumers',
      laneId: 'issue/origin-1743-template-cookiecutter-conveyor',
      runId: 'run-1743',
      context: {
        template_name: 'LabviewGitHubCiTemplate',
        version: 'v0.1.0'
      }
    },
    {
      now: new Date('2026-03-21T19:00:00.000Z'),
      uniqueSuffixFn: () => 'abc123',
      platform: 'win32'
    }
  );
  const planB = buildTemplateCookiecutterContainerPlan(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      workspaceRoot: 'C:\\comparevi-template-consumers',
      laneId: 'issue/origin-1743-template-cookiecutter-conveyor',
      runId: 'run-1743b',
      context: {
        template_name: 'LabviewGitHubCiTemplate',
        version: 'v0.1.0'
      }
    },
    {
      now: new Date('2026-03-21T19:00:00.000Z'),
      uniqueSuffixFn: () => 'def456',
      platform: 'win32'
    }
  );

  assert.equal(planA.policy.schema, 'priority/template-dependency@v1');
  assert.equal(planA.checkout, 'v0.1.0');
  assert.equal(planA.containerImage, policy.container.image);
  assert.equal(planA.policy.effectiveContainerImage, undefined);
  assert.match(planA.containerName, /^comparevi-template-issue-origin-1743-template-cookiecutter-conveyor-run-1743$/);
  assert.match(planA.hostRunRoot, /issue-origin-1743-template-cookiecutter-conveyor[\\/]+run-1743$/);
  assert.match(planA.containerWorkspaceRoot, /\/workspace\/issue-origin-1743-template-cookiecutter-conveyor\/run-1743$/);
  assert.match(planA.dockerArgs.join(' '), /from cookiecutter\.main import cookiecutter/);
  assert.match(planA.dockerArgs.join(' '), /checkout = "v0\.1\.0"/);
  assert.equal(planA.containerUser, null);
  assert.notEqual(planA.containerName, planB.containerName);
  assert.notEqual(planA.hostRunRoot, planB.hostRunRoot);
});

test('build helpers default to the checked-in deterministic template context', () => {
  const plan = buildTemplateCookiecutterContainerPlan(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      workspaceRoot: 'C:\\comparevi-template-consumers',
      laneId: 'logical-lane-03',
      runId: 'template-proof'
    },
    {
      now: new Date('2026-03-21T19:00:00.000Z'),
      uniqueSuffixFn: () => 'abc123',
      platform: 'win32'
    }
  );

  assert.equal(plan.policy.rendering.defaultContextPath, 'tests/fixtures/cookiecutter/template-context.json');
  assert.equal(plan.context.repo_slug, 'comparevi-template-consumer');
  assert.equal(plan.context.github_owner, 'LabVIEW-Community-CI-CD');
});

test('resolveContainerUser maps POSIX hosts and skips Windows hosts', () => {
  assert.equal(resolveContainerUser('win32', { getuid: () => 1001, getgid: () => 121 }), null);
  assert.equal(resolveContainerUser('linux', { getuid: () => 1001, getgid: () => 121 }), '1001:121');
  assert.equal(resolveContainerUser('linux', {}), null);
});

test('build helpers project host uid/gid onto POSIX docker runs', () => {
  const plan = buildTemplateCookiecutterContainerPlan(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      workspaceRoot: '/tmp/comparevi-template-consumers',
      laneId: 'cookiecutter-bootstrap-linux',
      runId: 'run-1743',
      context: {
        template_name: 'LabviewGitHubCiTemplate',
        version: 'v0.1.0'
      }
    },
    {
      now: new Date('2026-03-21T19:00:00.000Z'),
      uniqueSuffixFn: () => 'abc123',
      platform: 'linux',
      currentProcess: {
        getuid: () => 1001,
        getgid: () => 121
      }
    }
  );

  assert.equal(plan.containerUser, '1001:121');
  assert.match(plan.dockerArgs.join(' '), /--user 1001:121/);
});

test('buildCookiecutterPythonScript wires the pinned checkout and deterministic context', () => {
  const script = buildCookiecutterPythonScript({
    templateRepositoryUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate.git',
    templateDirectory: null,
    checkout: 'v0.1.0',
    outputDir: '/workspace/template-cookiecutter/run-1/output',
    context: {
      pack_slug: 'template-cookiecutter',
      pack_id: 'template-cookiecutter-v1'
    }
  });

  assert.match(script.script, /from cookiecutter\.main import cookiecutter/);
  assert.match(script.script, /checkout = "v0\.1\.0"/);
  assert.match(script.script, /"overwrite_if_exists": True/);
  assert.match(script.script, /COMPAREVI_TEMPLATE_EXTRA_CONTEXT_JSON/);
  assert.equal(script.contextJson.includes('template-cookiecutter-v1'), true);
});

test('runTemplateCookiecutterContainer writes a receipt and captures the spawned docker command', () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'template-cookiecutter-container-'));
  const outputPath = path.join(tempRoot, 'receipt.json');
  const contextFilePath = path.join(tempRoot, 'context.json');
  fs.writeFileSync(
    contextFilePath,
    `${JSON.stringify({
      pack_slug: 'template-cookiecutter',
      pack_id: 'template-cookiecutter-v1',
      template_name: 'LabviewGitHubCiTemplate'
    }, null, 2)}\n`,
    'utf8'
  );

  const calls = [];
  const { plan, receipt } = runTemplateCookiecutterContainer(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      outputPath,
      workspaceRoot: 'C:\\comparevi-template-consumers',
      laneId: 'issue/origin-1743-template-cookiecutter-conveyor',
      runId: 'run-1743',
      contextFilePath,
      containerImage: 'comparevi-tools:cookiecutter',
      failOnError: true
    },
    {
      now: new Date('2026-03-21T19:10:00.000Z'),
      uniqueSuffixFn: () => 'abc123',
      platform: 'win32',
      spawnSyncFn: (command, args, options) => {
        calls.push({ command, args, options });
        return {
          status: 0,
          stdout: `${JSON.stringify({
            schema: 'comparevi-cookiecutter-run@v1',
            project_dir: '/workspace/issue-origin-1743-template-cookiecutter-conveyor/run-1743/output/LabviewGitHubCiTemplate'
          })}\n`,
          stderr: ''
        };
      }
    }
  );

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, 'docker');
  assert.match(calls[0].args.join(' '), /--name comparevi-template-issue-origin-1743-template-cookiecutter-conveyor-run-1743/);
  assert.match(calls[0].args.join(' '), /comparevi-tools:cookiecutter/);
  assert.match(calls[0].args.join(' '), /COMPAREVI_TEMPLATE_CHECKOUT=v0\.1\.0/);
  assert.match(calls[0].args.join(' '), /COMPAREVI_TEMPLATE_EXTRA_CONTEXT_JSON=/);
  assert.match(calls[0].args.join(' '), /python3/);
  assert.match(calls[0].args.join(' '), /from cookiecutter\.main import cookiecutter/);
  assert.equal(receipt.status, 'pass');
  assert.equal(receipt.policy.effectiveContainerImage, 'comparevi-tools:cookiecutter');
  assert.equal(receipt.result.projectDir, '/workspace/issue-origin-1743-template-cookiecutter-conveyor/run-1743/output/LabviewGitHubCiTemplate');
  assert.equal(receipt.run.containerUser, null);
  assert.equal(fs.existsSync(outputPath), true);
  const persisted = JSON.parse(fs.readFileSync(outputPath, 'utf8'));
  assert.equal(persisted.run.uniqueWorkspaceRoot, true);
  assert.equal(persisted.run.uniqueContainerName, true);
  assert.equal(persisted.run.contextSource, 'file');
  assert.equal(persisted.run.contextFilePath, contextFilePath);
  assert.equal(plan.checkout, 'v0.1.0');
});

test('dry-run mode writes a receipt without invoking docker', () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'template-cookiecutter-dry-run-'));
  const outputPath = path.join(tempRoot, 'receipt.json');
  let spawnCalled = false;

  const { receipt } = runTemplateCookiecutterContainer(
    {
      policyPath: path.join(process.cwd(), 'tools', 'policy', 'template-dependency.json'),
      outputPath,
      workspaceRoot: 'C:\\comparevi-template-consumers',
      laneId: 'issue/origin-1743-template-cookiecutter-conveyor',
      runId: 'run-1743',
      dryRun: true
    },
    {
      now: new Date('2026-03-21T19:10:00.000Z'),
      uniqueSuffixFn: () => 'abc123',
      platform: 'win32',
      spawnSyncFn: () => {
        spawnCalled = true;
        return {
          status: 0,
          stdout: '',
          stderr: ''
        };
      }
    }
  );

  assert.equal(spawnCalled, false);
  assert.equal(receipt.status, 'dry-run');
  assert.equal(receipt.run.contextSource, 'policy-default-file');
  assert.equal(fs.existsSync(outputPath), true);
});
