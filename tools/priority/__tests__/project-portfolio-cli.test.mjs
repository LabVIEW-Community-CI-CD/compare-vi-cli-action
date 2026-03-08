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

function runCli(args) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
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

  await writeJson(configPath, {
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
      status: { name: 'Status', options: ['Todo'] },
      program: { name: 'Program', options: ['Shared Infra'] },
      phase: { name: 'Phase', options: ['Policy'] },
      environmentClass: { name: 'Environment Class', options: ['Infra'] },
      blockingSignal: { name: 'Blocking Signal', options: ['Scope'] },
      evidenceState: { name: 'Evidence State', options: ['Ready'] },
      portfolioTrack: { name: 'Portfolio Track', options: ['Agent UX'] },
    },
    items: [
      {
        url: 'https://github.com/example/repo/issues/1',
        status: 'Todo',
        program: 'Shared Infra',
        phase: 'Policy',
        environmentClass: 'Infra',
        blockingSignal: 'Scope',
        evidenceState: 'Ready',
        portfolioTrack: 'Agent UX',
      },
    ],
  });

  await writeJson(viewPath, {
    id: 'PVT_example',
    number: 7,
    title: 'Example Portfolio',
    shortDescription: 'Example description',
    readme: 'Example readme',
    public: false,
    url: 'https://github.com/orgs/example/projects/7',
    items: { totalCount: 1 },
    fields: { totalCount: 7 },
    owner: { login: 'example-owner', type: 'Organization' },
  });

  await writeJson(fieldsPath, {
    totalCount: 7,
    fields: [
      { id: 'status', name: 'Status', type: 'ProjectV2SingleSelectField', options: [{ id: 'a', name: 'Todo' }] },
      { id: 'program', name: 'Program', type: 'ProjectV2SingleSelectField', options: [{ id: 'b', name: 'Shared Infra' }] },
      { id: 'phase', name: 'Phase', type: 'ProjectV2SingleSelectField', options: [{ id: 'c', name: 'Policy' }] },
      { id: 'environment', name: 'Environment Class', type: 'ProjectV2SingleSelectField', options: [{ id: 'd', name: 'Infra' }] },
      { id: 'blocking', name: 'Blocking Signal', type: 'ProjectV2SingleSelectField', options: [{ id: 'e', name: 'Scope' }] },
      { id: 'evidence', name: 'Evidence State', type: 'ProjectV2SingleSelectField', options: [{ id: 'f', name: 'Ready' }] },
      { id: 'track', name: 'Portfolio Track', type: 'ProjectV2SingleSelectField', options: [{ id: 'g', name: 'Agent UX' }] },
    ],
  });

  await writeJson(itemsPath, {
    totalCount: 1,
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
          url: 'https://github.com/example/repo/issues/1',
          title: 'Example issue',
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
  assert.equal(report.schema, 'project-portfolio-report@v2');
  assert.equal(report.items[0].portfolioTrack, 'Agent UX');
  assert.deepEqual(report.drift.fieldCatalogMismatches, []);
});

test('project portfolio CLI normalizes item values using fieldCatalog display names', async (t) => {
  const tempRoot = await mkdtemp(path.join(tmpdir(), 'project-portfolio-renamed-fields-'));
  t.after(async () => {
    await rm(tempRoot, { recursive: true, force: true });
  });

  const configPath = path.join(tempRoot, 'config-renamed.json');
  const viewPath = path.join(tempRoot, 'view-renamed.json');
  const fieldsPath = path.join(tempRoot, 'fields-renamed.json');
  const itemsPath = path.join(tempRoot, 'items-renamed.json');
  const outPath = path.join(tempRoot, 'report-renamed.json');

  await writeJson(configPath, {
    schema: 'project-portfolio-config@v1',
    owner: 'example-owner',
    number: 9,
    title: 'Renamed Fields Portfolio',
    shortDescription: 'Renamed field labels',
    readme: 'Renamed field readme',
    public: false,
    allowAdditionalItems: false,
    repositories: ['example/repo'],
    fieldCatalog: {
      status: { name: 'Workflow Status', options: ['Todo'] },
      program: { name: 'Program Lane', options: ['Shared Infra'] },
      phase: { name: 'Execution Phase', options: ['Policy'] },
      environmentClass: { name: 'Runtime Class', options: ['Infra'] },
      blockingSignal: { name: 'Gate Signal', options: ['Scope'] },
      evidenceState: { name: 'Evidence Readiness', options: ['Ready'] },
      portfolioTrack: { name: 'Track Label', options: ['Agent UX'] },
    },
    items: [
      {
        url: 'https://github.com/example/repo/issues/3',
        status: 'Todo',
        program: 'Shared Infra',
        phase: 'Policy',
        environmentClass: 'Infra',
        blockingSignal: 'Scope',
        evidenceState: 'Ready',
        portfolioTrack: 'Agent UX',
      },
    ],
  });

  await writeJson(viewPath, {
    id: 'PVT_renamed',
    number: 9,
    title: 'Renamed Fields Portfolio',
    shortDescription: 'Renamed field labels',
    readme: 'Renamed field readme',
    public: false,
    url: 'https://github.com/orgs/example/projects/9',
    items: { totalCount: 1 },
    fields: { totalCount: 7 },
    owner: { login: 'example-owner', type: 'Organization' },
  });

  await writeJson(fieldsPath, {
    totalCount: 7,
    fields: [
      { id: 'status', name: 'Workflow Status', type: 'ProjectV2SingleSelectField', options: [{ id: 'a', name: 'Todo' }] },
      { id: 'program', name: 'Program Lane', type: 'ProjectV2SingleSelectField', options: [{ id: 'b', name: 'Shared Infra' }] },
      { id: 'phase', name: 'Execution Phase', type: 'ProjectV2SingleSelectField', options: [{ id: 'c', name: 'Policy' }] },
      { id: 'environment', name: 'Runtime Class', type: 'ProjectV2SingleSelectField', options: [{ id: 'd', name: 'Infra' }] },
      { id: 'blocking', name: 'Gate Signal', type: 'ProjectV2SingleSelectField', options: [{ id: 'e', name: 'Scope' }] },
      { id: 'evidence', name: 'Evidence Readiness', type: 'ProjectV2SingleSelectField', options: [{ id: 'f', name: 'Ready' }] },
      { id: 'track', name: 'Track Label', type: 'ProjectV2SingleSelectField', options: [{ id: 'g', name: 'Agent UX' }] },
    ],
  });

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
  await writeJson(configPath, {
    schema: 'project-portfolio-config@v1',
    owner: 'example-owner',
    number: 8,
    title: 'Invalid Portfolio',
    shortDescription: 'Invalid config',
    readme: 'Invalid readme',
    public: false,
    allowAdditionalItems: false,
    repositories: ['example/repo'],
    fieldCatalog: {
      status: { name: 'Status', options: ['Todo'] },
      program: { name: 'Program', options: ['Shared Infra'] },
      phase: { name: 'Phase', options: ['Policy'] },
      environmentClass: { name: 'Environment Class', options: ['Infra'] },
      blockingSignal: { name: 'Blocking Signal', options: ['Scope'] },
      evidenceState: { name: 'Evidence State', options: ['Ready'] },
      portfolioTrack: { name: 'Portfolio Track', options: ['Agent UX'] },
    },
    items: [
      {
        url: 'https://github.com/example/repo/issues/2',
        status: 'Todo',
        program: 'Shared Infra',
        phase: 'Policy',
        environmentClass: 'Infra',
        blockingSignal: 'Scope',
        evidenceState: 'Ready',
        portfolioTrack: 'Bad Track',
      },
    ],
  });

  const result = runCli([
    'snapshot',
    '--config', configPath,
  ]);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Invalid portfolioTrack 'Bad Track'/);
});
