import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { ArgumentParser } from 'argparse';
import { z } from 'zod';
const configItemSchema = z.object({
    url: z.string().url(),
    status: z.string().min(1),
    program: z.string().min(1),
    phase: z.string().min(1),
    environmentClass: z.string().min(1),
    blockingSignal: z.string().min(1),
    evidenceState: z.string().min(1),
});
const configSchema = z.object({
    schema: z.literal('project-portfolio-config@v1'),
    owner: z.string().min(1),
    number: z.number().int().positive(),
    title: z.string().min(1),
    shortDescription: z.string().min(1),
    readme: z.string().min(1),
    public: z.boolean(),
    allowAdditionalItems: z.boolean().default(false),
    repositories: z.array(z.string().min(1)).min(1),
    items: z.array(configItemSchema).min(1),
});
const viewSchema = z.object({
    id: z.string().min(1),
    number: z.number().int().positive(),
    title: z.string().min(1),
    shortDescription: z.string().min(1),
    readme: z.string().min(1),
    public: z.boolean(),
    url: z.string().url(),
    items: z.object({ totalCount: z.number().int().nonnegative() }),
    fields: z.object({ totalCount: z.number().int().nonnegative() }),
    owner: z.object({ login: z.string().min(1), type: z.string().min(1) }),
}).passthrough();
const fieldsSchema = z.object({
    totalCount: z.number().int().nonnegative(),
    fields: z.array(z.object({
        id: z.string().min(1),
        name: z.string().min(1),
        type: z.string().min(1),
    }).passthrough()),
});
const rawItemSchema = z.object({
    id: z.string().min(1),
    title: z.string().min(1).optional(),
    labels: z.array(z.string()).optional(),
    content: z.object({
        url: z.string().url().optional(),
        title: z.string().min(1).optional(),
        repository: z.string().min(1).optional(),
    }).passthrough().optional(),
}).passthrough();
const itemListSchema = z.object({
    totalCount: z.number().int().nonnegative(),
    items: z.array(rawItemSchema),
});
function readJsonFile(filePath) {
    return JSON.parse(readFileSync(filePath, 'utf8'));
}
function writeJsonFile(filePath, value) {
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}
function resolvePath(maybeRelative) {
    return resolve(process.cwd(), maybeRelative);
}
function runGhJson(args) {
    const result = spawnSync('gh', args, {
        cwd: process.cwd(),
        encoding: 'utf8',
    });
    if (result.status !== 0) {
        throw new Error((result.stderr || result.stdout || 'gh command failed').trim());
    }
    return JSON.parse(result.stdout);
}
function loadJsonInput(maybeFile, schema, ghArgs) {
    const payload = maybeFile ? readJsonFile(resolvePath(maybeFile)) : runGhJson(ghArgs);
    return schema.parse(payload);
}
function fieldValue(item, name) {
    const match = Object.entries(item).find(([key]) => key.trim().toLowerCase() === name.trim().toLowerCase());
    return typeof match?.[1] === 'string' ? match[1] : null;
}
function normalizeItem(item) {
    const content = item.content ?? {};
    return {
        id: item.id,
        url: typeof content.url === 'string' ? content.url : `project-item:${item.id}`,
        title: typeof item.title === 'string' ? item.title : typeof content.title === 'string' ? content.title : item.id,
        repository: typeof content.repository === 'string' ? content.repository : null,
        labels: Array.isArray(item.labels) ? item.labels.filter((value) => typeof value === 'string') : [],
        status: fieldValue(item, 'Status'),
        program: fieldValue(item, 'Program'),
        phase: fieldValue(item, 'Phase'),
        environmentClass: fieldValue(item, 'Environment Class'),
        blockingSignal: fieldValue(item, 'Blocking Signal'),
        evidenceState: fieldValue(item, 'Evidence State'),
    };
}
function compareProject(config, view, items) {
    const actualByUrl = new Map(items.map((item) => [item.url, item]));
    const expectedByUrl = new Map(config.items.map((item) => [item.url, item]));
    const metadata = [];
    if (view.title !== config.title) {
        metadata.push({ field: 'title', expected: config.title, actual: view.title });
    }
    if (view.shortDescription !== config.shortDescription) {
        metadata.push({ field: 'shortDescription', expected: config.shortDescription, actual: view.shortDescription });
    }
    if (view.readme !== config.readme) {
        metadata.push({ field: 'readme', expected: config.readme, actual: view.readme });
    }
    if (view.public !== config.public) {
        metadata.push({ field: 'public', expected: config.public, actual: view.public });
    }
    const missingItems = config.items
        .filter((item) => !actualByUrl.has(item.url))
        .map((item) => item.url)
        .sort((a, b) => a.localeCompare(b));
    const extraItems = config.allowAdditionalItems
        ? []
        : items
            .filter((item) => !expectedByUrl.has(item.url))
            .map((item) => item.url)
            .sort((a, b) => a.localeCompare(b));
    const fieldMismatches = [];
    for (const expected of config.items) {
        const actual = actualByUrl.get(expected.url);
        if (!actual) {
            continue;
        }
        const drifts = [];
        if (actual.status !== expected.status) {
            drifts.push({ field: 'status', expected: expected.status, actual: actual.status });
        }
        if (actual.program !== expected.program) {
            drifts.push({ field: 'program', expected: expected.program, actual: actual.program });
        }
        if (actual.phase !== expected.phase) {
            drifts.push({ field: 'phase', expected: expected.phase, actual: actual.phase });
        }
        if (actual.environmentClass !== expected.environmentClass) {
            drifts.push({
                field: 'environmentClass',
                expected: expected.environmentClass,
                actual: actual.environmentClass,
            });
        }
        if (actual.blockingSignal !== expected.blockingSignal) {
            drifts.push({ field: 'blockingSignal', expected: expected.blockingSignal, actual: actual.blockingSignal });
        }
        if (actual.evidenceState !== expected.evidenceState) {
            drifts.push({ field: 'evidenceState', expected: expected.evidenceState, actual: actual.evidenceState });
        }
        if (drifts.length > 0) {
            fieldMismatches.push({ url: expected.url, drifts });
        }
    }
    const actualRepositories = [...new Set(items.map((item) => item.repository).filter((value) => Boolean(value)))].sort();
    const missingRepositories = config.repositories
        .filter((repository) => !actualRepositories.includes(repository))
        .sort((a, b) => a.localeCompare(b));
    const unexpectedRepositories = actualRepositories
        .filter((repository) => !config.repositories.includes(repository))
        .sort((a, b) => a.localeCompare(b));
    return {
        ok: metadata.length === 0 &&
            missingItems.length === 0 &&
            extraItems.length === 0 &&
            fieldMismatches.length === 0 &&
            missingRepositories.length === 0 &&
            unexpectedRepositories.length === 0,
        metadata,
        missingItems,
        extraItems,
        fieldMismatches,
        missingRepositories,
        unexpectedRepositories,
    };
}
function buildParser() {
    const parser = new ArgumentParser({
        description: 'Snapshot or verify the compare-vi-cli-action portfolio GitHub Project.',
    });
    parser.add_argument('mode', {
        choices: ['snapshot', 'check'],
        help: 'Whether to only write a snapshot report or fail on drift.',
    });
    parser.add_argument('--config', {
        required: false,
        help: 'Path to the source-controlled project portfolio config JSON.',
    });
    parser.add_argument('--out', {
        required: false,
        help: 'Path for the output report JSON.',
    });
    parser.add_argument('--owner', {
        required: false,
        help: 'Project owner login override.',
    });
    parser.add_argument('--number', {
        required: false,
        type: 'int',
        help: 'Project number override.',
    });
    parser.add_argument('--view-file', {
        required: false,
        help: 'Optional path to a captured gh project view JSON payload.',
    });
    parser.add_argument('--fields-file', {
        required: false,
        help: 'Optional path to a captured gh project field-list JSON payload.',
    });
    parser.add_argument('--item-file', {
        required: false,
        help: 'Optional path to a captured gh project item-list JSON payload.',
    });
    return parser;
}
function main() {
    const parser = buildParser();
    const args = parser.parse_args();
    const configPath = resolvePath(args.config ?? 'tools/priority/project-portfolio.json');
    if (!existsSync(configPath)) {
        throw new Error(`Project portfolio config not found: ${configPath}`);
    }
    const config = configSchema.parse(readJsonFile(configPath));
    const owner = args.owner ?? config.owner;
    const number = args.number ?? config.number;
    const view = loadJsonInput(args.view_file, viewSchema, ['project', 'view', String(number), '--owner', owner, '--format', 'json']);
    const fields = loadJsonInput(args.fields_file, fieldsSchema, ['project', 'field-list', String(number), '--owner', owner, '--format', 'json']);
    const itemList = loadJsonInput(args.item_file, itemListSchema, ['project', 'item-list', String(number), '--owner', owner, '--limit', '100', '--format', 'json']);
    const normalizedItems = itemList.items
        .map(normalizeItem)
        .sort((a, b) => a.url.localeCompare(b.url));
    const drift = compareProject(config, view, normalizedItems);
    const report = {
        schema: 'project-portfolio-report@v1',
        generatedAt: new Date().toISOString(),
        mode: args.mode,
        configPath,
        project: {
            owner,
            number,
            id: view.id,
            title: view.title,
            shortDescription: view.shortDescription,
            public: view.public,
            url: view.url,
            itemCount: itemList.totalCount,
            fieldCount: fields.totalCount,
            repositories: [...new Set(normalizedItems.map((item) => item.repository).filter((value) => Boolean(value)))].sort(),
        },
        fields: fields.fields
            .map((field) => ({ id: field.id, name: field.name, type: field.type }))
            .sort((a, b) => a.name.localeCompare(b.name)),
        items: normalizedItems,
        drift,
    };
    const outPath = resolvePath(args.out ?? 'tests/results/_agent/project/portfolio-snapshot.json');
    writeJsonFile(outPath, report);
    const statusLabel = drift.ok ? '[info]' : '[warn]';
    // eslint-disable-next-line no-console
    console.log(`${statusLabel} Project ${owner}#${number} snapshot written to ${outPath}`);
    // eslint-disable-next-line no-console
    console.log(`${statusLabel} Items expected=${config.items.length} actual=${normalizedItems.length} drift=${drift.ok ? 'none' : 'present'}`);
    if (args.mode === 'check' && !drift.ok) {
        throw new Error('Project portfolio drift detected. Review the JSON report for details.');
    }
}
main();
