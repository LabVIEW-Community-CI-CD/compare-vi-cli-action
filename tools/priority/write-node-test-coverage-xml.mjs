#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const HELP = [
  'Usage: node tools/priority/write-node-test-coverage-xml.mjs --input <log> --output <coverage.xml> [--line-threshold <n>]',
  '',
  'Parses the console coverage summary emitted by `node --test --experimental-test-coverage`',
  'and writes a minimal Cobertura-style coverage.xml artifact.'
];

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    input: '',
    output: '',
    lineThreshold: 75
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = argv[i + 1];
    if (token === '--help' || token === '-h') {
      return { help: true };
    }
    if (token === '--input') {
      options.input = next;
      i += 1;
      continue;
    }
    if (token === '--output') {
      options.output = next;
      i += 1;
      continue;
    }
    if (token === '--line-threshold') {
      options.lineThreshold = Number(next);
      i += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  if (!options.input || !options.output) {
    throw new Error('Both --input and --output are required.');
  }

  return options;
}

function extractCoverageMetrics(text) {
  const allFilesMatch = text.match(/all files\s+\|\s+([0-9.]+)\s+\|\s+([0-9.]+)\s+\|\s+([0-9.]+)/i);
  if (!allFilesMatch) {
    throw new Error('Unable to locate aggregate coverage metrics in node test output.');
  }
  return {
    lineRatePercent: Number(allFilesMatch[1]),
    branchRatePercent: Number(allFilesMatch[2]),
    functionRatePercent: Number(allFilesMatch[3])
  };
}

function toRate(percent) {
  return (percent / 100).toFixed(4);
}

function buildCoberturaXml({ lineRatePercent, branchRatePercent, functionRatePercent, lineThreshold }) {
  const lineRate = toRate(lineRatePercent);
  const branchRate = toRate(branchRatePercent);
  return `<?xml version="1.0" encoding="UTF-8"?>
<coverage line-rate="${lineRate}" branch-rate="${branchRate}" lines-covered="${Math.round(lineRatePercent)}" lines-valid="100" branches-covered="${Math.round(branchRatePercent)}" branches-valid="100" complexity="0" version="1.0" timestamp="${Date.now()}">
  <sources>
    <source>.</source>
  </sources>
  <packages>
    <package name="pester-service-model" line-rate="${lineRate}" branch-rate="${branchRate}" complexity="0">
      <classes>
        <class name="workflow-contracts" filename="tools/priority/__tests__/pester-service-model-workflow-contract.test.mjs" line-rate="${lineRate}" branch-rate="${branchRate}" complexity="0">
          <methods/>
          <lines/>
        </class>
      </classes>
    </package>
  </packages>
  <thresholds line="${lineThreshold}" functions="${functionRatePercent.toFixed(2)}"/>
</coverage>
`;
}

async function materializeCoverageXml({ inputPath, outputPath, lineThreshold }) {
  const inputText = await fs.readFile(inputPath, 'utf8');
  const metrics = extractCoverageMetrics(inputText);
  const xml = buildCoberturaXml({ ...metrics, lineThreshold });
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, xml, 'utf8');
  if (metrics.lineRatePercent < lineThreshold) {
    throw new Error(`Line coverage ${metrics.lineRatePercent}% is below threshold ${lineThreshold}%`);
  }
  return { metrics, outputPath };
}

export { parseArgs, extractCoverageMetrics, buildCoberturaXml, materializeCoverageXml };

async function main() {
  const options = parseArgs();
  if (options.help) {
    console.log(HELP.join('\n'));
    return;
  }
  await materializeCoverageXml({
    inputPath: options.input,
    outputPath: options.output,
    lineThreshold: options.lineThreshold
  });
  console.log(`coverage_xml=${options.output}`);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exit(1);
  });
}
