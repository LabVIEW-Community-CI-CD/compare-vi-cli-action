import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
type LoadFunction = (request: string, parent: NodeModule | null | undefined, isMain: boolean) => unknown;

const Module = require('module') as typeof import('module') & { _load: LoadFunction };
const marker = Symbol.for('compare-vi-cli-action.punycode-userland');

const globalRegistry = globalThis as Record<symbol, unknown>;

if (!globalRegistry[marker]) {
  const originalLoad = Module._load;

  Module._load = function patchedLoad(request: string, parent: NodeModule | null | undefined, isMain: boolean) {
    if (request === 'punycode') {
      request = 'punycode/';
    }

    return originalLoad.call(this, request, parent, isMain);
  };

  globalRegistry[marker] = true;
}

export {};
