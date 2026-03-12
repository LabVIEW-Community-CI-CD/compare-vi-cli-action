#!/usr/bin/env node

export function resolveCheckoutContext(options) {
  const mode = String(options.mode ?? 'default').trim() || 'default';
  const eventName = String(options.eventName ?? '').trim();
  const fallbackRepository = String(options.repository ?? '').trim();
  const fallbackRef = String(options.sha ?? '').trim();
  const prHeadRepository = String(options.prHeadRepository ?? '').trim();
  const prHeadSha = String(options.prHeadSha ?? '').trim();
  const prBaseSha = String(options.prBaseSha ?? '').trim();
  const overrideRepository = String(options.overrideRepository ?? '').trim();
  const overrideRef = String(options.overrideRef ?? '').trim();

  let repository = fallbackRepository;
  let ref = fallbackRef;

  if (mode === 'pr-head' && eventName === 'pull_request') {
    repository = prHeadRepository || repository;
    ref = prHeadSha || ref;
  } else if (mode === 'base-safe' && (eventName === 'pull_request_target' || eventName === 'pull_request_review')) {
    repository = fallbackRepository;
    ref = prBaseSha || ref;
  } else if (mode !== 'default' && mode !== 'pr-head' && mode !== 'base-safe') {
    throw new Error(`Unsupported checkout mode: ${mode}`);
  }

  if (overrideRepository) {
    repository = overrideRepository;
  }
  if (overrideRef) {
    ref = overrideRef;
  }

  if (!repository) {
    throw new Error('Resolved checkout repository is empty.');
  }
  if (!ref) {
    throw new Error('Resolved checkout ref is empty.');
  }

  return {
    repository,
    ref,
    effectiveMode: mode
  };
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) {
      continue;
    }
    const key = token.slice(2).replace(/-([a-z])/g, (_, char) => char.toUpperCase());
    const next = argv[index + 1];
    if (next == null) {
      throw new Error(`Missing value for ${token}`);
    }
    options[key] = next;
    index += 1;
  }
  return options;
}

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, '/')}`) {
  const options = parseArgs(process.argv.slice(2));
  const result = resolveCheckoutContext(options);
  if (options.output) {
    const fs = await import('node:fs');
    fs.appendFileSync(
      options.output,
      `repository=${result.repository}\nref=${result.ref}\neffective-mode=${result.effectiveMode}\n`,
      'utf8'
    );
  } else {
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
}
