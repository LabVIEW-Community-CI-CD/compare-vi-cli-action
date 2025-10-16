import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import { zodToJsonSchema } from 'zod-to-json-schema';
import { cliArtifactMetaSchema, cliOperationsSchema, cliQuoteSchema, cliProcsSchema, cliTokenizeSchema, cliVersionSchema, } from '../schemas/definitions.js';
function resolveCliDll() {
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
function runCli(dllPath, args) {
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
        return JSON.parse(stdout);
    }
    catch (err) {
        throw new Error(`Failed to parse JSON from comparevi-cli ${args.join(' ')}: ${err.message}\nOutput:\n${stdout}`);
    }
}
function compileValidator(schemaId, jsonSchema) {
    const ajv = new Ajv({
        allErrors: true,
        strict: false,
    });
    addFormats(ajv);
    return ajv.compile(jsonSchema);
}
function validate(name, data, validateFn) {
    const ok = validateFn(data);
    if (!ok) {
        const errors = validateFn.errors?.map((e) => `${e.instancePath} ${e.message ?? ''}`.trim()).join('\n') ?? 'Unknown validation error';
        throw new Error(`Validation failed for ${name}:\n${errors}`);
    }
}
function readArtifactMeta() {
    const metaPath = join(process.cwd(), 'tests', 'results', '_cli', 'meta.json');
    if (!existsSync(metaPath)) {
        return null;
    }
    const raw = readFileSync(metaPath, 'utf8');
    return JSON.parse(raw);
}
function main() {
    const dll = resolveCliDll();
    const versionValidator = compileValidator('cli-version', zodToJsonSchema(cliVersionSchema, { target: 'jsonSchema7', name: 'cli-version' }));
    const tokenizeValidator = compileValidator('cli-tokenize', zodToJsonSchema(cliTokenizeSchema, { target: 'jsonSchema7', name: 'cli-tokenize' }));
    const quoteValidator = compileValidator('cli-quote', zodToJsonSchema(cliQuoteSchema, { target: 'jsonSchema7', name: 'cli-quote' }));
    const procsValidator = compileValidator('cli-procs', zodToJsonSchema(cliProcsSchema, { target: 'jsonSchema7', name: 'cli-procs' }));
    const operationsValidator = compileValidator('cli-operations', zodToJsonSchema(cliOperationsSchema, { target: 'jsonSchema7', name: 'cli-operations' }));
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
    const metaData = readArtifactMeta();
    if (metaData) {
        const metaValidator = compileValidator('cli-artifact-meta', zodToJsonSchema(cliArtifactMetaSchema, { target: 'jsonSchema7', name: 'cli-artifact-meta' }));
        validate('cli artifact meta', metaData, metaValidator);
    }
    // eslint-disable-next-line no-console
    console.log('comparevi-cli outputs validated successfully.');
}
main();
