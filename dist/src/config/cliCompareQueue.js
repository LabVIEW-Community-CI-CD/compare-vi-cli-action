import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import { cliCompareQueueCaseSchema, cliCompareQueueSchema, cliCompareQueueSummarySchema, } from '../schema/cli-compare.js';
function readJsonFile(path) {
    const fullPath = resolvePath(path);
    const raw = readFileSync(fullPath, 'utf8');
    try {
        return JSON.parse(raw);
    }
    catch (error) {
        const message = error.message;
        throw new Error(`Failed to parse JSON from ${fullPath}: ${message}`);
    }
}
export function loadCliCompareQueue(path) {
    const json = readJsonFile(path);
    return cliCompareQueueSchema.parse(json);
}
export function loadCliCompareQueueSummary(path) {
    const json = readJsonFile(path);
    return cliCompareQueueSummarySchema.parse(json);
}
export function validateCliCompareCase(candidate) {
    return cliCompareQueueCaseSchema.parse(candidate);
}
export function filterCasesByTag(queue, tag) {
    const normalized = tag.trim().toLowerCase();
    return queue.cases.filter((c) => c.tags?.some((t) => t.toLowerCase() === normalized));
}
export function getCaseById(queue, id) {
    const normalized = id.trim().toLowerCase();
    return queue.cases.find((c) => c.id.toLowerCase() === normalized);
}
export function enabledCases(queue) {
    return queue.cases.filter((c) => !c.disabled);
}
