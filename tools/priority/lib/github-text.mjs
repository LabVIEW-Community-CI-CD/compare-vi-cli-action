#!/usr/bin/env node

import assert from 'node:assert/strict';

/**
 * Normalise content destined for the GitHub CLI so literal backslashes survive.
 * - Converts CRLF/CR line endings to LF unless disableNormaliseEol is true.
 * - Doubles every backslash so gh/REST payloads do not interpret escape sequences.
 *
 * @param {string} input
 * @param {{ normaliseEol?: boolean }} [options]
 * @returns {string}
 */
export function sanitizeGhText(input, { normaliseEol = true } = {}) {
  if (input === null || input === undefined) {
    return '';
  }

  let value = String(input);
  if (normaliseEol) {
    value = value.replace(/\r\n?/g, '\n');
  }
  return value.replace(/\\/g, '\\\\');
}

/**
 * Build a PR auto-link snippet (e.g. "Fixes #123").
 *
 * @param {string|number} issueNumber
 * @param {{ prefix?: string, suffix?: string }} [options]
 * @returns {string}
 */
export function buildIssueLinkSnippet(issueNumber, { prefix = 'Fixes', suffix = '' } = {}) {
  const trimmed = String(issueNumber ?? '').trim();
  if (!trimmed) {
    throw new Error('Issue number is required to build the link snippet.');
  }
  if (!/^\d+$/.test(trimmed)) {
    throw new Error(`Issue number must be digits only (received: ${trimmed}).`);
  }

  const lead = prefix.trim();
  const tail = suffix ? ` ${suffix.trim()}` : '';
  return `${lead} #${trimmed}${tail}`;
}

/**
 * Convenience wrapper that sanitizes both title/body payloads.
 *
 * @param {{ title?: string, body?: string }} payload
 * @param {{ normaliseEol?: boolean }} [options]
 * @returns {{ title: string, body: string }}
 */
export function sanitizeIssuePayload(payload, { normaliseEol = true } = {}) {
  const { title = '', body = '' } = payload ?? {};
  return {
    title: sanitizeGhText(title, { normaliseEol }),
    body: sanitizeGhText(body, { normaliseEol })
  };
}

/**
 * Helper to assert that CLI sub-command arguments are present.
 *
 * @param {unknown} value
 * @param {string} message
 */
export function assertPresent(value, message) {
  assert.ok(value !== null && value !== undefined && String(value).trim() !== '', message);
}
