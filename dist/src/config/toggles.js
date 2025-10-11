import { createHash } from 'node:crypto';
const PROFILE_DEFINITIONS = {
    base: {
        name: 'base',
        description: 'Baseline LabVIEW focus safety toggles.',
        toggles: {
            LV_SUPPRESS_UI: '1',
            LV_NO_ACTIVATE: '1',
            LV_CURSOR_RESTORE: '1',
            LV_IDLE_WAIT_SECONDS: '2',
            LV_IDLE_MAX_WAIT_SECONDS: '5'
        }
    },
    'ci-orchestrated': {
        name: 'ci-orchestrated',
        description: 'Primary CI pipeline defaults (LabVIEW safe mode).',
        extends: ['base'],
        toggles: {}
    },
    'dev-workstation': {
        name: 'dev-workstation',
        description: 'Local developer defaults mirroring CI safeguards.',
        extends: ['base'],
        toggles: {}
    },
    'labview-diagnostics': {
        name: 'labview-diagnostics',
        description: 'Diagnostic profile retaining UI safeguards with extended idle waits.',
        extends: ['base'],
        toggles: {
            LV_IDLE_WAIT_SECONDS: '5',
            LV_IDLE_MAX_WAIT_SECONDS: '10'
        }
    }
};
function getProfileDefinition(name) {
    const definition = PROFILE_DEFINITIONS[name];
    if (!definition) {
        const available = Object.keys(PROFILE_DEFINITIONS).sort().join(', ');
        throw new Error(`Unknown toggle profile '${name}'. Available profiles: ${available}`);
    }
    return definition;
}
function applyProfile(name, result, resolved, stack) {
    if (stack.has(name)) {
        const path = Array.from(stack).concat(name).join(' -> ');
        throw new Error(`Toggle profile inheritance cycle detected: ${path}`);
    }
    const definition = getProfileDefinition(name);
    stack.add(name);
    for (const parent of definition.extends ?? []) {
        applyProfile(parent, result, resolved, stack);
    }
    if (!resolved.includes(name)) {
        resolved.push(name);
    }
    for (const [key, value] of Object.entries(definition.toggles)) {
        result[key] = value;
    }
    stack.delete(name);
}
function sortedEntries(record) {
    return Object.keys(record)
        .sort()
        .reduce((acc, key) => {
        acc[key] = record[key];
        return acc;
    }, {});
}
export function resolveToggleManifest(options) {
    const requestedProfiles = (options?.profiles && options.profiles.length > 0
        ? options.profiles
        : ['ci-orchestrated'])
        .map((profile) => profile.trim())
        .filter((profile) => profile.length > 0);
    if (requestedProfiles.length === 0) {
        requestedProfiles.push('ci-orchestrated');
    }
    const toggles = {};
    const resolvedProfiles = [];
    const stack = new Set();
    for (const profile of requestedProfiles) {
        applyProfile(profile, toggles, resolvedProfiles, stack);
    }
    if (options?.overrides) {
        for (const [key, value] of Object.entries(options.overrides)) {
            if (value === undefined || value === null) {
                continue;
            }
            toggles[key] = String(value);
        }
    }
    const canonical = sortedEntries(toggles);
    const digestPayload = JSON.stringify({
        version: 1,
        profiles: requestedProfiles,
        resolvedProfiles,
        toggles: canonical
    });
    const digest = createHash('sha256').update(digestPayload).digest('hex');
    return {
        schema: 'agent-toggles/v1',
        version: '1.0.0',
        profiles: requestedProfiles,
        resolvedProfiles,
        toggles: canonical,
        manifestDigest: digest,
        metadata: {
            hashAlgorithm: 'sha256'
        }
    };
}
export function getAvailableToggleProfiles() {
    return Object.values(PROFILE_DEFINITIONS).map((definition) => ({ ...definition }));
}
