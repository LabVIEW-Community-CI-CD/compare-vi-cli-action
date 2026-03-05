#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export function readSessionIndexHygiene(repoRoot, relativePath = path.join('tests', 'results', 'session-index.json')) {
  const sessionPath = path.join(repoRoot, relativePath);
  if (!existsSync(sessionPath)) {
    throw new Error(`Session-index hygiene evidence is missing: ${path.relative(repoRoot, sessionPath)}`);
  }

  let payload = null;
  try {
    payload = JSON.parse(readFileSync(sessionPath, 'utf8'));
  } catch (error) {
    throw new Error(`Session-index hygiene evidence is invalid JSON (${sessionPath}): ${error.message}`);
  }

  const status = String(payload?.status ?? '').toLowerCase();
  const failed = Number(payload?.summary?.failed ?? 0);
  const errors = Number(payload?.summary?.errors ?? 0);
  const branchProtectionStatus = String(payload?.branchProtection?.result?.status ?? '').toLowerCase();

  if (status !== 'ok') {
    throw new Error(`Session-index status must be "ok" before finalize (actual: ${payload?.status ?? 'missing'}).`);
  }
  if (failed > 0 || errors > 0) {
    throw new Error(`Session-index summary must be clean before finalize (failed=${failed}, errors=${errors}).`);
  }
  if (branchProtectionStatus === 'fail') {
    throw new Error('Session-index branch protection hygiene reported fail.');
  }

  return {
    path: path.relative(repoRoot, sessionPath),
    status: payload.status,
    summary: {
      failed,
      errors,
      skipped: Number(payload?.summary?.skipped ?? 0),
      total: Number(payload?.summary?.total ?? 0)
    },
    branchProtectionStatus: payload?.branchProtection?.result?.status ?? null
  };
}

export function parseRogueScanOutput(raw) {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) {
    throw new Error('Rogue scan did not emit JSON output.');
  }
  try {
    return JSON.parse(trimmed);
  } catch (error) {
    throw new Error(`Rogue scan output is not valid JSON: ${error.message}`);
  }
}

export function ensureRogueScanClean(report) {
  const rogueLvcompare = Array.isArray(report?.rogue?.lvcompare) ? report.rogue.lvcompare : [];
  const rogueLabview = Array.isArray(report?.rogue?.labview) ? report.rogue.labview : [];

  if (rogueLvcompare.length > 0 || rogueLabview.length > 0) {
    throw new Error(
      `Rogue process detection must be clean before finalize (LVCompare=${rogueLvcompare.join(',') || 'none'}; LabVIEW=${rogueLabview.join(',') || 'none'}).`
    );
  }

  return {
    generatedAt: report?.generatedAt ?? null,
    lookbackSeconds: Number(report?.lookbackSeconds ?? 0),
    rogue: {
      lvcompare: rogueLvcompare,
      labview: rogueLabview
    },
    noticed: {
      lvcompare: Array.isArray(report?.noticed?.lvcompare) ? report.noticed.lvcompare : [],
      labview: Array.isArray(report?.noticed?.labview) ? report.noticed.labview : []
    }
  };
}
