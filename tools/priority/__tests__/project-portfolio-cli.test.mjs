import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const scriptPath = path.join(repoRoot, 'dist', 'tools', 'cli', 'project-portfolio.js');

async function writeJson(filePath, value) {
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function runCli(args, options = {}) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: {
      ...process.env,
      ...(options.env ?? {}),
    },
  });
}

function buildConfig({
  fieldNames = {},
  itemUrl = 'https://github.com/example/repo/issues/1',
  status = 'Todo',
} = {}) {
  return {
    schema: 'project-portfolio-config@v1',
    owner: 'example-owner',
    number: 7,
    title: 'Example Portfolio',
    shortDescription: 'Example description',
    readme: 'Example readme',
    public: false,
    allowAdditionalItems: false,
    repositories: ['example/repo'],
    fieldCatalog: {
      status: { name: fieldNames.status ?? 'Status', options: ['Todo', 'In Progress'] },
      program: { name: fieldNames.program ?? 'Program', options: ['Shared Infra'] },
      phase: { name: fieldNames.phase ?? 'Phase', options: ['Policy'] },
      environmentClass: { name: fieldNames.environmentClass ?? 'Environment Class', options: ['Infra'] },
      blockingSignal: { name: fieldNames.blockingSignal ?? 'Blocking Signal', options: ['Scope'] },
      evidenceState: { name: fieldNames.evidenceState ?? 'Evidence State', options: ['Ready'] },
      portfolioTrack: { name: fieldNames.portfolioTrack ?? 'Portfolio Track', options: ['Agent UX'] },
    },
    items: [
      {
        url: itemUrl,
        status,
        program: 'Shared Infra',
        phase: 'Policy',
        environmentClass: 'Infra',
        blockingSignal: 'Scope',
        evidenceState: 'Ready',
        portfolioTrack: 'Agent UX',
      },
    ],
  };
}

function buildView({ itemCount = 1 } = {}) {
  return {
    id: 'PVT_example',
    number: 7,
    title: 'Example Portfolio',
    shortDescription: 'Example description',
    readme: 'Example readme',
    public: false,
    url: 'https://github.com/orgs/example/projects/7',
    items: { totalCount: itemCount },
    fields: { totalCount: 7 },
    owner: { login: 'example-owner', type: 'Organization' },
  };
}

function buildFields(fieldNames = {}, optionOverrides = {}) {
  return {
    totalCount: 7,
    fields: [
      {
        id: 'status-field',
        name: fieldNames.status ?? 'Status',
        type: 'ProjectV2SingleSelectField',
        options: [
          { id: 'status-todo', name: 'Todo' },
          { id: 'status-progress', name: optionOverrides.status ?? 'In Progress' },
        ],
      },
      {
        id: 'program-field',
        name: fieldNames.program ?? 'Program',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'program-shared', name: 'Shared Infra' }],
      },
      {
        id: 'phase-field',
        name: fieldNames.phase ?? 'Phase',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'phase-policy', name: 'Policy' }],
      },
      {
        id: 'environment-field',
        name: fieldNames.environmentClass ?? 'Environment Class',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'environment-infra', name: 'Infra' }],
      },
      {
        id: 'blocking-field',
        name: fieldNames.blockingSignal ?? 'Blocking Signal',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'blocking-scope', name: 'Scope' }],
      },
      {
        id: 'evidence-field',
        name: fieldNames.evidenceState ?? 'Evidence State',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'evidence-ready', name: 'Ready' }],
      },
      {
        id: 'track-field',
        name: fieldNames.portfolioTrack ?? 'Portfolio Track',
        type: 'ProjectV2SingleSelectField',
        options: [{ id: 'track-agent', name: 'Agent UX' }],
      },
    ],
  };
}

function buildFakeGhState({
  targetUrl,
  resourceId,
  title,
  body = null,
  fields,
  nextAddedItemId,
  existingItemId = null,
  existingItemFieldValues = {},
  resourceType = 'Issue',
  linkedIssueResources = [],
}) {
  const fieldMap = {};
  const optionMap = {};
  for (const field of fields.fields) {
    fieldMap[field.id] = field.name;
    for (const option of field.options ?? []) {
      optionMap[option.id] = option.name;
    }
  }

  return {
    resources: {
      [targetUrl]: {
        __typename: resourceType,
        id: resourceId,
        url: targetUrl,
        title,
        body,
        repository: {
          nameWithOwner: 'example/repo',
        },
        projectItems: existingItemId
          ? [
              {
                id: existingItemId,
                projectId: 'PVT_example',
              },
            ]
          : [],
        closingIssuesReferences: linkedIssueResources,
      },
    },
    fieldMap,
    optionMap,
    itemFields: existingItemId
      ? {
          [existingItemId]: Object.fromEntries(
            Object.entries(existingItemFieldValues).map(([fieldName, value]) => {
              const optionId = Object.entries(optionMap).find(([, optionName]) => optionName === value)?.[0] ?? null;
              return [fieldName, { value, optionId }];
            }),
          ),
        }
      : {},
    nextAddedItemId,
  };
}

async function writeFakeGhHarness(tempRoot, state) {
  const statePath = path.join(tempRoot, 'fake-gh-state.json');
  const scriptPath = path.join(tempRoot, 'fake-gh.mjs');
  await writeJson(statePath, state);
  await writeFile(scriptPath, `
import { readFileSync, writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const statePath = process.env.FAKE_GH_STATE_PATH;
const state = JSON.parse(readFileSync(statePath, 'utf8'));
state.calls ??= [];
state.addCalls ??= [];
state.updateCalls ??= [];
state.calls.push(args);

function saveAndPrint(payload) {
  writeFileSync(statePath, JSON.stringify(state, null, 2) + '\\n', 'utf8');
  process.stdout.write(JSON.stringify(payload));
}

function parseGraphqlArgs(argv) {
  let query = '';
  const variables = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if ((token === '-f' || token === '-F') && index + 1 < argv.length) {
      const assignment = argv[index + 1];
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
}

function extractUpdateAliases(query) {
  return [...query.matchAll(/([A-Za-z0-9_]+)[ \\t\\r\\n]*:[ \\t\\r\\n]*updateProjectV2ItemFieldValue/g)].map((match) => match[1]);
}

function serializeProjectItems(resource) {
  return (resource.projectItems ?? []).map((item) => {
    const itemFields = state.itemFields?.[item.id] ?? {};
    const nodes = Object.entries(itemFields).map(([fieldName, fieldState]) => ({
      __typename: 'ProjectV2ItemFieldSingleSelectValue',
      field: { name: fieldName },
      name: fieldState.value,
      optionId: fieldState.optionId,
    }));
    return {
      id: item.id,
      project: { id: item.projectId },
      fieldValues: { nodes },
    };
  });
}

if (args[0] !== 'api' || args[1] !== 'graphql') {
  if (args[0] === 'project' && args[1] === 'view') {
    saveAndPrint(state.projectView ?? {});
    process.exit(0);
  }
  if (args[0] === 'project' && args[1] === 'field-list') {
    saveAndPrint(state.projectFields ?? {});
    process.exit(0);
  }
  if (args[0] === 'project' && args[1] === 'item-list') {
    saveAndPrint(state.projectItems ?? {});
    process.exit(0);
  }
  console.error('Unsupported fake gh invocation:', args.join(' '));
  process.exit(1);
}

const { query, variables } = parseGraphqlArgs(args);
if (query.includes('resource(url: $url)')) {
  const resource = state.resources?.[variables.url] ?? null;
  if (!resource) {
    saveAndPrint({ data: { resource: null } });
    process.exit(0);
  }

  if (query.includes('projectItems(first: 100)')) {
    const projectItems = serializeProjectItems(resource);
    saveAndPrint({
      data: {
        resource: {
          __typename: resource.__typename,
          id: resource.id,
          url: resource.url,
          title: resource.title,
          body: resource.body ?? null,
          repository: resource.repository,
          projectItems: { nodes: projectItems },
          closingIssuesReferences: {
            nodes: (resource.closingIssuesReferences ?? []).map((issue) => ({
              id: issue.id,
              url: issue.url,
              title: issue.title,
              body: issue.body ?? null,
              repository: issue.repository,
              projectItems: { nodes: serializeProjectItems(issue) },
            })),
          },
        },
      },
    });
    process.exit(0);
  }

  saveAndPrint({ data: { resource } });
  process.exit(0);
}

if (query.includes('addProjectV2ItemById')) {
  const itemId = state.nextAddedItemId ?? 'item-added-1';
  state.addCalls.push({ projectId: variables.projectId, contentId: variables.contentId, itemId });
  state.nextAddedItemId = itemId;
  state.itemFields[itemId] ??= {};
  const resource = Object.values(state.resources ?? {}).find((candidate) => candidate.id === variables.contentId);
  if (resource) {
    resource.projectItems ??= [];
    if (!resource.projectItems.some((item) => item.id === itemId)) {
      resource.projectItems.push({ id: itemId, projectId: variables.projectId });
    }
  }
  saveAndPrint({ data: { addProjectV2ItemById: { item: { id: itemId } } } });
  process.exit(0);
}

if (query.includes('updateProjectV2ItemFieldValue')) {
  state.itemFields[variables.itemId] ??= {};
  const aliases = extractUpdateAliases(query);
  const data = {};
  const updates = Object.keys(variables)
    .filter((key) => /^fieldId[0-9]+$/.test(key))
    .sort((left, right) => Number.parseInt(left.replace('fieldId', ''), 10) - Number.parseInt(right.replace('fieldId', ''), 10))
    .map((fieldKey, index) => ({
      alias: aliases[index] ?? ('fieldUpdate' + index),
      fieldId: variables[fieldKey],
      optionId: variables['optionId' + index],
    }));

  for (const update of updates) {
    const fieldName = state.fieldMap?.[update.fieldId] ?? update.fieldId;
    const optionName = state.optionMap?.[update.optionId] ?? update.optionId;
    state.updateCalls.push({
      projectId: variables.projectId,
      itemId: variables.itemId,
      fieldId: update.fieldId,
      optionId: update.optionId,
    });
    state.itemFields[variables.itemId][fieldName] = {
      value: optionName,
      optionId: update.optionId,
    };
    data[update.alias] = { projectV2Item: { id: variables.itemId } };
  }

  saveAndPrint({ data });
  process.exit(0);
}

if (query.includes('node(id: $itemId)')) {
  const itemFields = state.itemFields?.[variables.itemId] ?? {};
  const nodes = Object.entries(itemFields).map(([fieldName, fieldState]) => ({
    __typename: 'ProjectV2ItemFieldSingleSelectValue',
    field: { name: fieldName },
    name: fieldState.value,
    optionId: fieldState.optionId,
  }));
  saveAndPrint({ data: { node: { id: variables.itemId, fieldValues: { nodes } } } });
  process.exit(0);
}

console.error('Unsupported fake gh graphql query');
process.exit(1);
`, 'utf8');
  return {
    env: {
      FAKE_GH_STATE_PATH: statePath,
      COMPAREVI_PROJECT_PORTFOLIO_GH_SCRIPT: scriptPath,
    },
    statePath,
  };
}

test('project portfolio CLI emits v2 report schema for the expanded payload', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-cli-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const itemsPath = path.join(tempRoot, 'items.json');
  const outPath = path.join(tempRoot, 'report.json');

  await writeJson(configPath, buildConfig());
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, buildFields());
  await writeJson(itemsPath, {
    totalCount: 1,
    items: [
      {
        id: 'item-1',
        Type: 'Epic',
        Assignees: ['svelde'],
        Reviewers: ['copilot-reviewer'],
        'Linked pull requests': ['https://github.com/example/repo/pull/1'],
        Milestone: 'Q1 Sustain',
        'Parent issue': 'https://github.com/example/repo/issues/99',
        'Sub-issues progress': '2 / 3',
        Status: 'Todo',
        Program: 'Shared Infra',
        Phase: 'Policy',
        'Environment Class': 'Infra',
        'Blocking Signal': 'Scope',
        'Evidence State': 'Ready',
        'Portfolio Track': 'Agent UX',
        content: {
          url: 'https://github.com/example/repo/issues/1',
          title: 'Example issue',
          repository: 'example/repo',
          type: 'Issue',
        },
      },
    ],
  });

  const result = runCli([
    'snapshot',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--item-file', itemsPath,
    '--out', outPath,
  ]);

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  assert.equal(report.schema, 'project-portfolio-report@v2');
  assert.equal(report.items[0].portfolioTrack, 'Agent UX');
  assert.equal(report.items[0].type, 'Epic');
  assert.equal(report.items[0].milestone, 'Q1 Sustain');
  assert.deepEqual(report.items[0].subIssuesProgressSummary, {
    completed: 2,
    total: 3,
    percent: 0.6667,
  });
  assert.deepEqual(report.items[0].linkedPullRequests, ['https://github.com/example/repo/pull/1']);
  assert.deepEqual(report.items[0].reviewers, ['copilot-reviewer']);
  assert.deepEqual(report.drift.fieldCatalogMismatches, []);
});

test('project portfolio CLI sizes gh item-list fetches to the live project item count', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-live-load-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const configPath = path.join(tempRoot, 'config.json');
  const outPath = path.join(tempRoot, 'report.json');
  const itemUrl = 'https://github.com/example/repo/issues/1';
  const config = buildConfig({ itemUrl });
  const fields = buildFields();
  const state = buildFakeGhState({
    targetUrl: itemUrl,
    resourceId: 'resource-1',
    title: 'Example issue',
    fields,
    nextAddedItemId: 'item-1',
  });
  state.projectView = buildView({ itemCount: 138 });
  state.projectFields = fields;
  state.projectItems = {
    totalCount: 138,
    items: [
      {
        id: 'item-1',
        Status: 'Todo',
        Program: 'Shared Infra',
        Phase: 'Policy',
        'Environment Class': 'Infra',
        'Blocking Signal': 'Scope',
        'Evidence State': 'Ready',
        'Portfolio Track': 'Agent UX',
        content: {
          url: itemUrl,
          title: 'Example issue',
          repository: 'example/repo',
          type: 'Issue',
        },
      },
    ],
  };

  await writeJson(configPath, config);
  const harness = await writeFakeGhHarness(tempRoot, state);
  const result = runCli(['snapshot', '--config', configPath, '--out', outPath], { env: harness.env });

  assert.equal(result.status, 0, result.stderr);
  const finalState = JSON.parse(await readFile(harness.statePath, 'utf8'));
  const itemListCall = finalState.calls.find(
    (args) => args[0] === 'project' && args[1] === 'item-list',
  );
  assert.ok(itemListCall, 'expected project item-list call');
  const limitIndex = itemListCall.indexOf('--limit');
  assert.notEqual(limitIndex, -1, 'expected --limit in project item-list call');
  assert.equal(itemListCall[limitIndex + 1], '138');
});

test('project portfolio CLI normalizes item values using fieldCatalog display names', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-renamed-fields-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const fieldNames = {
    status: 'Workflow Status',
    program: 'Program Lane',
    phase: 'Execution Phase',
    environmentClass: 'Runtime Class',
    blockingSignal: 'Gate Signal',
    evidenceState: 'Evidence Readiness',
    portfolioTrack: 'Track Label',
  };

  const configPath = path.join(tempRoot, 'config-renamed.json');
  const viewPath = path.join(tempRoot, 'view-renamed.json');
  const fieldsPath = path.join(tempRoot, 'fields-renamed.json');
  const itemsPath = path.join(tempRoot, 'items-renamed.json');
  const outPath = path.join(tempRoot, 'report-renamed.json');

  await writeJson(configPath, buildConfig({ fieldNames, itemUrl: 'https://github.com/example/repo/issues/3' }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, buildFields(fieldNames));
  await writeJson(itemsPath, {
    totalCount: 1,
    items: [
      {
        id: 'item-3',
        'Workflow Status': 'Todo',
        'Program Lane': 'Shared Infra',
        'Execution Phase': 'Policy',
        'Runtime Class': 'Infra',
        'Gate Signal': 'Scope',
        'Evidence Readiness': 'Ready',
        'Track Label': 'Agent UX',
        content: {
          url: 'https://github.com/example/repo/issues/3',
          title: 'Renamed fields issue',
          repository: 'example/repo',
        },
      },
    ],
  });

  const result = runCli([
    'snapshot',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--item-file', itemsPath,
    '--out', outPath,
  ]);

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  assert.equal(report.items[0].status, 'Todo');
  assert.equal(report.items[0].program, 'Shared Infra');
  assert.equal(report.items[0].phase, 'Policy');
  assert.equal(report.items[0].environmentClass, 'Infra');
  assert.equal(report.items[0].blockingSignal, 'Scope');
  assert.equal(report.items[0].evidenceState, 'Ready');
  assert.equal(report.items[0].portfolioTrack, 'Agent UX');
  assert.deepEqual(report.drift.fieldMismatches, []);
});

test('project portfolio CLI rejects config field values outside fieldCatalog options', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-invalid-config-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const configPath = path.join(tempRoot, 'config-invalid.json');
  const config = buildConfig();
  config.items[0].portfolioTrack = 'Bad Track';
  await writeJson(configPath, config);

  const result = runCli([
    'snapshot',
    '--config', configPath,
  ]);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Invalid portfolioTrack 'Bad Track'/);
});

test('project portfolio CLI apply mode adds a missing item and seeds fields from config', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-config-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/10';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const itemsPath = path.join(tempRoot, 'items.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({ itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);
  await writeJson(itemsPath, {
    totalCount: 0,
    items: [],
  });

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_10',
    title: 'Tracked project issue',
    fields,
    nextAddedItemId: 'item-added-10',
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--item-file', itemsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.schema, 'project-portfolio-apply-report@v1');
  assert.equal(report.target.added, true);
  assert.equal(report.target.itemId, 'item-added-10');
  assert.equal(report.target.projectedItemSnapshot.status, 'Todo');
  assert.equal(report.target.projectedItemSnapshot.program, 'Shared Infra');
  assert.equal(report.target.boardContext.contentType, 'Issue');
  assert.equal(report.target.boardContext.hasMilestone, false);
  assert.equal(report.appliedFields.length, 7);
  assert.ok(report.appliedFields.every((field) => field.source === 'config'));
  assert.equal(report.verification.ok, true);
  assert.equal(report.verification.attempts, 1);
  assert.equal(report.verification.delayMs, 0);
  assert.deepEqual(fakeGhState.addCalls, [
    {
      projectId: 'PVT_example',
      contentId: 'ISSUE_10',
      itemId: 'item-added-10',
    },
  ]);
  assert.equal(fakeGhState.updateCalls.length, 7);
  assert.ok(fakeGhState.updateCalls.every((call) => call.itemId === 'item-added-10'));
});

test('project portfolio CLI apply mode prefers explicit values and skips add when item already exists', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-explicit-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/11';
  const fieldNames = {
    status: 'Workflow Status',
    program: 'Program Lane',
    phase: 'Execution Phase',
    environmentClass: 'Runtime Class',
    blockingSignal: 'Gate Signal',
    evidenceState: 'Evidence Readiness',
    portfolioTrack: 'Track Label',
  };

  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const itemsPath = path.join(tempRoot, 'items.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields(fieldNames);

  await writeJson(configPath, buildConfig({ fieldNames, itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);
  await writeJson(itemsPath, {
    totalCount: 1,
    items: [
      {
        id: 'item-existing-11',
        Type: 'Feature',
        Reviewers: ['copilot-reviewer', 'human-reviewer'],
        Milestone: 'Q2 Intake',
        'Linked pull requests': ['https://github.com/example/repo/pull/11'],
        'Sub-issues progress': '1 / 4',
        'Workflow Status': 'Todo',
        'Program Lane': 'Shared Infra',
        'Execution Phase': 'Policy',
        'Runtime Class': 'Infra',
        'Gate Signal': 'Scope',
        'Evidence Readiness': 'Ready',
        'Track Label': 'Agent UX',
        content: {
          url: targetUrl,
          title: 'Existing project issue',
          repository: 'example/repo',
          type: 'Issue',
        },
      },
    ],
  });

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_11',
    title: 'Tracked existing issue',
    fields,
    existingItemId: 'item-existing-11',
    existingItemFieldValues: {
      'Workflow Status': 'Todo',
      'Program Lane': 'Shared Infra',
      'Execution Phase': 'Policy',
      'Runtime Class': 'Infra',
      'Gate Signal': 'Scope',
      'Evidence Readiness': 'Ready',
      'Track Label': 'Agent UX',
    },
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--item-file', itemsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
    '--status', 'In Progress',
    '--program', '^Shared^ Infra^',
  ], {
    env: fakeGh.env,
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, false);
  assert.equal(report.target.existed, true);
  assert.equal(report.target.itemId, 'item-existing-11');
  assert.equal(report.target.existingItemSnapshot.url, targetUrl);
  assert.equal(report.target.existingItemSnapshot.type, 'Feature');
  assert.equal(report.target.projectedItemSnapshot.status, 'In Progress');
  assert.equal(report.target.projectedItemSnapshot.milestone, 'Q2 Intake');
  assert.equal(report.target.boardContext.type, 'Feature');
  assert.equal(report.target.boardContext.reviewerCount, 2);
  assert.equal(report.target.boardContext.linkedPullRequestCount, 1);
  assert.equal(report.target.boardContext.subIssuesCompleted, 1);
  assert.equal(report.target.boardContext.subIssuesTotal, 4);
  assert.equal(report.appliedFields.find((field) => field.key === 'status').source, 'explicit');
  assert.equal(report.appliedFields.find((field) => field.key === 'status').value, 'In Progress');
  assert.equal(report.appliedFields.find((field) => field.key === 'program').source, 'explicit');
  assert.equal(report.appliedFields.find((field) => field.key === 'program').value, 'Shared Infra');
  assert.equal(report.verification.ok, true);
  assert.equal(fakeGhState.addCalls.length, 0);
  assert.equal(fakeGhState.updateCalls.length, 1);
  assert.equal(fakeGhState.updateCalls[0].itemId, 'item-existing-11');
  assert.equal(fakeGhState.updateCalls[0].fieldId, 'status-field');
});

test('project portfolio CLI live apply skips project item-list and batches field updates for a missing item', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-live-missing-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/13';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({ itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_13',
    title: 'Live apply issue',
    fields,
    nextAddedItemId: 'item-added-13',
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, true);
  assert.equal(report.target.itemId, 'item-added-13');
  assert.equal(report.verification.ok, true);
  assert.equal(
    fakeGhState.calls.some((args) => args[0] === 'project' && args[1] === 'item-list'),
    false,
  );
  const updateMutations = fakeGhState.calls.filter(
    (args) => args[0] === 'api'
      && args[1] === 'graphql'
      && args.some((token) => typeof token === 'string' && token.includes('updateProjectV2ItemFieldValue')),
  );
  assert.equal(updateMutations.length, 1);
  assert.equal(fakeGhState.updateCalls.length, 7);
});

test('project portfolio CLI live apply infers fresh PR field defaults from a linked issue project item', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-live-pr-infer-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/pull/22';
  const linkedIssueUrl = 'https://github.com/example/repo/issues/22';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({
    itemUrl: linkedIssueUrl,
    status: 'Todo',
  }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'PR_22',
    title: 'Fresh PR apply target',
    fields,
    nextAddedItemId: 'item-added-22',
    resourceType: 'PullRequest',
    linkedIssueResources: [
      {
        id: 'ISSUE_22',
        url: linkedIssueUrl,
        title: 'Linked issue context',
        repository: {
          nameWithOwner: 'example/repo',
        },
        projectItems: [
          {
            id: 'item-existing-issue-22',
            projectId: 'PVT_example',
          },
        ],
      },
    ],
    existingItemFieldValues: {
      Status: 'Todo',
      Program: 'Shared Infra',
      Phase: 'Policy',
      'Environment Class': 'Infra',
      'Blocking Signal': 'Scope',
      'Evidence State': 'Ready',
      'Portfolio Track': 'Agent UX',
    },
  }));

  const state = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));
  state.itemFields['item-existing-issue-22'] = {
    Status: { value: 'Todo', optionId: 'status-todo' },
    Program: { value: 'Shared Infra', optionId: 'program-shared' },
    Phase: { value: 'Policy', optionId: 'phase-policy' },
    'Environment Class': { value: 'Infra', optionId: 'environment-infra' },
    'Blocking Signal': { value: 'Scope', optionId: 'blocking-scope' },
    'Evidence State': { value: 'Ready', optionId: 'evidence-ready' },
    'Portfolio Track': { value: 'Agent UX', optionId: 'track-agent' },
  };
  await writeJson(fakeGh.statePath, state);

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, true);
  assert.equal(report.target.itemId, 'item-added-22');
  assert.equal(report.appliedFields.length, 7);
  assert.ok(report.appliedFields.every((field) => field.source === 'inferred-linked-issue'));
  assert.ok(report.appliedFields.every((field) => field.sourceUrl === linkedIssueUrl));
  assert.equal(fakeGhState.addCalls.length, 1);
  assert.equal(fakeGhState.updateCalls.length, 7);
});

test('project portfolio CLI live apply infers fresh PR field defaults from issue metadata in the PR body', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-live-pr-body-infer-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/pull/23';
  const linkedIssueUrl = 'https://github.com/example/repo/issues/23';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({
    itemUrl: linkedIssueUrl,
    status: 'Todo',
  }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'PR_23',
    title: 'Fresh PR apply target from body metadata',
    body: `## Issue Linkage\n- Primary issue: #23\n- Issue URL: ${linkedIssueUrl}\n`,
    fields,
    nextAddedItemId: 'item-added-23',
    resourceType: 'PullRequest',
  }));

  const state = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));
  state.resources[linkedIssueUrl] = {
    __typename: 'Issue',
    id: 'ISSUE_23',
    url: linkedIssueUrl,
    title: 'Standing issue context',
    repository: {
      nameWithOwner: 'example/repo',
    },
    projectItems: [
      {
        id: 'item-existing-issue-23',
        projectId: 'PVT_example',
      },
    ],
    closingIssuesReferences: [],
  };
  state.itemFields['item-existing-issue-23'] = {
    Status: { value: 'Todo', optionId: 'status-todo' },
    Program: { value: 'Shared Infra', optionId: 'program-shared' },
    Phase: { value: 'Policy', optionId: 'phase-policy' },
    'Environment Class': { value: 'Infra', optionId: 'environment-infra' },
    'Blocking Signal': { value: 'Scope', optionId: 'blocking-scope' },
    'Evidence State': { value: 'Ready', optionId: 'evidence-ready' },
    'Portfolio Track': { value: 'Agent UX', optionId: 'track-agent' },
  };
  await writeJson(fakeGh.statePath, state);

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, true);
  assert.equal(report.target.itemId, 'item-added-23');
  assert.equal(report.appliedFields.length, 7);
  assert.ok(report.appliedFields.every((field) => field.source === 'inferred-linked-issue'));
  assert.ok(report.appliedFields.every((field) => field.sourceUrl === linkedIssueUrl));
  assert.equal(fakeGhState.addCalls.length, 1);
  assert.equal(fakeGhState.updateCalls.length, 7);
});

test('project portfolio CLI live apply resolves existing project membership without a board scrape', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-live-existing-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/14';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({ itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_14',
    title: 'Existing live apply issue',
    fields,
    existingItemId: 'item-existing-14',
    existingItemFieldValues: {
      Status: 'Todo',
      Program: 'Shared Infra',
      Phase: 'Policy',
      'Environment Class': 'Infra',
      'Blocking Signal': 'Scope',
      'Evidence State': 'Ready',
      'Portfolio Track': 'Agent UX',
    },
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--status', 'In Progress',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, false);
  assert.equal(report.target.existed, true);
  assert.equal(report.target.itemId, 'item-existing-14');
  assert.equal(report.target.existingItemSnapshot.status, 'Todo');
  assert.equal(report.target.observedItemSnapshot.status, 'In Progress');
  assert.equal(
    fakeGhState.calls.some((args) => args[0] === 'project' && args[1] === 'item-list'),
    false,
  );
  assert.equal(fakeGhState.addCalls.length, 0);
  const updateMutations = fakeGhState.calls.filter(
    (args) => args[0] === 'api'
      && args[1] === 'graphql'
      && args.some((token) => typeof token === 'string' && token.includes('updateProjectV2ItemFieldValue')),
  );
  assert.equal(updateMutations.length, 1);
  assert.equal(fakeGhState.updateCalls.length, 1);
  assert.equal(fakeGhState.updateCalls[0].fieldId, 'status-field');
});

test('project portfolio CLI live apply skips mutations entirely when the target already matches the requested fields', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-live-noop-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/15';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const outPath = path.join(tempRoot, 'apply-report.json');
  const fields = buildFields();

  await writeJson(configPath, buildConfig({ itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);

  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_15',
    title: 'No-op live apply issue',
    fields,
    existingItemId: 'item-existing-15',
    existingItemFieldValues: {
      Status: 'Todo',
      Program: 'Shared Infra',
      Phase: 'Policy',
      'Environment Class': 'Infra',
      'Blocking Signal': 'Scope',
      'Evidence State': 'Ready',
      'Portfolio Track': 'Agent UX',
    },
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--out', outPath,
    '--url', targetUrl,
    '--use-config',
  ], {
    env: {
      ...fakeGh.env,
      COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS: '0',
    },
  });

  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(outPath, 'utf8'));
  const fakeGhState = JSON.parse(await readFile(fakeGh.statePath, 'utf8'));

  assert.equal(report.target.added, false);
  assert.equal(report.target.existed, true);
  assert.equal(report.verification.ok, true);
  assert.equal(report.verification.skipped, true);
  assert.equal(report.appliedFields.every((field) => field.applied === false), true);
  assert.equal(fakeGhState.updateCalls.length, 0);
  assert.equal(
    fakeGhState.calls.some((args) => args[0] === 'project' && args[1] === 'item-list'),
    false,
  );
});

test('project portfolio CLI apply mode rejects live option mismatches before mutating GitHub', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-apply-invalid-option-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const targetUrl = 'https://github.com/example/repo/issues/12';
  const configPath = path.join(tempRoot, 'config.json');
  const viewPath = path.join(tempRoot, 'view.json');
  const fieldsPath = path.join(tempRoot, 'fields.json');
  const itemsPath = path.join(tempRoot, 'items.json');
  const fields = buildFields({}, { status: 'Backlog' });

  await writeJson(configPath, buildConfig({ itemUrl: targetUrl }));
  await writeJson(viewPath, buildView());
  await writeJson(fieldsPath, fields);
  await writeJson(itemsPath, {
    totalCount: 0,
    items: [],
  });
  const fakeGh = await writeFakeGhHarness(tempRoot, buildFakeGhState({
    targetUrl,
    resourceId: 'ISSUE_12',
    title: 'Issue 12',
    fields,
    nextAddedItemId: 'item-added-12',
  }));

  const result = runCli([
    'apply',
    '--config', configPath,
    '--view-file', viewPath,
    '--fields-file', fieldsPath,
    '--item-file', itemsPath,
    '--url', targetUrl,
    '--status', 'In Progress',
  ], {
    env: fakeGh.env,
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /does not expose option 'In Progress'/);
});
