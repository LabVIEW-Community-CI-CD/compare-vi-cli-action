function normalizeStepOutput(output) {
  if (typeof output !== 'string' || output.length === 0) {
    return output;
  }

  const normalizedLines = output
    .replace(/\r\n/g, '\n')
    .split('\n')
    .filter((line) => !/^\[(ni(?:-linux)?-container-compare)\] running container=.* elapsed=\d+(?:\.\d+)?s timeout=\d+s$/.test(line));

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
