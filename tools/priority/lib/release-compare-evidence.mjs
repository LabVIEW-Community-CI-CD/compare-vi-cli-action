#!/usr/bin/env node

const DEFAULT_WORKFLOWS = [
  { file: 'validate.yml', key: 'validate' },
  { file: 'fixture-drift.yml', key: 'fixture-drift' }
];

export async function collectBlockingCompareEvidence({
  repoSlug,
  branch,
  ghJsonFn,
  workflows = DEFAULT_WORKFLOWS
}) {
  if (!repoSlug) {
    throw new Error('Repository slug is required for compare-evidence checks.');
  }
  if (!branch) {
    throw new Error('Branch is required for compare-evidence checks.');
  }
  if (typeof ghJsonFn !== 'function') {
    throw new Error('ghJsonFn is required for compare-evidence checks.');
  }

  const evidence = [];
  for (const workflow of workflows) {
    const runs = await ghJsonFn([
      'run',
      'list',
      '--repo',
      repoSlug,
      '--workflow',
      workflow.file,
      '--branch',
      branch,
      '--limit',
      '1',
      '--json',
      'databaseId,status,conclusion,url,displayTitle,headBranch,createdAt'
    ]);

    if (!Array.isArray(runs) || runs.length === 0) {
      throw new Error(`Missing required compare evidence run for ${workflow.file} on ${branch}.`);
    }

    const latest = runs[0] ?? {};
    const status = String(latest.status ?? '').toLowerCase();
    const conclusion = String(latest.conclusion ?? '').toLowerCase();
    if (status !== 'completed' || conclusion !== 'success') {
      throw new Error(
        `Compare evidence workflow ${workflow.file} is not green (status=${latest.status ?? 'unknown'}, conclusion=${latest.conclusion ?? 'unknown'}).`
      );
    }

    const runId = Number(latest.databaseId);
    if (!Number.isFinite(runId) || runId <= 0) {
      throw new Error(`Compare evidence workflow ${workflow.file} returned invalid run id.`);
    }

    const artifactListing = await ghJsonFn([
      'api',
      `repos/${repoSlug}/actions/runs/${runId}/artifacts`
    ]);

    const artifacts = Array.isArray(artifactListing?.artifacts) ? artifactListing.artifacts : [];
    if (artifacts.length === 0) {
      throw new Error(`Compare evidence workflow ${workflow.file} has no artifacts attached.`);
    }

    evidence.push({
      key: workflow.key,
      workflow: workflow.file,
      runId,
      runUrl: latest.url ?? null,
      headBranch: latest.headBranch ?? null,
      createdAt: latest.createdAt ?? null,
      artifacts: artifacts.map((artifact) => ({
        name: artifact?.name ?? null,
        sizeInBytes: Number(artifact?.sizeInBytes ?? 0)
      }))
    });
  }

  return evidence;
}
