import { readFileSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';
const DEFAULT_ADR_PATH = path.join('docs', 'adr', '0004-session-index-v2-requirements.md');
const FRONT_MATTER_REGEX = /^---\s*[\r\n]+([\s\S]*?)\r?\n---/;
function parseFrontMatter(content) {
    const match = FRONT_MATTER_REGEX.exec(content);
    if (!match) {
        return {};
    }
    const yamlBlock = match[1];
    try {
        const parsed = yaml.load(yamlBlock);
        return (parsed ?? {});
    }
    catch (error) {
        throw new Error(`Unable to parse ADR front matter: ${error.message}`);
    }
}
function coerceRequirement(raw) {
    const id = typeof raw.id === 'string' ? raw.id : null;
    const description = typeof raw.description === 'string' ? raw.description : null;
    const pathValue = typeof raw.path === 'string' ? raw.path : null;
    const rule = typeof raw.rule === 'string' ? raw.rule : null;
    const severity = raw.severity === 'error' || raw.severity === 'warning'
        ? raw.severity
        : null;
    if (!id || !description || !pathValue || !rule || !severity) {
        return null;
    }
    const requirement = {
        id,
        description,
        path: pathValue,
        rule: rule,
        severity
    };
    if (raw.field && typeof raw.field === 'string') {
        requirement.field = raw.field;
    }
    return requirement;
}
export function loadSessionIndexRequirements(baseDir = process.cwd(), adrPath = DEFAULT_ADR_PATH) {
    const resolved = path.resolve(baseDir, adrPath);
    const content = readFileSync(resolved, 'utf8');
    const frontMatter = parseFrontMatter(content);
    const rawRequirements = frontMatter.requirements ?? [];
    const requirements = [];
    for (const entry of rawRequirements) {
        if (!entry || typeof entry !== 'object') {
            continue;
        }
        const requirement = coerceRequirement(entry);
        if (requirement) {
            requirements.push(requirement);
        }
    }
    return requirements;
}
