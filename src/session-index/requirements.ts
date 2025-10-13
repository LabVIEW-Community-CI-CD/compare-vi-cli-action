
import { readFileSync } from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';

export type RequirementRule =
  | 'required'
  | 'nonEmptyArray'
  | 'nonEmptyString'
  | 'everyCaseHas';

export type RequirementSeverity = 'error' | 'warning';

export interface SessionIndexRequirement {
  id: string;
  description: string;
  path: string;
  rule: RequirementRule;
  severity: RequirementSeverity;
  field?: string;
}

interface AdrFrontMatter {
  requirements?: Array<Record<string, unknown>>;
}

const DEFAULT_ADR_PATH = path.join(
  'docs',
  'adr',
  '0004-session-index-v2-requirements.md'
);

const FRONT_MATTER_REGEX = /^---\s*[\r\n]+([\s\S]*?)\r?\n---/;

function parseFrontMatter(content: string): AdrFrontMatter {
  const match = FRONT_MATTER_REGEX.exec(content);
  if (!match) {
    return {};
  }
  const yamlBlock = match[1];
  try {
    const parsed = yaml.load(yamlBlock) as Record<string, unknown>;
    return (parsed ?? {}) as AdrFrontMatter;
  } catch (error) {
    throw new Error(`Unable to parse ADR front matter: ${(error as Error).message}`);
  }
}

function coerceRequirement(
  raw: Record<string, unknown>
): SessionIndexRequirement | null {
  const id = typeof raw.id === 'string' ? raw.id : null;
  const description =
    typeof raw.description === 'string' ? raw.description : null;
  const pathValue = typeof raw.path === 'string' ? raw.path : null;
  const rule = typeof raw.rule === 'string' ? raw.rule : null;
  const severity =
    raw.severity === 'error' || raw.severity === 'warning'
      ? raw.severity
      : null;

  if (!id || !description || !pathValue || !rule || !severity) {
    return null;
  }

  const requirement: SessionIndexRequirement = {
    id,
    description,
    path: pathValue,
    rule: rule as RequirementRule,
    severity
  };

  if (raw.field && typeof raw.field === 'string') {
    requirement.field = raw.field;
  }

  return requirement;
}

export function loadSessionIndexRequirements(
  baseDir = process.cwd(),
  adrPath = DEFAULT_ADR_PATH
): SessionIndexRequirement[] {
  const resolved = path.resolve(baseDir, adrPath);
  const content = readFileSync(resolved, 'utf8');
  const frontMatter = parseFrontMatter(content);
  const rawRequirements = frontMatter.requirements ?? [];
  const requirements: SessionIndexRequirement[] = [];

  for (const entry of rawRequirements) {
    if (!entry || typeof entry !== 'object') {
      continue;
    }
    const requirement = coerceRequirement(entry as Record<string, unknown>);
    if (requirement) {
      requirements.push(requirement);
    }
  }

  return requirements;
}
