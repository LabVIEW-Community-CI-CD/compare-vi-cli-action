import type { SessionIndexRequirement } from './requirements.js';

export interface RequirementViolation {
  requirement: SessionIndexRequirement;
  message: string;
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

export function evaluateRequirement(
  requirement: SessionIndexRequirement,
  sessionIndex: Record<string, unknown>
): RequirementViolation | null {
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

export function evaluateRequirements(
  sessionIndex: Record<string, unknown>,
  requirements: SessionIndexRequirement[]
): RequirementViolation[] {
  const violations: RequirementViolation[] = [];
  for (const requirement of requirements) {
    const violation = evaluateRequirement(requirement, sessionIndex);
    if (violation) {
      violations.push(violation);
    }
  }
  return violations;
}

export function hasErrorViolations(violations: RequirementViolation[]): boolean {
  return violations.some((violation) => violation.requirement.severity === 'error');
}

export function formatViolationMessage(violation: RequirementViolation): string {
  const prefix = violation.requirement.severity === 'error' ? 'ERROR' : 'WARN';
  return `${prefix}: [${violation.requirement.id}] ${violation.message} – ${violation.requirement.description}`;
}
