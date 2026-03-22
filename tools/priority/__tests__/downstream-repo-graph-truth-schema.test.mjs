import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runDownstreamRepoGraphTruth } from '../downstream-repo-graph-truth.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('downstream repo graph truth report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-repo-graph-schema-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const outputPath = path.join(tmpDir, 'truth.json');

  writeJson(policyPath, {
    schema: 'priority/downstream-repo-graph-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositories: [
      {
        id: 'compare',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        kind: 'supervisor',
        roles: [
          {
            id: 'compare-producer-lineage',
            role: 'producer-lineage',
            branch: 'develop',
            localRefAlias: 'upstream/develop',
            required: true
          }
        ]
      }
    ]
  });

  const { report } = await runDownstreamRepoGraphTruth(
    {
      repoRoot: tmpDir,
      policyPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      resolveRepoSlugFn: (repo) => repo,
      runGhJsonFn: () => ({ commit: { sha: 'cmp123' } })
    }
  );

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'downstream-repo-graph-truth-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

test('checked-in downstream repo graph policy matches schema', () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const policy = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'tools', 'policy', 'downstream-repo-graph.json'), 'utf8')
  );
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'downstream-repo-graph-policy-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(policy), true, JSON.stringify(validate.errors, null, 2));
});
