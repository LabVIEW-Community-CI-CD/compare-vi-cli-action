#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { stdin as stdinStream } from 'node:process';
import { sanitizeGhText, buildIssueLinkSnippet, assertPresent } from './lib/github-text.mjs';

function printUsage() {
  console.log(`Usage:
  node tools/priority/github-helper.mjs sanitize [--input <file>] [--output <file>]
  node tools/priority/github-helper.mjs snippet --issue <number> [--prefix <text>] [--suffix <text>] [--output <file>]

Commands:
  sanitize   Normalise issue/PR body text (doubles backslashes, normalises CRLF).
             Reads from --input or STDIN and writes to --output or STDOUT.
  snippet    Generate an auto-link snippet (defaults to "Fixes #<issue>").
`);
}

async function readFromStdin() {
  return new Promise((resolve, reject) => {
    let result = '';
    stdinStream.setEncoding('utf8');
    stdinStream.on('data', (chunk) => {
      result += chunk;
    });
    stdinStream.on('end', () => resolve(result));
    stdinStream.on('error', reject);
  });
}

function writeOutput(content, target) {
  if (target) {
    fs.writeFileSync(target, content, 'utf8');
  } else {
    process.stdout.write(content);
    if (!content.endsWith('\n')) {
      process.stdout.write('\n');
    }
  }
}

async function handleSanitize(args) {
  let inputFile;
  let outputFile;
  const rest = [];

  for (let i = 0; i < args.length; i++) {
    const token = args[i];
    if (token === '--input') {
      inputFile = args[++i];
    } else if (token === '--output') {
      outputFile = args[++i];
    } else if (token === '--help') {
      printUsage();
      process.exit(0);
    } else {
      rest.push(token);
    }
  }

  if (rest.length > 0) {
    throw new Error(`Unknown sanitize option(s): ${rest.join(', ')}`);
  }

  let content;
  if (inputFile) {
    content = fs.readFileSync(inputFile, 'utf8');
  } else if (!stdinStream.isTTY) {
    content = await readFromStdin();
  } else {
    throw new Error('Provide --input <file> or pipe content via STDIN.');
  }

  const sanitised = sanitizeGhText(content);
  writeOutput(sanitised, outputFile);
}

function handleSnippet(args) {
  let issueNumber;
  let prefix = 'Fixes';
  let suffix = '';
  let outputFile;
  const rest = [];

  for (let i = 0; i < args.length; i++) {
    const token = args[i];
    if (token === '--issue') {
      issueNumber = args[++i];
    } else if (token === '--prefix') {
      prefix = args[++i] ?? '';
    } else if (token === '--suffix') {
      suffix = args[++i] ?? '';
    } else if (token === '--output') {
      outputFile = args[++i];
    } else if (token === '--help') {
      printUsage();
      process.exit(0);
    } else {
      rest.push(token);
    }
  }

  if (rest.length > 0) {
    throw new Error(`Unknown snippet option(s): ${rest.join(', ')}`);
  }

  assertPresent(issueNumber, 'Snippet generation requires --issue <number>.');
  const snippet = buildIssueLinkSnippet(issueNumber, { prefix, suffix });
  writeOutput(snippet, outputFile);
}

export async function main() {
  const [, , command, ...commandArgs] = process.argv;
  try {
    switch (command) {
      case 'sanitize':
        await handleSanitize(commandArgs);
        break;
      case 'snippet':
        handleSnippet(commandArgs);
        break;
      case '--help':
      case undefined:
        printUsage();
        process.exit(command ? 0 : 1);
        break;
      default:
        throw new Error(`Unknown command: ${command}`);
    }
  } catch (error) {
    console.error(`[github-helper] ${error.message}`);
    process.exit(1);
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  await main();
}
