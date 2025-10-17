import '../bootstrap/node-deprecations.js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ArgumentParser } from 'argparse';
import fg from 'fast-glob';
import Ajv from 'ajv';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
function readJson(path) {
    try {
        const raw = readFileSync(path, 'utf8');
        return JSON.parse(raw);
    }
    catch (err) {
        throw new Error(`Failed to parse JSON from ${path}: ${err.message}`);
    }
}
function main() {
    const parser = new ArgumentParser({
        description: 'Validate JSON documents against a schema using Ajv 2020.',
    });
    parser.add_argument('--schema', { required: true, help: 'Path to JSON schema file.' });
    parser.add_argument('--data', {
        required: true,
        action: 'append',
        help: 'Data file glob(s) to validate. Can be specified multiple times.',
    });
    parser.add_argument('--optional', {
        action: 'store_true',
        help: 'Do not error when data globs match no files.',
    });
    const args = parser.parse_args();
    const schemaPath = resolve(process.cwd(), args.schema);
    const schema = readJson(schemaPath);
    const schemaObj = (schema ?? {});
    const schemaMeta = typeof schemaObj.$schema === 'string' ? schemaObj.$schema : '';
    const ajv = schemaMeta.includes('2020-12')
        ? new Ajv2020({ allErrors: true, strict: false, allowUnionTypes: true })
        : new Ajv({ allErrors: true, strict: false, allowUnionTypes: true });
    addFormats(ajv);
    const validate = ajv.compile(schema);
    let matched = 0;
    const globOptions = {
        cwd: process.cwd(),
        absolute: true,
        onlyFiles: true,
    };
    for (const pattern of args.data) {
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
                const issues = (validate.errors ?? []).map((err) => `${err.instancePath || '/'} ${err.message ?? ''}`.trim());
                throw new Error(`Validation failed for ${file}:\n${issues.join('\n')}`);
            }
        }
    }
    if (matched === 0) {
        // eslint-disable-next-line no-console
        console.log('[schema] No data files validated (globs empty).');
    }
    else {
        // eslint-disable-next-line no-console
        console.log(`[schema] Validated ${matched} file(s) against ${schemaPath}.`);
    }
}
main();
