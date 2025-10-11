import { ArgumentParser } from 'argparse';
import process from 'node:process';
import { resolveToggleManifest, getAvailableToggleProfiles } from './toggles.js';
const parser = new ArgumentParser({
    description: 'Agent toggle manifest CLI'
});
parser.add_argument('--profile', {
    action: 'append',
    dest: 'profiles',
    help: 'Toggle profile to apply (can be specified multiple times). Defaults to ci-orchestrated.'
});
parser.add_argument('--format', {
    choices: ['values', 'env', 'psd1'],
    default: 'values',
    help: 'Output format. Defaults to values (JSON).'
});
parser.add_argument('--pretty', {
    action: 'store_true',
    help: 'Pretty-print JSON output (values format only).'
});
parser.add_argument('--list-profiles', {
    action: 'store_true',
    help: 'List available profiles and exit.'
});
function listProfiles() {
    const profiles = getAvailableToggleProfiles()
        .map((profile) => {
        const extendsLabel = profile.extends && profile.extends.length > 0
            ? ` (extends: ${profile.extends.join(', ')})`
            : '';
        return `- ${profile.name}${extendsLabel}${profile.description ? ` — ${profile.description}` : ''}`;
    })
        .join('\n');
    process.stdout.write('Available toggle profiles:\n');
    process.stdout.write(`${profiles}\n`);
}
function emitValues(profiles, pretty) {
    const manifest = resolveToggleManifest({ profiles });
    const spacing = pretty ? 2 : undefined;
    const json = JSON.stringify(manifest, null, spacing);
    process.stdout.write(`${json}\n`);
}
function emitEnv(profiles) {
    const manifest = resolveToggleManifest({ profiles });
    const lines = [];
    lines.push(`AGENT_TOGGLE_MANIFEST_DIGEST=${manifest.manifestDigest}`);
    lines.push(`AGENT_TOGGLE_PROFILES=${manifest.profiles.join(',')}`);
    lines.push(`AGENT_TOGGLE_RESOLVED_PROFILES=${manifest.resolvedProfiles.join(',')}`);
    if (manifest.metadata?.hashAlgorithm) {
        lines.push(`AGENT_TOGGLE_HASH_ALGORITHM=${manifest.metadata.hashAlgorithm}`);
    }
    for (const [key, value] of Object.entries(manifest.toggles)) {
        lines.push(`${key}=${value}`);
    }
    process.stdout.write(`${lines.join('\n')}\n`);
}
function emitPsd1(profiles) {
    const manifest = resolveToggleManifest({ profiles });
    const toggleLines = Object.entries(manifest.toggles)
        .map(([key, value]) => `    ${key} = '${value}'`)
        .join('\n');
    const psd1 = [
        '@{',
        `  Profiles        = @(${manifest.profiles.map((profile) => `'${profile}'`).join(', ')})`,
        `  ResolvedProfiles = @(${manifest.resolvedProfiles.map((profile) => `'${profile}'`).join(', ')})`,
        `  ManifestDigest  = '${manifest.manifestDigest}'`,
        manifest.metadata?.hashAlgorithm
            ? `  HashAlgorithm   = '${manifest.metadata.hashAlgorithm}'`
            : undefined,
        '  Toggles         = @{',
        toggleLines,
        '  }',
        '}'
    ]
        .filter((line) => Boolean(line))
        .join('\n');
    process.stdout.write(`${psd1}\n`);
}
function run() {
    const args = parser.parse_args();
    if (args.list_profiles) {
        listProfiles();
        return;
    }
    try {
        switch (args.format) {
            case 'values':
                emitValues(args.profiles, args.pretty);
                break;
            case 'env':
                emitEnv(args.profiles);
                break;
            case 'psd1':
                emitPsd1(args.profiles);
                break;
            default:
                throw new Error(`Unsupported format: ${args.format}`);
        }
    }
    catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        process.stderr.write(`Toggle CLI failed: ${message}\n`);
        process.exitCode = 1;
    }
}
run();
