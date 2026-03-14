#!/usr/bin/env node
import '../../shims/punycode-userland.mjs';
import * as fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import { findGitRoot, info } from './runner.mjs';

export const HOOK_SUMMARY_FILE_PATTERN = /^(pre-commit|post-commit|pre-push)(?:\.(shell|pwsh))?\.json$/i;

export function isHookSummaryFileName(fileName) {
  return typeof fileName === 'string' && HOOK_SUMMARY_FILE_PATTERN.test(fileName);
}

export function validateHookSummaries({ repoRoot = findGitRoot() } = {}) {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'hooks-summary-v1.schema.json');
  const resultsDir = path.join(repoRoot, 'tests', 'results', '_hooks');

  if (!fs.existsSync(schemaPath)) {
    throw new Error('[hooks schema] Schema not found at ' + schemaPath);
  }

  if (!fs.existsSync(resultsDir)) {
    throw new Error('[hooks schema] Directory not found: ' + resultsDir);
  }

  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const files = fs.readdirSync(resultsDir).filter(isHookSummaryFileName);

  if (files.length === 0) {
    info('[hooks schema] No hook summaries present.');
    return { files, failures: 0 };
  }

  let failures = 0;
  for (const file of files) {
    const fullPath = path.join(resultsDir, file);
    const data = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
    const valid = validate(data);
    if (!valid) {
      failures += 1;
      console.error('[hooks schema] Validation failed for ' + file + ':');
      console.error(JSON.stringify(validate.errors, null, 2));
    } else {
      info('[hooks schema] OK: ' + file);
    }
  }

  return { files, failures };
}

export function main() {
  const { failures } = validateHookSummaries();
  if (failures > 0) {
    process.exit(1);
  }
  info('[hooks schema] All summaries valid.');
  process.exit(0);
}

const isEntrypoint = fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || '');

if (isEntrypoint) {
  main();
}
