import { ArgumentParser } from 'argparse';
import type { ToggleManifest, ToggleResolution, ToggleResolutionContext, ToggleValue } from './toggles.js';
import { createToggleManifest, resolveToggleValues } from './toggles.js';

type OutputFormat = 'json' | 'values' | 'env' | 'psd1';

interface CliOptions extends ToggleResolutionContext {
  format: OutputFormat;
  pretty?: boolean;
  includeMetadata?: boolean;
}

interface ValuesPayload {
  schema: 'agent-toggle-values/v1';
  schemaVersion: string;
  generatedAtUtc: string;
  profiles: string[];
  context: {
    describe?: string;
    it?: string;
    tags?: string[];
  };
  values: Record<string, ToggleResolution>;
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

function buildValuesPayload(manifest: ToggleManifest, context: ToggleResolutionContext): ValuesPayload {
  const resolved = resolveToggleValues(manifest, context);
  const values: Record<string, ToggleResolution> = {};
  for (const [key, resolution] of resolved.entries()) {
    values[key] = resolution;
  }
  return {
    schema: 'agent-toggle-values/v1',
    schemaVersion: manifest.schemaVersion,
    generatedAtUtc: manifest.generatedAtUtc,
    profiles: context.profiles ?? [],
    context: {
      describe: context.describe,
      it: context.it,
      tags: context.tags && context.tags.length > 0 ? context.tags : undefined
    },
    values
  };
}

function formatEnv(manifest: ToggleManifest, context: ToggleResolutionContext): string {
  const resolved = resolveToggleValues(manifest, context);
  const lines: string[] = [];
  for (const [key, resolution] of resolved.entries()) {
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

function formatPsd1(manifest: ToggleManifest, context: ToggleResolutionContext): string {
  const payload = buildValuesPayload(manifest, context);
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

  const manifest = createToggleManifest();

  const context: ToggleResolutionContext = {
    profiles: args.profiles ?? [],
    describe: args.describe,
    it: args.it,
    tags: args.tags
  };

  let output = '';

  switch (args.format) {
    case 'json': {
      output = formatJson(manifest, args.pretty);
      break;
    }
    case 'values': {
      const payload = buildValuesPayload(manifest, context);
      output = formatJson(payload, args.pretty ?? true);
      break;
    }
    case 'env': {
      output = formatEnv(manifest, context);
      break;
    }
    case 'psd1': {
      output = formatPsd1(manifest, context);
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
