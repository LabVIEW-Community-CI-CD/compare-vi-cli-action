import { ArgumentParser } from 'argparse';
import { writeFileSync } from 'node:fs';
import { createSessionIndexBuilder } from './builder.js';
import { resolveToggleManifest } from '../config/toggles.js';

const parser = new ArgumentParser({
  description: 'Session Index v2 helper'
});

parser.add_argument('--out', {
  help: 'Optional path to write the generated session-index.json (defaults to stdout)'
});

parser.add_argument('--sample', {
  help: 'Emit a sample session index with placeholder data',
  action: 'store_true'
});

parser.add_argument('--workflow', {
  help: 'Workflow name when generating real output',
  default: process.env.GITHUB_WORKFLOW || 'unknown'
});

parser.add_argument('--job', {
  help: 'Job name',
  default: process.env.GITHUB_JOB
});

const args = parser.parse_args();

function getToggleManifest() {
  try {
    const rawProfiles = (process.env.AGENT_TOGGLE_PROFILES ?? '')
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0);
    const manifest = resolveToggleManifest({
      profiles: rawProfiles.length > 0 ? rawProfiles : undefined
    });
    const digest = process.env.AGENT_TOGGLE_MANIFEST_DIGEST?.trim();
    const values: Record<string, string> = {};
    for (const [key, value] of Object.entries(manifest.toggles)) {
      const envValue = process.env[key];
      values[key] = envValue ?? value;
    }
    return {
      manifestDigest: digest && digest.length > 0 ? digest : manifest.manifestDigest,
      profiles: manifest.profiles,
      resolvedProfiles: manifest.resolvedProfiles,
      values,
      hashAlgorithm: manifest.metadata?.hashAlgorithm
    };
  } catch {
    return undefined;
  }
}

const builder = createSessionIndexBuilder();
const toggleManifest = getToggleManifest();

if (args.sample) {
  const sampleManifest = resolveToggleManifest({ profiles: ['ci-orchestrated'] });
  builder
    .setRun({
      workflow: args.workflow,
      job: args.job ?? 'sample',
      branch: 'develop',
      commit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      trigger: {
        kind: 'pull_request',
        number: 119,
        author: 'sample-user'
      }
    })
    .setEnvironment({
      runner: 'ubuntu-24.04',
      node: process.version,
      pwsh: '7.5.3',
      toggles: {
        manifestDigest: sampleManifest.manifestDigest,
        profiles: sampleManifest.profiles,
        resolvedProfiles: sampleManifest.resolvedProfiles,
        values: sampleManifest.toggles,
        hashAlgorithm: sampleManifest.metadata?.hashAlgorithm
      }
    })
    .setBranchProtection({
      status: 'warn',
      reason: 'api_forbidden',
      expected: ['Validate / lint', 'Validate / fixtures', 'Validate / session-index'],
      actual: ['Validate', 'Workflows Lint'],
      mapping: {
        path: 'tools/policy/branch-required-checks.json',
        digest: '9121da2e7b43a122c02db5adf6148f42de443d89159995fce7d035ae66745772'
      },
      notes: [
        'Branch protection query failed: Response status code does not indicate success: 403 (Forbidden).'
      ]
    })
    .setTestsSummary({
      total: 7,
      passed: 7,
      failed: 0,
      errors: 0,
      skipped: 0,
      durationSeconds: 14.75
    })
    .addTestCase({
      id: 'Watcher.BusyLoop.Tests::should exit when hang detected',
      category: 'tests/Watcher.BusyLoop.Tests.ps1',
      requirement: 'REQ-1234',
      rationale: 'Busy-loop detection must terminate the watcher within 120 seconds.',
      expectedResult: 'Watcher exits with code 2 and logs hang telemetry.',
      outcome: 'passed',
      durationMs: 1739,
      artifacts: ['tests/results/watcher-busyloop/pester-results.xml'],
      tags: ['busy-loop', 'watcher']
    })
    .addArtifact({
      name: 'pester-summary',
      path: 'tests/results/pester-summary.json',
      kind: 'summary'
    })
    .addArtifact({
      name: 'compare-report',
      path: 'tests/results/compare-report.html',
      kind: 'report',
      mimeType: 'text/html'
    })
    .addNote('Sample session index generated for demonstration.');
} else {
  builder.setRun({
    workflow: args.workflow,
    job: args.job ?? process.env.GITHUB_JOB,
    branch: process.env.GITHUB_REF_NAME,
    commit: process.env.GITHUB_SHA,
    repository: process.env.GITHUB_REPOSITORY,
    trigger: {
      kind: process.env.GITHUB_EVENT_NAME
    }
  });

  if (toggleManifest) {
    builder.setEnvironment({
      toggles: toggleManifest
    });
  }
}

const index = builder.build();
const json = JSON.stringify(index, null, 2);

if (args.out) {
  writeFileSync(args.out, json, { encoding: 'utf8' });
} else {
  process.stdout.write(json);
}
