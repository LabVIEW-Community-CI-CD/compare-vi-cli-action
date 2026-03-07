import '../shims/punycode-userland.js';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ArgumentParser } from 'argparse';

interface Args {
  summary: string;
  markdown?: string;
  step_summary?: string;
  require_mode?: string[];
}

interface CountMap {
  [key: string]: number;
}

interface ModeSummary {
  slug: string;
  diffs: number;
  signalDiffs: number;
  noiseCollapsed: number;
  categoryCounts?: CountMap | null;
  collapsedNoise?: {
    categoryCounts?: CountMap | null;
  };
}

interface CertificationSummary {
  schema: string;
  warningText: string;
  execution?: {
    mode?: string;
    bundleArchivePath?: string | null;
  };
  aggregate?: {
    categoryCounts?: CountMap | null;
  };
  modes?: ModeSummary[];
  certification?: {
    passed?: boolean;
    noUnspecified?: boolean;
    warningHasUnspecified?: boolean;
    warningHasExplicitCategories?: boolean;
    actualModes?: string[];
  };
}

function readJson<T>(path: string): T {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T;
  } catch (err) {
    throw new Error(`Failed to parse JSON from ${path}: ${(err as Error).message}`);
  }
}

function normalizeModeList(input?: string[]): string[] {
  if (!input || input.length === 0) {
    return ['default', 'attributes', 'front-panel', 'block-diagram'];
  }

  const values = input
    .flatMap((entry) => entry.split(','))
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);

  return [...new Set(values)];
}

function normalizeCountMap(map: CountMap | null | undefined): Array<[string, number]> {
  if (!map || typeof map !== 'object') {
    return [];
  }

  return Object.entries(map)
    .filter(([, value]) => Number.isFinite(value))
    .map(([key, value]) => [key, Number(value)] as [string, number])
    .sort((a, b) => a[0].localeCompare(b[0]));
}

function formatCountMap(map: CountMap | null | undefined): string {
  const entries = normalizeCountMap(map);
  if (entries.length === 0) {
    return 'none';
  }

  return entries.map(([key, value]) => `${key} (${value})`).join('<br>');
}

function hasUnspecified(entries: Array<[string, number]>): boolean {
  return entries.some(([key]) => key.toLowerCase() === 'unspecified');
}

function escapeMarkdown(text: string): string {
  return text.replace(/\|/g, '\\|');
}

function verifySummary(summary: CertificationSummary, requiredModes: string[]): void {
  if (summary.schema !== 'comparevi-history-bundle-certification@v1') {
    throw new Error(`Unexpected certification schema '${summary.schema}'.`);
  }

  if (!summary.certification?.passed) {
    throw new Error('Certification summary reports passed=false.');
  }
  if (!summary.certification.noUnspecified) {
    throw new Error('Certification summary reports noUnspecified=false.');
  }
  if (summary.certification.warningHasUnspecified) {
    throw new Error('Certification warning still contains unspecified categories.');
  }
  if (!summary.certification.warningHasExplicitCategories) {
    throw new Error('Certification warning did not report explicit category labels.');
  }

  const actualModes = [...new Set(summary.certification.actualModes ?? [])].sort();
  const expectedModes = [...requiredModes].sort();
  if (actualModes.length !== expectedModes.length || actualModes.some((mode, index) => mode !== expectedModes[index])) {
    throw new Error(`Certification modes mismatch. expected=${expectedModes.join(', ')} actual=${actualModes.join(', ')}`);
  }

  const modeIndex = new Map<string, ModeSummary>();
  for (const mode of summary.modes ?? []) {
    modeIndex.set(mode.slug, mode);
  }

  for (const modeSlug of requiredModes) {
    const mode = modeIndex.get(modeSlug);
    if (!mode) {
      throw new Error(`Missing certification mode '${modeSlug}'.`);
    }

    const directCategories = normalizeCountMap(mode.categoryCounts);
    const collapsedCategories = normalizeCountMap(mode.collapsedNoise?.categoryCounts);
    if (directCategories.length === 0 && collapsedCategories.length === 0) {
      throw new Error(`Mode '${modeSlug}' did not surface any explicit categories.`);
    }
    if (hasUnspecified(directCategories) || hasUnspecified(collapsedCategories)) {
      throw new Error(`Mode '${modeSlug}' still contains unspecified categories.`);
    }
  }

  if (!summary.warningText || !summary.warningText.includes('LVCompare detected differences')) {
    throw new Error('Certification warning text is missing.');
  }
}

function buildMarkdown(summary: CertificationSummary, requiredModes: string[]): string {
  const modeIndex = new Map<string, ModeSummary>();
  for (const mode of summary.modes ?? []) {
    modeIndex.set(mode.slug, mode);
  }

  const lines = [
    '## CompareVI History Bundle Certification',
    '',
    `- Execution: \`${summary.execution?.mode ?? 'unknown'}\``,
    `- Certified modes: \`${requiredModes.join(', ')}\``,
    `- Warning: \`${escapeMarkdown(summary.warningText)}\``,
    `- Aggregate categories: ${formatCountMap(summary.aggregate?.categoryCounts)}`,
  ];

  if (summary.execution?.bundleArchivePath) {
    lines.push(`- Bundle archive: \`${summary.execution.bundleArchivePath}\``);
  }

  lines.push('');
  lines.push('| Mode | Diffs | Signal | Collapsed Noise | Categories | Collapsed Categories |');
  lines.push('| --- | ---: | ---: | ---: | --- | --- |');

  for (const modeSlug of requiredModes) {
    const mode = modeIndex.get(modeSlug);
    if (!mode) {
      continue;
    }

    lines.push(
      `| ${modeSlug} | ${mode.diffs} | ${mode.signalDiffs} | ${mode.noiseCollapsed} | ${formatCountMap(mode.categoryCounts)} | ${formatCountMap(mode.collapsedNoise?.categoryCounts)} |`,
    );
  }

  lines.push('');
  return lines.join('\n');
}

function main(): void {
  const parser = new ArgumentParser({
    description: 'Verify and render CompareVI history bundle certification evidence.',
  });

  parser.add_argument('--summary', { required: true, help: 'Path to comparevi-history-bundle-certification.json.' });
  parser.add_argument('--markdown', { required: false, help: 'Optional output path for rendered Markdown.' });
  parser.add_argument('--step-summary', { required: false, help: 'Optional GitHub Step Summary path to append to.' });
  parser.add_argument('--require-mode', {
    action: 'append',
    required: false,
    help: 'Expected certification mode slug. Repeat or provide comma-separated values.',
  });

  const args = parser.parse_args() as Args;
  const summaryPath = resolve(process.cwd(), args.summary);
  if (!existsSync(summaryPath)) {
    throw new Error(`Certification summary not found: ${summaryPath}`);
  }

  const summary = readJson<CertificationSummary>(summaryPath);
  const requiredModes = normalizeModeList(args.require_mode);
  verifySummary(summary, requiredModes);

  const markdown = buildMarkdown(summary, requiredModes);

  if (args.markdown) {
    const markdownPath = resolve(process.cwd(), args.markdown);
    writeFileSync(markdownPath, `${markdown}\n`, 'utf8');
  }

  if (args.step_summary) {
    const stepSummaryPath = resolve(process.cwd(), args.step_summary);
    writeFileSync(stepSummaryPath, `\n${markdown}\n`, { encoding: 'utf8', flag: 'a' });
  }

  // eslint-disable-next-line no-console
  console.log(markdown);
}

main();
