import process from 'node:process';
import { resolveToggleManifest, getAvailableToggleProfiles } from './toggles.js';

type OutputFormat = 'values' | 'env' | 'psd1';

interface ParsedArgs {
  profiles: string[];
  format: OutputFormat;
  pretty: boolean;
  listProfiles: boolean;
}

const FLAG_ALIAS: Record<string, keyof ParsedArgs | 'pushProfile'> = {
  '--profile': 'pushProfile',
  '-p': 'pushProfile',
  '--format': 'format',
  '-f': 'format',
  '--pretty': 'pretty',
  '--list-profiles': 'listProfiles'
};

const FORMAT_VALUES = new Set<OutputFormat>(['values', 'env', 'psd1']);

function parseArgs(argv: string[]): ParsedArgs {
  const result: ParsedArgs = {
    profiles: [],
    format: 'values',
    pretty: false,
    listProfiles: false
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const flag = FLAG_ALIAS[token];

    if (!flag) {
      throw new Error(`Unknown argument: ${token}`);
    }

    if (flag === 'pushProfile') {
      const value = argv[i + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing profile value after ${token}`);
      }
      result.profiles.push(value);
      i += 1;
      continue;
    }

    if (flag === 'format') {
      const value = argv[i + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing format value after ${token}`);
      }
      if (!FORMAT_VALUES.has(value as OutputFormat)) {
        const options = Array.from(FORMAT_VALUES).join(', ');
        throw new Error(`Unsupported format: ${value}. Valid options: ${options}`);
      }
      result.format = value as OutputFormat;
      i += 1;
      continue;
    }

    if (flag === 'pretty') {
      result.pretty = true;
      continue;
    }

    if (flag === 'listProfiles') {
      result.listProfiles = true;
    }
  }

  return result;
}

function listProfiles(): void {
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

function emitValues(profiles: string[] | undefined, pretty: boolean | undefined): void {
  const manifest = resolveToggleManifest({ profiles });
  const spacing = pretty ? 2 : undefined;
  const json = JSON.stringify(manifest, null, spacing);
  process.stdout.write(`${json}\n`);
}

function emitEnv(profiles: string[] | undefined): void {
  const manifest = resolveToggleManifest({ profiles });
  const lines: string[] = [];
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

function emitPsd1(profiles: string[] | undefined): void {
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
    .filter((line): line is string => Boolean(line))
    .join('\n');

  process.stdout.write(`${psd1}\n`);
}

function run(): void {
  const args = parseArgs(process.argv.slice(2));

  if (args.listProfiles) {
    listProfiles();
    return;
  }

  try {
    switch (args.format) {
      case 'values':
        emitValues(args.profiles.length > 0 ? args.profiles : undefined, args.pretty);
        break;
      case 'env':
        emitEnv(args.profiles.length > 0 ? args.profiles : undefined);
        break;
      case 'psd1':
        emitPsd1(args.profiles.length > 0 ? args.profiles : undefined);
        break;
      default:
        throw new Error(`Unsupported format: ${args.format}`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Toggle CLI failed: ${message}\n`);
    process.exitCode = 1;
  }
}

run();
