#!/usr/bin/env node

function normalizeText(value) {
  if (value == null) {
    return '';
  }
  return String(value).trim();
}

export function formatGitInvocation(args = []) {
  return `git ${args.join(' ')}`.trim();
}

export function extractGitResultMessage(result = {}) {
  return normalizeText(result?.stderr) || normalizeText(result?.stdout) || '';
}

export function isUpstreamRefRaceMessage(message) {
  const normalized = normalizeText(message);
  if (!normalized) {
    return false;
  }

  return (
    /incorrect old value provided/i.test(normalized) ||
    /cannot lock ref ['"]?refs\/remotes\/upstream\/develop['"]?/i.test(normalized)
  );
}

export function buildForcedUpstreamRefRefreshArgs(baseRefName = 'develop') {
  return ['fetch', 'upstream', `+${baseRefName}:refs/remotes/upstream/${baseRefName}`];
}

export async function refreshUpstreamTrackingRef({
  runGitFn,
  baseRefName = 'develop',
  initialArgs = ['fetch', 'upstream', baseRefName]
} = {}) {
  if (typeof runGitFn !== 'function') {
    throw new Error('refreshUpstreamTrackingRef requires runGitFn.');
  }

  const initialResult = await runGitFn(initialArgs);
  const attempts = [formatGitInvocation(initialArgs)];
  if (initialResult?.status === 0) {
    return {
      result: initialResult,
      attempts,
      repairedRace: false,
      initialMessage: ''
    };
  }

  const initialMessage = extractGitResultMessage(initialResult);
  if (!isUpstreamRefRaceMessage(initialMessage)) {
    return {
      result: initialResult,
      attempts,
      repairedRace: false,
      initialMessage
    };
  }

  const forcedArgs = buildForcedUpstreamRefRefreshArgs(baseRefName);
  const forcedResult = await runGitFn(forcedArgs);
  attempts.push(formatGitInvocation(forcedArgs));
  return {
    result: forcedResult,
    attempts,
    repairedRace: true,
    initialMessage
  };
}
