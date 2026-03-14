function normalizeVolatileJsonFields(value) {
  if (Array.isArray(value)) {
    return value.map(normalizeVolatileJsonFields);
  }
  if (!value || typeof value !== 'object') {
    return value;
  }

  const normalized = {};
  for (const [key, entryValue] of Object.entries(value)) {
    if (key === 'timestamp' || key === 'generatedAt' || key === 'startedAt' || key === 'finishedAt') {
      normalized[key] = 'normalized';
      continue;
    }
    if (key === 'durationMs' && Number.isFinite(entryValue)) {
      normalized[key] = 0;
      continue;
    }
    normalized[key] = normalizeVolatileJsonFields(entryValue);
  }
  return normalized;
}

function normalizeStepOutput(output) {
  if (typeof output !== 'string' || output.length === 0) {
    return output;
  }

  const normalized = output.replace(/\r\n/g, '\n').trim();
  if (normalized.startsWith('{') || normalized.startsWith('[')) {
    try {
      return JSON.stringify(normalizeVolatileJsonFields(JSON.parse(normalized)), null, 2);
    } catch {
      // Fall through to line-based normalization.
    }
  }

  const normalizedLines = output
    .replace(/\r\n/g, '\n')
    .split('\n')
    .filter((line) => !/^\[(ni(?:-linux)?-container-compare)\] running container=.* elapsed=\d+(?:\.\d+)?s timeout=\d+s$/.test(line))
    .filter((line) => !/^Downloading actionlint \S+ \(.+\)\.\.\.$/.test(line));

  return normalizedLines.join('\n');
}

export function normalizeSummary(summary) {
  const clone = JSON.parse(JSON.stringify(summary));
  clone.timestamp = 'normalized';
  if (Array.isArray(clone.steps)) {
    clone.steps = clone.steps
      .map((step) => ({
        ...step,
        durationMs: 0,
        stdout: normalizeStepOutput(step.stdout),
        stderr: normalizeStepOutput(step.stderr),
      }))
      .sort((a, b) => {
        if (a.name < b.name) { return -1; }
        if (a.name > b.name) { return 1; }
        return 0;
      });
  }
  return clone;
}
