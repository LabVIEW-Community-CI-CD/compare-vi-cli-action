
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  evaluateRequirements,
  formatViolationMessage,
  hasErrorViolations
} from './requirements-check.js';
import { loadSessionIndexRequirements } from './requirements.js';

interface CheckOptions {
  filePath: string;
  baseDir: string;
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

function run(): void {
  try {
    const options = parseArgs(process.argv);
    const sessionPath = path.resolve(process.cwd(), options.filePath);
    const raw = readFileSync(sessionPath, 'utf8');
    const sessionIndex = JSON.parse(raw) as Record<string, unknown>;

    const requirements = loadSessionIndexRequirements(options.baseDir);
    const violations = evaluateRequirements(sessionIndex, requirements);

    if (violations.length === 0) {
      console.log('Session index v2 requirements satisfied.');
      process.exit(0);
    }

    const errorViolations = hasErrorViolations(violations);
    for (const violation of violations) {
      const message = formatViolationMessage(violation);
      if (violation.requirement.severity === 'error') {
        console.error(message);
      } else {
        console.warn(message);
      }
    }

    process.exit(errorViolations ? 1 : 0);
  } catch (error) {
    console.error(`session-index:check failed – ${(error as Error).message}`);
    process.exit(1);
  }
}

run();
