import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('Directory.Build.props defaults CompareVi.Shared to package-first with project fallback', () => {
  const props = read('Directory.Build.props');
  assert.match(props, /<CompareViSharedSource[^>]*>\s*package-first\s*<\/CompareViSharedSource>/i);
  assert.match(props, /<CompareViSharedFallbackSource[^>]*>\s*project\s*<\/CompareViSharedFallbackSource>/i);
  assert.match(props, /<CompareViSharedPackageFeed[^>]*>/i);
});

test('Directory.Build.targets resolves package-first and exposes print target seam', () => {
  const targets = read('Directory.Build.targets');
  assert.ok(targets.includes('CompareViSharedResolvedSource'));
  assert.ok(targets.includes("'$(CompareViSharedSource)' == 'package-first'"));
  assert.ok(targets.includes('<Target Name="PrintCompareViSharedSource">'));
  assert.ok(targets.includes('CompareViSharedPackageAvailable='));
});

test('CLI csproj references resolved CompareVi.Shared source seam', () => {
  const cliCsproj = read('src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj');
  assert.ok(cliCsproj.includes("'$(CompareViSharedResolvedSource)' == 'project'"));
  assert.ok(cliCsproj.includes("'$(CompareViSharedResolvedSource)' == 'package'"));
});

test('dotnet-shared workflow enforces package-first parity lane', () => {
  const workflow = read('.github/workflows/dotnet-shared.yml');
  assert.match(workflow, /shared_source:\s*package-first/i);
  assert.match(workflow, /expected_resolved:\s*package/i);
  assert.match(workflow, /Assert shared-source resolution/i);
});

test('monthly stability workflow derives CompareVi.Shared version from Directory.Build.props', () => {
  const workflow = read('.github/workflows/monthly-stability-release.yml');
  assert.match(workflow, /fs\.readFileSync\('Directory\.Build\.props', 'utf8'\)/);
  assert.match(workflow, /<CompareViSharedPackageVersion\\b\[\^>\]\*>\(\[\^<\]\+\)<\\\/CompareViSharedPackageVersion>/);
  assert.match(workflow, /configuredPackageVersion === '\$\(Version\)'/);
  assert.match(workflow, /publish_shared=true requires shared_version \(or Directory\.Build\.props CompareViSharedPackageVersion\/Version\)\./);
  assert.doesNotMatch(workflow, /fs\.readFileSync\('src\/CompareVi\.Shared\/CompareVi\.Shared\.csproj', 'utf8'\)/);
});
