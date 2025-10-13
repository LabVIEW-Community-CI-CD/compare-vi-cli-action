import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { zodToJsonSchema } from 'zod-to-json-schema';
import { schemas } from './definitions.js';

const OUTPUT_DIR = join(process.cwd(), 'docs', 'schema', 'generated');
const DOTNET_SCHEMA_DIR = join(process.cwd(), 'src', 'CompareVi.Shared', 'Schemas');
const MANIFEST_PATH = join(OUTPUT_DIR, 'schema-manifest.json');

async function main() {
  await Promise.all([mkdir(OUTPUT_DIR, { recursive: true }), mkdir(DOTNET_SCHEMA_DIR, { recursive: true })]);
  const outputs: string[] = [];
  const manifestEntries: Array<{ id: string; fileName: string; hash: string }> = [];

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
  const schemaJson = `${JSON.stringify(jsonSchema, null, 2)}\n`;
  await writeFile(outPath, schemaJson, { encoding: 'utf8' });
  const dotnetPath = join(DOTNET_SCHEMA_DIR, entry.fileName);
  await writeFile(dotnetPath, schemaJson, { encoding: 'utf8' });
  outputs.push(outPath);

  const hash = createHash('sha256').update(schemaJson).digest('hex');
  manifestEntries.push({ id: entry.id, fileName: entry.fileName, hash });
}

  let manifestGeneratedAt = new Date().toISOString();
  try {
    const existing = await readFile(MANIFEST_PATH, { encoding: 'utf8' });
    const parsed = JSON.parse(existing) as { generatedAt?: string; schemas?: Array<{ id: string; fileName: string; hash: string }> };
    if (parsed.schemas && JSON.stringify(parsed.schemas) === JSON.stringify(manifestEntries) && parsed.generatedAt) {
      manifestGeneratedAt = parsed.generatedAt;
    }
  } catch {
    // Ignore parse/read failures; manifest will be regenerated.
  }

  const manifest = {
    generatedAt: manifestGeneratedAt,
    schemas: manifestEntries,
  };
  const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`;
  await writeFile(MANIFEST_PATH, manifestJson, { encoding: 'utf8' });

  console.log(`Generated ${outputs.length} schema${outputs.length === 1 ? '' : 's'} in ${OUTPUT_DIR}`);
}

main().catch((err) => {
  console.error('[schemas] generation failed');
  console.error(err);
  process.exitCode = 1;
});
