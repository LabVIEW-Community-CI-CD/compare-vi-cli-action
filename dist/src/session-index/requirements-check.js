function getValue(subject, dotPath) {
    if (!dotPath) {
        return subject;
    }
    const segments = dotPath.split('.');
    let current = subject;
    for (const segment of segments) {
        if (current === null || current === undefined) {
            return undefined;
        }
        if (typeof current !== 'object') {
            return undefined;
        }
        current = current[segment];
    }
    return current;
}
function isNonEmptyString(value) {
    return typeof value === 'string' && value.trim().length > 0;
}
function isNonEmptyArray(value) {
    return Array.isArray(value) && value.length > 0;
}
export function evaluateRequirement(requirement, sessionIndex) {
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
            const missing = value.filter((item) => typeof item !== 'object' ||
                item === null ||
                !isNonEmptyString(item[requirement.field ?? '']));
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
export function evaluateRequirements(sessionIndex, requirements) {
    const violations = [];
    for (const requirement of requirements) {
        const violation = evaluateRequirement(requirement, sessionIndex);
        if (violation) {
            violations.push(violation);
        }
    }
    return violations;
}
export function hasErrorViolations(violations) {
    return violations.some((violation) => violation.requirement.severity === 'error');
}
export function formatViolationMessage(violation) {
    const prefix = violation.requirement.severity === 'error' ? 'ERROR' : 'WARN';
    return `${prefix}: [${violation.requirement.id}] ${violation.message} – ${violation.requirement.description}`;
}
