#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveRepoRoot() {
  const probes = [
    process.cwd(),
    path.resolve(__dirname, '..', '..', '..'),
    path.resolve(__dirname, '..', '..')
  ];
  for (const candidate of probes) {
    try {
      const pkgPath = path.join(candidate, 'package.json');
      if (fs.existsSync(pkgPath)) {
        return candidate;
      }
    } catch {
      // ignore
    }
  }
  return process.cwd();
}

const repoRoot = resolveRepoRoot();

function readPackageVersion() {
  const pkgPath = path.join(repoRoot, 'package.json');
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  if (!pkg.version) {
    throw new Error('version field not found in package.json');
  }
  return String(pkg.version);
}

const args = process.argv.slice(2);
let versionArg = null;
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === '--version' && args[i + 1]) {
    versionArg = args[i + 1];
    i += 1;
  } else if (!arg.startsWith('--') && !versionArg) {
    versionArg = arg;
  }
}

let version = null;
try {
  version = versionArg ?? readPackageVersion();
} catch (err) {
  console.error(JSON.stringify({
    schema: 'priority/semver-check@v1',
    version: null,
    valid: false,
    issues: [err.message],
    checkedAt: new Date().toISOString()
  }, null, 2));
  process.exit(1);
}

const semverRegex = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const valid = semverRegex.test(version);
const issues = [];

if (!valid) {
  issues.push(`Version "${version}" does not comply with SemVer 2.0.0`);
}

const output = {
  schema: 'priority/semver-check@v1',
  version,
  valid,
  issues,
  checkedAt: new Date().toISOString()
};

console.log(JSON.stringify(output, null, 2));
process.exit(valid ? 0 : 1);
