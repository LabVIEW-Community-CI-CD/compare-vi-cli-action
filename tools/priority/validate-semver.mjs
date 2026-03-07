#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  deriveReleaseSurfaceVersions,
  readReleaseSurfaceVersionsSync,
  evaluateReleaseSurfaceVersionExpectations
} from './lib/release-surface-versions.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');

const semverRegex = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

function readPackageVersion() {
  const pkgPath = path.join(repoRoot, 'package.json');
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  if (!pkg.version) {
    throw new Error('version field not found in package.json');
  }
  return String(pkg.version);
}

export function parseArgs(args = process.argv.slice(2), env = process.env) {
  let versionArg = null;
  let branchArg = null;

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--version' && args[i + 1]) {
      versionArg = args[i + 1];
      i += 1;
      continue;
    }
    if (arg === '--branch' && args[i + 1]) {
      branchArg = args[i + 1];
      i += 1;
      continue;
    }
    if (!arg.startsWith('--') && !versionArg) {
      versionArg = arg;
    }
  }

  const branch =
    branchArg ||
    env.GITHUB_HEAD_REF ||
    env.GITHUB_REF_NAME ||
    null;

  return {
    versionArg,
    branch
  };
}

export function evaluateVersionIntegrity(version, branch = null) {
  const issues = [];
  const valid = semverRegex.test(version);
  if (!valid) {
    issues.push(`Version "${version}" does not comply with SemVer 2.0.0`);
  }

  if (branch && branch.startsWith('release/')) {
    const branchTag = branch.slice('release/'.length);
    const branchSemver = branchTag.startsWith('v') ? branchTag.slice(1) : branchTag;
    if (!semverRegex.test(branchSemver)) {
      issues.push(`Release branch tag "${branchTag}" is not a SemVer version.`);
    } else if (version !== branchSemver) {
      issues.push(`Version "${version}" does not match release branch tag "${branchTag}".`);
    }
  }

  return {
    valid: issues.length === 0,
    issues
  };
}

export function run({ args = process.argv.slice(2), env = process.env } = {}) {
  const parsed = parseArgs(args, env);
  let version = null;
  let surfaceVersions = null;

  try {
    version = parsed.versionArg ?? readPackageVersion();
    surfaceVersions = readReleaseSurfaceVersionsSync(repoRoot);
  } catch (err) {
    return {
      code: 1,
      output: {
        schema: 'priority/semver-check@v1',
        version: null,
        branch: parsed.branch,
        surfaceVersions: null,
        valid: false,
        issues: [err.message],
        checkedAt: new Date().toISOString()
      }
    };
  }

  const evaluated = evaluateVersionIntegrity(version, parsed.branch);
  const releaseSurfaceEvaluation = evaluateReleaseSurfaceVersionExpectations(version, surfaceVersions);
  const valid = evaluated.valid && releaseSurfaceEvaluation.valid;
  const expectedSurfaces = deriveReleaseSurfaceVersions(version);
  return {
    code: valid ? 0 : 1,
    output: {
      schema: 'priority/semver-check@v1',
      version,
      branch: parsed.branch,
      surfaceVersions,
      expectedSurfaces,
      valid,
      issues: [...evaluated.issues, ...releaseSurfaceEvaluation.issues],
      checkedAt: new Date().toISOString()
    }
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === __filename) {
  const result = run();
  console.log(JSON.stringify(result.output, null, 2));
  process.exit(result.code);
}
