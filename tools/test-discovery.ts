/*
  tools/test-discovery.ts
  - Scans the tests directory for *.Tests.ps1
  - Marks a file as Integration if it contains -Tag 'Integration' (loose match)
  - Emits a manifest JSON used by the dispatcher to pre-exclude Integration tests
*/

import fs from 'fs';
import path from 'path';

type FileEntry = {
  path: string;       // repo-relative posix path
  fullPath: string;   // absolute
  tags: string[];     // detected tags (at least 'Integration' when present)
};

function walk(dir: string, acc: string[] = []): string[] {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walk(p, acc);
    } else if (e.isFile() && e.name.endsWith('.Tests.ps1')) {
      acc.push(p);
    }
  }
  return acc;
}

function hasIntegrationTag(text: string): boolean {
  // Match common patterns: -Tag 'Integration', -Tag "Integration", -Tag Integration
  const re = /-Tag\s*(?:'Integration'|"Integration"|Integration\b)/i;
  return re.test(text);
}

function toPosix(p: string): string {
  return p.replace(/\\/g, '/');
}

function main() {
  const args = process.argv.slice(2);
  let testsDir = 'tests';
  let outPath = path.join('tests', 'results', '_agent', 'test-manifest.json');
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if ((a === '--tests' || a === '-t') && i + 1 < args.length) { testsDir = args[++i]; continue; }
    if ((a === '--out' || a === '-o') && i + 1 < args.length) { outPath = args[++i]; continue; }
  }

  const repoRoot = process.cwd();
  const absTests = path.resolve(repoRoot, testsDir);
  const files = walk(absTests);

  const entries: FileEntry[] = files.map(f => {
    const text = fs.readFileSync(f, 'utf8');
    const tags: string[] = [];
    if (hasIntegrationTag(text)) tags.push('Integration');
    const rel = path.relative(repoRoot, f);
    return { path: toPosix(rel), fullPath: f, tags };
  });

  const manifest = {
    schema: 'pester-test-manifest/v1',
    generatedAt: new Date().toISOString(),
    root: toPosix(repoRoot),
    testsDir: toPosix(absTests),
    counts: {
      total: entries.length,
      integration: entries.filter(e => e.tags.includes('Integration')).length,
      unit: entries.filter(e => !e.tags.includes('Integration')).length
    },
    files: entries
  };

  const outAbs = path.resolve(repoRoot, outPath);
  fs.mkdirSync(path.dirname(outAbs), { recursive: true });
  fs.writeFileSync(outAbs, JSON.stringify(manifest, null, 2), 'utf8');

  // Print concise summary for callers
  const { total, integration, unit } = manifest.counts;
  // eslint-disable-next-line no-console
  console.log(`Discovered tests: total=${total} unit=${unit} integration=${integration}\nManifest: ${outAbs}`);
}

main();

