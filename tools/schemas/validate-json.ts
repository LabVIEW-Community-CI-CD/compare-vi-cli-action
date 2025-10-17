import '../shims/punycode-userland.js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ArgumentParser } from 'argparse';
import fg from 'fast-glob';
import { Ajv, type ErrorObject, type ValidateFunction } from 'ajv';
import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormatsPlugin from 'ajv-formats';
import type { FormatsPlugin } from 'ajv-formats';

interface Args {
  schema: string;
  data: string[][];
  optional?: boolean;
}

function readJson(path: string): unknown {
  try {
    const raw = readFileSync(path, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse JSON from ${path}: ${(err as Error).message}`);
  }
}

const addFormats = addFormatsPlugin as unknown as FormatsPlugin;

function formatIssues(errors: readonly ErrorObject[] | null | undefined): string {
  if (!errors || errors.length === 0) {
    return 'Unknown validation error';
  }

  return errors
    .map((error) => `${error.instancePath || '/'} ${error.message ?? ''}`.trim() || error.keyword)
    .join('\n');
}

function main(): void {
  const parser = new ArgumentParser({
    description: 'Validate JSON documents against a schema using Ajv 2020.',
  });
  parser.add_argument('--schema', { required: true, help: 'Path to JSON schema file.' });
  parser.add_argument('--data', {
    required: true,
    action: 'append',
    nargs: '+',
    help: 'Data file glob(s) to validate. Can be specified multiple times.',
  });
  parser.add_argument('--optional', {
    action: 'store_true',
    help: 'Do not error when data globs match no files.',
  });

  const args = parser.parse_args() as Args;

  const schemaPath = resolve(process.cwd(), args.schema);
  const schema = readJson(schemaPath);

  const schemaObj = (schema ?? {}) as Record<string, unknown>;
  const schemaMeta = typeof schemaObj.$schema === 'string' ? schemaObj.$schema : '';

  const ajv = schemaMeta.includes('2020-12')
    ? new Ajv2020({ allErrors: true, strict: false, allowUnionTypes: true })
    : new Ajv({ allErrors: true, strict: false, allowUnionTypes: true });
  addFormats(ajv);

  const validate: ValidateFunction = ajv.compile(schema as Record<string, unknown>);

  let matched = 0;
  const globOptions: fg.Options = {
    cwd: process.cwd(),
    absolute: true,
    onlyFiles: true,
  };

  const dataGlobs = args.data.flat();

  for (const pattern of dataGlobs) {
    const files = fg.sync(pattern, globOptions);
    if (files.length === 0) {
      if (!args.optional) {
        // eslint-disable-next-line no-console
        console.warn(`[schema] No files matched pattern '${pattern}'.`);
      }
      continue;
    }
    matched += files.length;
    for (const file of files) {
      const data = readJson(file);
      const ok = validate(data);
      if (!ok) {
        const issues = formatIssues(validate.errors);
        throw new Error(`Validation failed for ${file}:\n${issues}`);
      }
    }
  }

  if (matched === 0) {
    // eslint-disable-next-line no-console
    console.log('[schema] No data files validated (globs empty).');
  } else {
    // eslint-disable-next-line no-console
    console.log(`[schema] Validated ${matched} file(s) against ${schemaPath}.`);
  }
}

main();
