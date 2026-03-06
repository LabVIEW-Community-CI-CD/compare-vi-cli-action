#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

export const DEFAULT_RELEASE_ROLLBACK_POLICY_PATH = path.join(
  'tools',
  'policy',
  'release-rollback-policy.json'
);

const DEFAULT_STREAMS = {
  stable: {
    tagPattern: '^v[0-9]+\\.[0-9]+\\.[0-9]+$',
    minimumHistory: 2
  },
  rc: {
    tagPattern: '^v[0-9]+\\.[0-9]+\\.[0-9]+-rc\\.[0-9]+$',
    minimumHistory: 2
  },
  lts: {
    tagPattern: '^v[0-9]+\\.[0-9]+\\.[0-9]+-lts\\.[0-9]+$',
    minimumHistory: 2
  }
};

function parsePositiveInt(value, fallback, { minimum = 1 } = {}) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed) || parsed < minimum) {
    return fallback;
  }
  return parsed;
}

function parseRatio(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    return fallback;
  }
  return parsed;
}

function normalizeStreamPolicy(raw, defaults) {
  const source = raw && typeof raw === 'object' ? raw : {};
  const tagPattern = String(source.tag_pattern ?? source.tagPattern ?? defaults.tagPattern);
  const minimumHistory = parsePositiveInt(
    source.minimum_history ?? source.minimumHistory,
    defaults.minimumHistory,
    { minimum: 2 }
  );
  return {
    tagPattern,
    minimumHistory
  };
}

export function normalizeReleaseRollbackPolicy(raw = {}, policyPath = DEFAULT_RELEASE_ROLLBACK_POLICY_PATH) {
  const source = raw && typeof raw === 'object' ? raw : {};
  const rollback = source.rollback && typeof source.rollback === 'object' ? source.rollback : {};
  const drill = source.drill && typeof source.drill === 'object' ? source.drill : {};
  const sourceStreams = source.streams && typeof source.streams === 'object' ? source.streams : {};

  const streams = {};
  for (const key of Object.keys(DEFAULT_STREAMS)) {
    streams[key] = normalizeStreamPolicy(sourceStreams[key], DEFAULT_STREAMS[key]);
  }

  const targetBranchesRaw = Array.isArray(rollback.target_branches)
    ? rollback.target_branches
    : rollback.targetBranches;
  const targetBranches = (Array.isArray(targetBranchesRaw) ? targetBranchesRaw : ['main', 'develop'])
    .map((value) => String(value || '').trim())
    .filter(Boolean);

  return {
    schema: String(source.schema || 'release-rollback-policy/v1'),
    path: policyPath,
    rollback: {
      remote: String(rollback.remote || 'upstream'),
      targetBranches: targetBranches.length > 0 ? targetBranches : ['main', 'develop'],
      minimumHistory: parsePositiveInt(rollback.minimum_history ?? rollback.minimumHistory, 2, { minimum: 2 })
    },
    streams,
    drill: {
      workflow: String(drill.workflow || 'release-rollback-drill.yml'),
      branch: String(drill.branch || 'develop'),
      lookbackRuns: parsePositiveInt(drill.lookback_runs ?? drill.lookbackRuns, 10, { minimum: 1 }),
      minimumSuccessRate: parseRatio(drill.minimum_success_rate ?? drill.minimumSuccessRate, 0.8),
      maxHoursSinceSuccess: parsePositiveInt(
        drill.max_hours_since_success ?? drill.maxHoursSinceSuccess,
        192,
        { minimum: 1 }
      )
    }
  };
}

export function loadReleaseRollbackPolicy(policyPath = DEFAULT_RELEASE_ROLLBACK_POLICY_PATH) {
  const resolvedPath = path.resolve(policyPath);
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`Rollback policy not found: ${resolvedPath}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(resolvedPath, 'utf8'));
  } catch (error) {
    throw new Error(`Failed to parse rollback policy at ${resolvedPath}: ${error.message}`);
  }

  return normalizeReleaseRollbackPolicy(parsed, policyPath);
}

export function getReleaseRollbackStreamPolicy(policy, stream) {
  const streamKey = String(stream || '').trim();
  if (!streamKey) {
    throw new Error('Rollback stream is required.');
  }
  const entry = policy?.streams?.[streamKey];
  if (!entry) {
    throw new Error(`Unsupported rollback stream: ${streamKey}`);
  }
  return entry;
}

