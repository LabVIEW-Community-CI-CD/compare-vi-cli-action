import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

export function resolveWindowsNpmCliPath(nodeExecPath = process.execPath, pathExists = existsSync) {
  const nodeDir = dirname(nodeExecPath);
  const candidates = [
    join(nodeDir, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    join(nodeDir, '..', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
  ];

  return candidates.find((candidate) => pathExists(candidate));
}

export function createNpmLaunchSpec(
  npmArgs,
  env = process.env,
  platform = process.platform,
  nodeExecPath = process.execPath,
  pathExists = existsSync,
) {
  if (platform === 'win32') {
    const npmCliPath = resolveWindowsNpmCliPath(nodeExecPath, pathExists);
    if (!npmCliPath) {
      throw new Error(`Unable to resolve npm-cli.js relative to ${nodeExecPath}.`);
    }

    return {
      command: nodeExecPath,
      args: [npmCliPath, ...npmArgs],
    };
  }

  return {
    command: 'npm',
    args: npmArgs,
  };
}
