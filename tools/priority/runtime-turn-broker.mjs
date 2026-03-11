#!/usr/bin/env node

import path from 'node:path';
import process from 'node:process';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { DELIVERY_AGENT_POLICY_RELATIVE_PATH, runDeliveryTurnBroker } from './delivery-agent.mjs';

function printUsage() {
  console.log('Usage: node tools/priority/runtime-turn-broker.mjs --task-packet <path> [options]');
  console.log('');
  console.log('Options:');
  console.log('  --task-packet <path>   Task packet JSON input (required).');
  console.log(`  --policy <path>        Delivery-agent policy path (default: ${DELIVERY_AGENT_POLICY_RELATIVE_PATH}).`);
  console.log('  --receipt-out <path>   Optional output file for the execution receipt.');
  console.log('  --repo-root <path>     Repository root override (default: current working directory).');
  console.log('  -h, --help             Show this help text and exit.');
}

function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    taskPacketPath: '',
    policyPath: DELIVERY_AGENT_POLICY_RELATIVE_PATH,
    receiptOutPath: '',
    repoRoot: process.cwd(),
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--task-packet' || token === '--policy' || token === '--receipt-out' || token === '--repo-root') {
      const value = args[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      if (token === '--task-packet') options.taskPacketPath = value;
      if (token === '--policy') options.policyPath = value;
      if (token === '--receipt-out') options.receiptOutPath = value;
      if (token === '--repo-root') options.repoRoot = value;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }
  if (!options.taskPacketPath) {
    printUsage();
    throw new Error('Missing required option --task-packet <path>.');
  }

  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const taskPacketPath = path.resolve(repoRoot, options.taskPacketPath);
  const taskPacket = JSON.parse(await readFile(taskPacketPath, 'utf8'));
  const receipt = await runDeliveryTurnBroker({
    taskPacket,
    taskPacketPath,
    repoRoot,
    policyPath: options.policyPath
  });

  if (options.receiptOutPath) {
    const receiptOutPath = path.resolve(repoRoot, options.receiptOutPath);
    await writeFile(receiptOutPath, `${JSON.stringify(receipt, null, 2)}\n`, 'utf8');
  }
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  return 0;
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  try {
    const exitCode = await main(process.argv);
    process.exit(exitCode);
  } catch (error) {
    process.stderr.write(`${error?.message || String(error)}\n`);
    process.exit(1);
  }
}

export { parseArgs, main };
