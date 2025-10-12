import { ArgumentParser } from 'argparse';
import type { ToggleResolutionContext, ToggleValue, ToggleValuesPayload } from './toggles.js';
import { buildToggleValuesPayload, createToggleContract } from './toggles.js';

type OutputFormat = 'json' | 'values' | 'env' | 'psd1';

interface CliOptions extends ToggleResolutionContext {
  format: OutputFormat;
  pretty?: boolean;
  includeMetadata?: boolean;
}

function formatJson(value: unknown, pretty: boolean | undefined): string {
  return `${JSON.stringify(value, null, pretty ? 2 : undefined)}\n`;
}

function toEnvString(value: ToggleValue): string {
  if (typeof value === 'boolean') {
    return value ? '1' : '0';
  }
  return String(value);
}

function formatEnv(payload: ToggleValuesPayload): string {
  const lines: string[] = [];
  lines.push(`AGENT_TOGGLE_MANIFEST_DIGEST=${payload.manifestDigest}`);
  if (payload.profiles.length > 0) {
    lines.push(`AGENT_TOGGLE_PROFILES=${payload.profiles.join(',')}`);
  }
  for (const [key, resolution] of Object.entries(payload.values)) {
    lines.push(`${key}=${toEnvString(resolution.value)}`);
  }
  return `${lines.join('\n')}\n`;
}

function indent(text: string, spaces: number): string {
  const indentString = ' '.repeat(spaces);
  return text
    .split('\n')
    .map((line) => (line.length > 0 ? indentString + line : line))
    .join('\n');
}

function stringifyPsd1(value: unknown, depth = 0): string {
  if (value === null || value === undefined) {
    return '$null';
  }
  if (typeof value === 'boolean') {
    return value ? '$true' : '$false';
  }
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : '0';
  }
  if (typeof value === 'string') {
    return `'${value.replace(/'/g, "''")}'`;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return '@()';
    }
    const items = value.map((item) => stringifyPsd1(item, depth + 2));
    return "@(\n" + indent(items.join(",\n"), depth + 2) + "\n" + ' '.repeat(depth) + ')';
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>);
    if (entries.length === 0) {
      return '@{}';
    }
    const lines = entries.map(
      ([key, val]) => `'${key.replace(/'/g, "''")}' = ${stringifyPsd1(val, depth + 2)}`
    );
    return "@{\n" + indent(lines.join("\n"), depth + 2) + "\n" + ' '.repeat(depth) + '}';
  }
  return "'unknown'";
}

function formatPsd1(payload: ToggleValuesPayload): string {
  return `${stringifyPsd1(payload)}\n`;
}

function run(): void {
  const parser = new ArgumentParser({
    description: 'Agent toggle manifest utility'
  });

  parser.add_argument('--format', {
    help: 'Output format',
    choices: ['json', 'values', 'env', 'psd1'],
    default: 'json'
  });
  parser.add_argument('--profile', {
    help: 'Profile(s) to apply (can be provided multiple times)',
    action: 'append',
    dest: 'profiles'
  });
  parser.add_argument('--describe', {
    help: 'Match context: Describe block name for variant resolution'
  });
  parser.add_argument('--it', {
    help: 'Match context: It block name for variant resolution'
  });
  parser.add_argument('--tag', {
    help: 'Match context: Tag to include when resolving variants (repeatable)',
    action: 'append',
    dest: 'tags'
  });
  parser.add_argument('--pretty', {
    help: 'Pretty-print JSON output',
    action: 'store_true'
  });

  const args = parser.parse_args() as CliOptions;

  const context: ToggleResolutionContext = {
    profiles: args.profiles ?? [],
    describe: args.describe,
    it: args.it,
    tags: args.tags ?? []
  };

  let output = '';
  let contract: ReturnType<typeof createToggleContract> | undefined;

  const ensureContract = (): ReturnType<typeof createToggleContract> => {
    if (!contract) {
      contract = createToggleContract();
    }
    return contract;
  };

  switch (args.format) {
    case 'json': {
      const { manifest, manifestDigest } = ensureContract();
      const manifestOutput = {
        ...manifest,
        manifestDigest
      };
      output = formatJson(manifestOutput, args.pretty ?? true);
      break;
    }
    case 'values': {
      const payload = buildToggleValuesPayload(context, ensureContract());
      output = formatJson(payload, args.pretty ?? true);
      break;
    }
    case 'env': {
      const payload = buildToggleValuesPayload(context, ensureContract());
      output = formatEnv(payload);
      break;
    }
    case 'psd1': {
      const payload = buildToggleValuesPayload(context, ensureContract());
      output = formatPsd1(payload);
      break;
    }
    default: {
      throw new Error(`Unsupported format '${args.format}'.`);
    }
  }

  process.stdout.write(output);
}

try {
  run();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`toggle-cli: ${message}`);
  process.exit(1);
}
