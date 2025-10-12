import { createHash } from 'node:crypto';
const DEFAULT_SCHEMA_VERSION = '1.0.0';
function escapeForRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
function patternToRegex(pattern) {
    const escaped = escapeForRegex(pattern).replace(/\\\*/g, '.*');
    return new RegExp(`^${escaped}$`, 'i');
}
function sortStrings(values) {
    const next = Array.from(values);
    next.sort((a, b) => a.localeCompare(b));
    return next;
}
function matchesPattern(pattern, value) {
    if (!pattern) {
        return true;
    }
    if (!value) {
        return false;
    }
    const regex = patternToRegex(pattern);
    return regex.test(value);
}
function matchesTags(required, candidate) {
    if (!required || required.length === 0) {
        return true;
    }
    if (!candidate || candidate.length === 0) {
        return false;
    }
    const candidateSet = new Set(candidate.map((tag) => tag.toLowerCase()));
    return required.every((tag) => candidateSet.has(tag.toLowerCase()));
}
function matchesContext(match, context) {
    if (!match) {
        return false;
    }
    const describeMatch = matchesPattern(match.describe, context.describe);
    const itMatch = matchesPattern(match.it, context.it);
    const tagsMatch = matchesTags(match.tags, context.tags);
    return describeMatch && itMatch && tagsMatch;
}
export function createToggleManifest(now = new Date()) {
    const manifest = {
        schema: 'agent-toggles/v1',
        schemaVersion: DEFAULT_SCHEMA_VERSION,
        generatedAtUtc: now.toISOString(),
        toggles: [
            {
                key: 'SKIP_SYNC_DEVELOP',
                description: 'Skip automatic develop branch sync during bootstrap (set to 1/true only when a frozen snapshot is required).',
                type: 'boolean',
                defaultValue: false,
                scopes: ['global', 'bootstrap'],
                tags: ['git', 'workflow', 'bootstrap'],
                docs: ['AGENTS.md#first-actions-in-a-session'],
                variants: [
                    {
                        id: 'suite-dev-dashboard',
                        description: 'Dev-Dashboard suites always exercise sync logic regardless of env overrides.',
                        value: false,
                        match: {
                            describe: 'Dev Dashboard*'
                        }
                    }
                ]
            },
            {
                key: 'HANDOFF_AUTOTRIM',
                description: 'Automatically trim watcher logs during agent hand-off when telemetry indicates oversize and cooldown permits.',
                type: 'boolean',
                defaultValue: false,
                scopes: ['watcher', 'handoff'],
                tags: ['watcher', 'telemetry'],
                docs: ['AGENT_HANDOFF.txt', 'AGENTS.md#agent-hand-off--telemetry'],
                variants: [
                    {
                        id: 'watcher-tests',
                        description: 'Enable auto trim within watcher-focused Pester suites to validate trimming behaviour.',
                        value: true,
                        match: {
                            tags: ['watcher']
                        }
                    }
                ]
            },
            {
                key: 'LV_SUPPRESS_UI',
                description: 'Prevent LabVIEW UI surfaces during automation (required for non-interactive runners).',
                type: 'boolean',
                defaultValue: true,
                scopes: ['labview', 'safety'],
                tags: ['labview', 'safety'],
                docs: ['AGENT_HANDOFF.txt#context-snapshot']
            },
            {
                key: 'LV_NO_ACTIVATE',
                description: 'Ensure LabVIEW does not trigger activation prompts during automation.',
                type: 'boolean',
                defaultValue: true,
                scopes: ['labview', 'safety'],
                tags: ['labview', 'safety'],
                docs: ['AGENT_HANDOFF.txt#context-snapshot']
            },
            {
                key: 'LV_CURSOR_RESTORE',
                description: 'Restore cursor state after LabVIEW automation completes.',
                type: 'boolean',
                defaultValue: true,
                scopes: ['labview', 'safety'],
                tags: ['labview'],
                docs: ['AGENT_HANDOFF.txt#context-snapshot']
            },
            {
                key: 'LV_IDLE_WAIT_SECONDS',
                description: 'Base wait duration between LabVIEW idle polls (seconds).',
                type: 'number',
                defaultValue: 2,
                scopes: ['labview', 'safety'],
                tags: ['labview', 'timing'],
                docs: ['AGENT_HANDOFF.txt#context-snapshot']
            },
            {
                key: 'LV_IDLE_MAX_WAIT_SECONDS',
                description: 'Maximum wait duration before deeming LabVIEW idle cycle as stalled (seconds).',
                type: 'number',
                defaultValue: 5,
                scopes: ['labview', 'safety'],
                tags: ['labview', 'timing'],
                docs: ['AGENT_HANDOFF.txt#context-snapshot']
            },
            {
                key: 'WIRE_PROBES',
                description: 'Controls Long-Wire probe injection (1 = enabled, 0 = disabled).',
                type: 'string',
                defaultValue: '1',
                scopes: ['ci', 'workflow'],
                tags: ['ci', 'probes'],
                docs: ['AGENTS.md#wire-probes-long-wire-v2']
            }
        ],
        profiles: [
            {
                id: 'ci-orchestrated',
                description: 'Default profile for orchestrated CI runs (hosted runners and automation agents).',
                values: {
                    HANDOFF_AUTOTRIM: true,
                    LV_SUPPRESS_UI: true,
                    LV_NO_ACTIVATE: true,
                    LV_CURSOR_RESTORE: true,
                    LV_IDLE_WAIT_SECONDS: 2,
                    LV_IDLE_MAX_WAIT_SECONDS: 5,
                    WIRE_PROBES: '1',
                    SKIP_SYNC_DEVELOP: false
                },
                tags: ['ci', 'default'],
                docs: ['.github/workflows/ci-orchestrated.yml']
            },
            {
                id: 'dev-workstation',
                description: 'Local developer defaults balancing safety with flexibility.',
                values: {
                    HANDOFF_AUTOTRIM: false,
                    LV_SUPPRESS_UI: true,
                    LV_NO_ACTIVATE: true,
                    LV_CURSOR_RESTORE: true,
                    LV_IDLE_WAIT_SECONDS: 2,
                    LV_IDLE_MAX_WAIT_SECONDS: 5,
                    SKIP_SYNC_DEVELOP: false,
                    WIRE_PROBES: '1'
                },
                tags: ['developer']
            },
            {
                id: 'labview-diagnostics',
                description: 'Profile used when intentionally permitting LabVIEW UI (e.g. debugging rogue processes).',
                inherits: ['dev-workstation'],
                values: {
                    LV_SUPPRESS_UI: false,
                    LV_NO_ACTIVATE: false
                },
                tags: ['diagnostics'],
                docs: ['docs/INTEGRATION_RUNBOOK.md']
            }
        ]
    };
    return manifest;
}
function ensureToggleExists(manifest, key) {
    const toggle = manifest.toggles.find((item) => item.key === key);
    if (!toggle) {
        throw new Error(`Toggle '${key}' referenced by profile but not defined.`);
    }
    return toggle;
}
function expandProfileOrder(manifest, profileId, seen, stack) {
    if (seen.has(profileId)) {
        return [];
    }
    const profile = manifest.profiles.find((item) => item.id === profileId);
    if (!profile) {
        throw new Error(`Unknown profile '${profileId}'.`);
    }
    if (stack.includes(profileId)) {
        throw new Error(`Circular profile inheritance detected: ${[...stack, profileId].join(' -> ')}`);
    }
    stack.push(profileId);
    const order = [];
    if (profile.inherits) {
        for (const parent of profile.inherits) {
            order.push(...expandProfileOrder(manifest, parent, seen, stack));
        }
    }
    stack.pop();
    seen.add(profileId);
    order.push(profileId);
    return order;
}
export function resolveToggleValues(manifest, context = {}) {
    const values = new Map();
    for (const toggle of manifest.toggles) {
        values.set(toggle.key, {
            key: toggle.key,
            value: toggle.defaultValue,
            valueType: toggle.type,
            source: 'default',
            description: toggle.description
        });
    }
    const requestedProfiles = context.profiles ?? [];
    const seenProfiles = new Set();
    const orderedProfiles = [];
    for (const profileId of requestedProfiles) {
        orderedProfiles.push(...expandProfileOrder(manifest, profileId, seenProfiles, []));
    }
    const appliedProfiles = new Set();
    for (const profileId of orderedProfiles) {
        if (appliedProfiles.has(profileId)) {
            continue;
        }
        appliedProfiles.add(profileId);
        const profile = manifest.profiles.find((item) => item.id === profileId);
        if (!profile) {
            continue;
        }
        for (const [key, value] of Object.entries(profile.values)) {
            const toggle = ensureToggleExists(manifest, key);
            const resolution = values.get(key);
            if (!resolution) {
                continue;
            }
            if (typeof value !== toggle.type) {
                if (!(toggle.type === 'number' && typeof value === 'number')) {
                    throw new Error(`Profile '${profileId}' provides invalid type for '${key}'.`);
                }
            }
            values.set(key, {
                key,
                value,
                valueType: toggle.type,
                source: 'profile',
                profile: profileId,
                description: toggle.description
            });
        }
    }
    const ctx = {
        ...context,
        tags: context.tags ? sortStrings(Array.from(new Set(context.tags))) : []
    };
    for (const toggle of manifest.toggles) {
        if (!toggle.variants || toggle.variants.length === 0) {
            continue;
        }
        const applicable = toggle.variants.find((variant) => matchesContext(variant.match, ctx));
        if (!applicable) {
            continue;
        }
        const resolution = values.get(toggle.key);
        if (!resolution) {
            continue;
        }
        if (typeof applicable.value !== toggle.type && !(toggle.type === 'number' && typeof applicable.value === 'number')) {
            throw new Error(`Variant '${applicable.id ?? 'unnamed'}' provides invalid type for '${toggle.key}'.`);
        }
        values.set(toggle.key, {
            key: toggle.key,
            value: applicable.value,
            valueType: toggle.type,
            source: 'variant',
            variant: applicable.id,
            description: toggle.description
        });
    }
    return values;
}
function createCanonicalManifest(manifest) {
    const clone = JSON.parse(JSON.stringify(manifest));
    clone.generatedAtUtc = '1970-01-01T00:00:00.000Z';
    return clone;
}
export function computeToggleManifestDigest(manifest) {
    const base = manifest ?? createToggleManifest(new Date(0));
    const canonical = createCanonicalManifest(base);
    const serialized = JSON.stringify(canonical);
    return createHash('sha256').update(serialized).digest('hex');
}
export function buildToggleValuesPayload(context = {}) {
    const manifest = createToggleManifest();
    const digest = computeToggleManifestDigest(manifest);
    const resolved = resolveToggleValues(manifest, context);
    const values = {};
    const profiles = context.profiles
        ? sortStrings(Array.from(new Set(context.profiles)))
        : [];
    const tags = context.tags && context.tags.length > 0
        ? sortStrings(Array.from(new Set(context.tags)))
        : undefined;
    const sortedEntries = Array.from(resolved.entries()).sort(([a], [b]) => a.localeCompare(b));
    for (const [key, resolution] of sortedEntries) {
        values[key] = { ...resolution };
    }
    return {
        schema: 'agent-toggle-values/v1',
        schemaVersion: manifest.schemaVersion,
        generatedAtUtc: manifest.generatedAtUtc,
        manifestDigest: digest,
        manifestGeneratedAtUtc: manifest.generatedAtUtc,
        profiles,
        context: {
            describe: context.describe,
            it: context.it,
            tags
        },
        values
    };
}
