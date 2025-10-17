import '../bootstrap/node-deprecations.js';

import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { zodToJsonSchema } from 'zod-to-json-schema';
import { schemas } from './definitions.js';

const OUTPUT_DIR = join(process.cwd(), 'docs', 'schema', 'generated');

async function main() {
  await mkdir(OUTPUT_DIR, { recursive: true });
  const outputs = [];

for (const entry of schemas) {
  const jsonSchema = zodToJsonSchema(entry.schema, {
    target: 'jsonSchema7',
    name: entry.id,
  }) as Record<string, unknown>;

  if (entry.description) {
    jsonSchema.description = entry.description;
  }

  if (!jsonSchema.$schema) {
    jsonSchema.$schema = 'https://json-schema.org/draft/2020-12/schema';
  }

  if (!jsonSchema.$id) {
    jsonSchema.$id = `urn:compare-vi-cli-action:schema:${entry.id}`;
  }

  const outPath = join(OUTPUT_DIR, entry.fileName);
  await writeFile(outPath, `${JSON.stringify(jsonSchema, null, 2)}\n`, { encoding: 'utf8' });
  outputs.push(outPath);
}

  console.log(`Generated ${outputs.length} schema${outputs.length === 1 ? '' : 's'} in ${OUTPUT_DIR}`);
}

main().catch((err) => {
  console.error('[schemas] generation failed');
  console.error(err);
  process.exitCode = 1;
});
