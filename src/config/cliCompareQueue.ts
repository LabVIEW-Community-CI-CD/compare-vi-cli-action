import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import { z } from 'zod';
import {
  cliCompareQueueCaseSchema,
  cliCompareQueueSchema,
  cliCompareQueueSummarySchema,
  CliCompareQueue,
  CliCompareQueueCase,
  CliCompareQueueSummary,
} from '../schema/cli-compare.js';

function readJsonFile(path: string): unknown {
  const fullPath = resolvePath(path);
  const raw = readFileSync(fullPath, 'utf8');
  try {
    return JSON.parse(raw);
  } catch (error) {
    const message = (error as Error).message;
    throw new Error(`Failed to parse JSON from ${fullPath}: ${message}`);
  }
}

export function loadCliCompareQueue(path: string): CliCompareQueue {
  const json = readJsonFile(path);
  return cliCompareQueueSchema.parse(json);
}

export function loadCliCompareQueueSummary(path: string): CliCompareQueueSummary {
  const json = readJsonFile(path);
  return cliCompareQueueSummarySchema.parse(json);
}

export function validateCliCompareCase(candidate: unknown): CliCompareQueueCase {
  return cliCompareQueueCaseSchema.parse(candidate);
}

export function filterCasesByTag(queue: CliCompareQueue, tag: string): CliCompareQueueCase[] {
  const normalized = tag.trim().toLowerCase();
  return queue.cases.filter((c) => c.tags?.some((t) => t.toLowerCase() === normalized));
}

export function getCaseById(queue: CliCompareQueue, id: string): CliCompareQueueCase | undefined {
  const normalized = id.trim().toLowerCase();
  return queue.cases.find((c) => c.id.toLowerCase() === normalized);
}

export function enabledCases(queue: CliCompareQueue): CliCompareQueueCase[] {
  return queue.cases.filter((c) => !c.disabled);
}

export type CliCompareQueueType = CliCompareQueue;
export type CliCompareQueueCaseType = CliCompareQueueCase;
export type CliCompareQueueSummaryType = CliCompareQueueSummary;
