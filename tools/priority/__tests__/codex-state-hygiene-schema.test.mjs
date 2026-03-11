#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runCodexStateHygiene } from '../codex-state-hygiene.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('codex state hygiene schema validates a checked-in report shape', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'codex-state-schema-'));
  const codexHome = path.join(tempRoot, '.codex');
  const sessionsRoot = path.join(codexHome, 'sessions', '2026', '03', '11');
  const logPath = path.join(tempRoot, 'Codex.log');

  await mkdir(sessionsRoot, { recursive: true });
  await writeFile(path.join(sessionsRoot, 'rollout.jsonl'), '{"ok":true}\n', 'utf8');
  await writeFile(logPath, '2026-03-11 12:35:03.812 [warning] [git-origin-and-roots] Failed to resolve origin\n', 'utf8');

  const report = await runCodexStateHygiene({
    codexHome,
    latestLogPath: logPath,
    now: new Date('2026-03-11T20:00:00.000Z')
  });

  const schema = JSON.parse(
    await readFile(path.join(repoRoot, 'docs', 'schemas', 'codex-state-hygiene-v1.schema.json'), 'utf8')
  );
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});
