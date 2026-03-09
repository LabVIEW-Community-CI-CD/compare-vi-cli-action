import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const libPath = path.join(repoRoot, 'dist', 'tools', 'cli', 'github-metadata-lib.js');
const metadataLib = await import(pathToFileURL(libPath).href);

function makeIssue() {
  return {
    contentType: 'Issue',
    id: 'ISSUE_TARGET',
    url: 'https://github.com/example/repo/issues/949',
    number: 949,
    title: 'Metadata helper',
    repository: 'example/repo',
    assignees: [],
    reviewers: [],
    milestone: null,
    issueType: null,
    parentIssue: null,
    subIssues: [],
  };
}

function makeRunGhJson(target) {
  const issueTypes = [{ id: 'IT_FEATURE', name: 'Feature' }];
  const milestones = [{ id: 'MS_Q2', title: 'LabVIEW CI Platform v1 (2026Q2)', number: 2, state: 'OPEN' }];
  return (args) => {
    const parseGraphqlArgs = () => {
      let query = '';
      const variables = {};
      for (let index = 0; index < args.length; index += 1) {
        const token = args[index];
        if ((token === '-f' || token === '-F') && index + 1 < args.length) {
          const assignment = args[index + 1];
          const separator = assignment.indexOf('=');
          if (separator >= 0) {
            const key = assignment.slice(0, separator);
            const value = assignment.slice(separator + 1);
            if (key === 'query') {
              query = value;
            } else {
              variables[key] = value;
            }
          }
          index += 1;
        }
      }
      return { query, variables };
    };

    const { query } = parseGraphqlArgs();
    if (query.includes('resource(url: $url)')) {
      return {
        data: {
          resource: {
            __typename: 'Issue',
            id: target.id,
            url: target.url,
            number: target.number,
            title: target.title,
            repository: {
              nameWithOwner: target.repository,
              name: 'repo',
              owner: { login: 'example' },
            },
            assignees: { nodes: [] },
            milestone: null,
            issueType: null,
            parent: null,
            subIssues: { totalCount: 0, nodes: [] },
          },
        },
      };
    }
    if (query.includes('repository(owner: $owner, name: $name)')) {
      return {
        data: {
          repository: {
            nameWithOwner: target.repository,
            issueTypes: { nodes: issueTypes },
            milestones: { nodes: milestones },
          },
        },
      };
    }
    throw new Error(`Unexpected gh invocation: ${args.join(' ')}`);
  };
}

test('github metadata apply report schema validates a generated dry-run report', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'github-intake-metadata-apply-report-v1.schema.json');
  const schema = JSON.parse(await fs.readFile(schemaPath, 'utf8'));
  const target = makeIssue();
  const result = metadataLib.runMetadataApply({
    argv: [
      '--url', target.url,
      '--dry-run',
      '--issue-type', 'Feature',
      '--milestone', '2',
      '--out', 'tests/results/_agent/issue/github-metadata-schema-report.json',
    ],
    now: new Date('2026-03-09T18:15:00Z'),
    runGhJsonFn: makeRunGhJson(target),
  });

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(result.report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(result.report.schema, 'github-intake/metadata-apply-report@v1');
  assert.equal(result.report.execution.status, 'planned');
});
