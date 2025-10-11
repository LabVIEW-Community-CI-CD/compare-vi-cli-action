
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { loadSessionIndexRequirements, SessionIndexRequirement } from './requirements.js';

interface CheckOptions {
  filePath: string;
  baseDir: string;
}

interface Violation {
  requirement: SessionIndexRequirement;
  message: string;
}

function parseArgs(argv: string[]): CheckOptions {
  const options: CheckOptions = {
    filePath: '',
    baseDir: process.cwd()
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--file' || arg === '-f') {
      options.filePath = argv[++i];
    } else if (arg === '--base') {
      options.baseDir = argv[++i];
    }
  }

  if (!options.filePath) {
    throw new Error('Missing --file <session-index.v2.json> argument.');
  }

  return options;
}

function getValue(subject: unknown, dotPath: string): unknown {
  if (!dotPath) {
    return subject;
  }
  const segments = dotPath.split('.');
  let current: unknown = subject;
  for (const segment of segments) {
    if (current === null || current === undefined) {
      return undefined;
    }
    if (typeof current !== 'object') {
      return undefined;
    }
    current = (current as Record<string, unknown>)[segment];
  }
  return current;
}

function isNonEmptyString(value: unknown): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

function isNonEmptyArray(value: unknown): value is unknown[] {
  return Array.isArray(value) && value.length > 0;
}

function evaluateRequirement(
  requirement: SessionIndexRequirement,
  sessionIndex: Record<string, unknown>
): Violation | null {
  const value = getValue(sessionIndex, requirement.path);

  switch (requirement.rule) {
    case 'required':
      if (value === undefined || value === null) {
        return {
          requirement,
          message: `Path '${requirement.path}' is missing`
        };
      }
      break;
    case 'nonEmptyArray':
      if (!isNonEmptyArray(value)) {
        return {
          requirement,
          message: `Path '${requirement.path}' must be a non-empty array`
        };
      }
      break;
    case 'nonEmptyString':
      if (!isNonEmptyString(value)) {
        return {
          requirement,
          message: `Path '${requirement.path}' must be a non-empty string`
        };
      }
      break;
    case 'everyCaseHas': {
      if (!isNonEmptyArray(value)) {
        return {
          requirement,
          message: `Path '${requirement.path}' must be a non-empty array`
        };
      }
      const missing = value.filter(
        (item) =>
          typeof item !== 'object' ||
          item === null ||
          !isNonEmptyString(
            (item as Record<string, unknown>)[requirement.field ?? '']
          )
      );
      if (missing.length > 0) {
        return {
          requirement,
          message: `Not all entries under '${requirement.path}' provide '${requirement.field}'`
        };
      }
      break;
    }
    default:
      throw new Error(`Unknown requirement rule '${requirement.rule}'.`);
  }

  return null;
}

function run(): void {
  try {
    const options = parseArgs(process.argv);
    const sessionPath = path.resolve(process.cwd(), options.filePath);
    const raw = readFileSync(sessionPath, 'utf8');
    const sessionIndex = JSON.parse(raw) as Record<string, unknown>;

    const requirements = loadSessionIndexRequirements(options.baseDir);
    const violations: Violation[] = [];

    for (const requirement of requirements) {
      const violation = evaluateRequirement(requirement, sessionIndex);
      if (violation) {
        violations.push(violation);
      }
    }

    if (violations.length === 0) {
      console.log('Session index v2 requirements satisfied.');
      process.exit(0);
    }

    let exitCode = 0;
    for (const violation of violations) {
      const prefix =
        violation.requirement.severity === 'error' ? 'ERROR' : 'WARN';
      const message = `${prefix}: [${violation.requirement.id}] ${violation.message} – ${violation.requirement.description}`;
      if (violation.requirement.severity === 'error') {
        console.error(message);
        exitCode = 1;
      } else {
        console.warn(message);
      }
    }

    process.exit(exitCode);
  } catch (error) {
    console.error(`session-index:check failed – ${(error as Error).message}`);
    process.exit(1);
  }
}

run();
