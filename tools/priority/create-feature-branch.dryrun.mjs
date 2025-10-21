#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
    ...options
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with exit code ${result.status}`);
  }
  return result.stdout.trim();
}

async function main() {
  const name = process.argv[2];
  if (!name) {
    console.error("Usage: npm run feature:branch:dry -- my-feature");
    process.exit(1);
  }

  const branch = `feature/${name}`;
  const root = run("git", ["rev-parse", "--show-toplevel"]);
  const status = run("git", ["status", "--porcelain"]);
  if (status.length > 0) {
    throw new Error("Working tree not clean. Commit or stash changes before running the dry-run helper.");
  }

  run("git", ["checkout", "-B", "develop", "upstream/develop"]);
  run("git", ["checkout", "-b", branch]);

  const baseCommit = run("git", ["rev-parse", "HEAD"]);
  const dir = path.join(root, "tests", "results", "_agent", "feature");
  await mkdir(dir, { recursive: true });
  const payload = {
    schema: "feature/branch-dryrun@v1",
    branch,
    baseBranch: "develop",
    baseCommit,
    dryRun: true,
    createdAt: new Date().toISOString()
  };
  const file = path.join(dir, `feature-${name}-dryrun.json`);
  await writeFile(file, `${JSON.stringify(payload, null, 2)}\n`, "utf8");

  console.log(`[dry-run] created ${branch} at ${baseCommit}`);
  console.log(`[dry-run] metadata -> ${file}`);
  console.log("[dry-run] skipping push and PR creation");
}

main().catch((error) => {
  console.error(`[feature:branch:dry] ${error.message}`);
  process.exit(1);
});
