import '../shims/punycode-userland.js';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { Ajv, type ErrorObject, type ValidateFunction } from 'ajv';
import addFormatsPlugin from 'ajv-formats';
import type { FormatsPlugin } from 'ajv-formats';
import { zodToJsonSchema } from 'zod-to-json-schema';

import {
  cliArtifactMetaSchema,
  cliOperationNamesSchema,
  cliOperationsSchema,
  cliProviderNamesSchema,
  cliProviderSchema,
  cliProvidersSchema,
  cliQuoteSchema,
  cliProcsSchema,
  cliTokenizeSchema,
  cliVersionSchema,
} from '../schemas/definitions.js';

type JsonValue = unknown;

function resolveCliDll(): string {
  const override = process.env.CLI_DLL;
  if (override) {
    return override;
  }

  const repoRoot = process.cwd();
  const candidate = join(repoRoot, 'dist', 'comparevi-cli', 'comparevi-cli.dll');
  if (!existsSync(candidate)) {
    throw new Error(`comparevi-cli.dll not found at ${candidate}. Build the CLI first (Run Non-LV Checks or dotnet publish).`);
  }
  return candidate;
}

function runCli(dllPath: string, args: string[]): JsonValue {
  const result = spawnSync('dotnet', [dllPath, ...args], {
    encoding: 'utf8',
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`comparevi-cli ${args.join(' ')} exited ${result.status}: ${result.stderr}`.trim());
  }

  const stdout = result.stdout.trim();
  if (!stdout) {
    throw new Error(`comparevi-cli ${args.join(' ')} emitted no output.`);
  }

  try {
    return JSON.parse(stdout) as JsonValue;
  } catch (err) {
    throw new Error(`Failed to parse JSON from comparevi-cli ${args.join(' ')}: ${(err as Error).message}\nOutput:\n${stdout}`);
  }
}

const addFormats = addFormatsPlugin as unknown as FormatsPlugin;

function compileValidator(schemaId: string, jsonSchema: Record<string, unknown>) {
  const ajv = new Ajv({
    allErrors: true,
    strict: false,
  });
  addFormats(ajv);
  return ajv.compile<JsonValue>(jsonSchema);
}

function formatErrors(errors: readonly ErrorObject[] | null | undefined): string {
  if (!errors || errors.length === 0) {
    return 'Unknown validation error';
  }

  return errors
    .map((error) => `${error.instancePath} ${error.message ?? ''}`.trim() || error.keyword)
    .join('\n');
}

function validate(name: string, data: JsonValue, validateFn: ValidateFunction<JsonValue>) {
  const ok = validateFn(data);
  if (!ok) {
    const errors = formatErrors(validateFn.errors);
    throw new Error(`Validation failed for ${name}:\n${errors}`);
  }
}

function readArtifactMeta(): JsonValue | null {
  const metaPath = join(process.cwd(), 'tests', 'results', '_cli', 'meta.json');
  if (!existsSync(metaPath)) {
    return null;
  }
  const raw = readFileSync(metaPath, 'utf8');
  return JSON.parse(raw) as JsonValue;
}

function main() {
  const dll = resolveCliDll();

  const versionValidator = compileValidator(
    'cli-version',
    zodToJsonSchema(cliVersionSchema, { target: 'jsonSchema7', name: 'cli-version' }) as Record<string, unknown>,
  );

  const tokenizeValidator = compileValidator(
    'cli-tokenize',
    zodToJsonSchema(cliTokenizeSchema, { target: 'jsonSchema7', name: 'cli-tokenize' }) as Record<string, unknown>,
  );

  const quoteValidator = compileValidator(
    'cli-quote',
    zodToJsonSchema(cliQuoteSchema, { target: 'jsonSchema7', name: 'cli-quote' }) as Record<string, unknown>,
  );

  const procsValidator = compileValidator(
    'cli-procs',
    zodToJsonSchema(cliProcsSchema, { target: 'jsonSchema7', name: 'cli-procs' }) as Record<string, unknown>,
  );

  const operationsValidator = compileValidator(
    'cli-operations',
    zodToJsonSchema(cliOperationsSchema, { target: 'jsonSchema7', name: 'cli-operations' }) as Record<string, unknown>,
  );

  const operationNamesValidator = compileValidator(
    'cli-operation-names',
    zodToJsonSchema(cliOperationNamesSchema, { target: 'jsonSchema7', name: 'cli-operation-names' }) as Record<string, unknown>,
  );

  const providersValidator = compileValidator(
    'cli-providers',
    zodToJsonSchema(cliProvidersSchema, { target: 'jsonSchema7', name: 'cli-providers' }) as Record<string, unknown>,
  );

  const providerValidator = compileValidator(
    'cli-provider',
    zodToJsonSchema(cliProviderSchema, { target: 'jsonSchema7', name: 'cli-provider' }) as Record<string, unknown>,
  );

  const providerNamesValidator = compileValidator(
    'cli-provider-names',
    zodToJsonSchema(cliProviderNamesSchema, { target: 'jsonSchema7', name: 'cli-provider-names' }) as Record<string, unknown>,
  );

  const versionData = runCli(dll, ['version']);
  validate('comparevi-cli version', versionData, versionValidator);

  const tokenizeData = runCli(dll, ['tokenize', '--input', 'foo -x=1 "bar baz"']);
  validate('comparevi-cli tokenize', tokenizeData, tokenizeValidator);

  const quoteData = runCli(dll, ['quote', '--path', 'C:/Program Files/National Instruments/LabVIEW 2025/LabVIEW.exe']);
  validate('comparevi-cli quote', quoteData, quoteValidator);

  const procsData = runCli(dll, ['procs']);
  validate('comparevi-cli procs', procsData, procsValidator);

  const operationsData = runCli(dll, ['operations']);
  validate('comparevi-cli operations', operationsData, operationsValidator);

  const operationsNamesData = runCli(dll, ['operations', '--names-only']);
  validate('comparevi-cli operations --names-only', operationsNamesData, operationNamesValidator);

  const providersData = runCli(dll, ['providers']);
  validate('comparevi-cli providers', providersData, providersValidator);

  const providerNamesData = runCli(dll, ['providers', '--names-only']);
  validate('comparevi-cli providers --names-only', providerNamesData, providerNamesValidator);

  const providerNames =
    providerNamesData &&
    typeof providerNamesData === 'object' &&
    Array.isArray((providerNamesData as { names?: unknown }).names)
      ? ((providerNamesData as { names?: unknown[] }).names as unknown[])
      : [];

  let providerId = providerNames.find((name): name is string => typeof name === 'string' && name.length > 0);

  if (!providerId &&
      providersData &&
      typeof providersData === 'object' &&
      Array.isArray((providersData as { providers?: unknown }).providers)) {
    const firstProvider = (providersData as { providers?: unknown[] }).providers?.[0];
    if (firstProvider && typeof firstProvider === 'object' && typeof (firstProvider as { id?: unknown }).id === 'string') {
      providerId = (firstProvider as { id: string }).id;
    }
  }

  if (!providerId) {
    throw new Error('comparevi-cli providers did not return any provider identifiers to validate.');
  }

  const providerData = runCli(dll, ['providers', '--name', providerId]);
  validate(`comparevi-cli providers --name ${providerId}`, providerData, providerValidator);

  const metaData = readArtifactMeta();
  if (metaData) {
    const metaValidator = compileValidator(
      'cli-artifact-meta',
      zodToJsonSchema(cliArtifactMetaSchema, { target: 'jsonSchema7', name: 'cli-artifact-meta' }) as Record<string, unknown>,
    );
    validate('cli artifact meta', metaData, metaValidator);
  }

  // eslint-disable-next-line no-console
  console.log('comparevi-cli outputs validated successfully.');
}

main();
