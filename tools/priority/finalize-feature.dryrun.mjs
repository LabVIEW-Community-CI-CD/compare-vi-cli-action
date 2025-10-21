#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
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
    console.error("Usage: npm run feature:finalize:dry -- my-feature");
    process.exit(1);
  }

  const branch = `feature/${name}`;
  const root = run("git", ["rev-parse", "--show-toplevel"]);

  const branches = run("git", ["branch"]).split("\n").map((line) => line.replace("*", "").trim()).filter(Boolean);
  if (!branches.includes(branch)) {
    throw new Error(`Branch ${branch} not found. Create it before running the dry-run finalizer.`);
  }

  const featureCommit = run("git", ["rev-parse", branch]);
  const developBase = run("git", ["rev-parse", "upstream/develop"]);

  console.log(`[dry-run] would rebase ${branch} onto upstream/develop (${developBase})`);
  console.log(`[dry-run] git push origin ${branch}`);
  console.log("[dry-run] merge via PR (squash)");

  const dir = path.join(root, "tests", "results", "_agent", "feature");
  const payload = {
    schema: "feature/finalize-dryrun@v1",
    branch,
    branchCommit: featureCommit,
    developBase,
    dryRun: true,
    generatedAt: new Date().toISOString()
  };
  await writeFile(path.join(dir, `feature-${name}-finalize-dryrun.json`), `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  console.log("[dry-run] wrote feature finalize dry-run metadata");
}

main().catch((error) => {
  console.error(`[feature:finalize:dry] ${error.message}`);
  process.exit(1);
});
