import Module from 'node:module';
import { createRequire } from 'node:module';

type ModuleLoader = (request: string, parent: NodeModule | null, isMain: boolean) => unknown;

type ModuleWithLoad = typeof Module & {
  _load?: ModuleLoader;
};

declare const globalThis: typeof global & {
  [key: symbol]: unknown;
};

const globalKey = Symbol.for('comparevi.node.punycodePatched');

if (!globalThis[globalKey]) {
  const moduleWithLoad = Module as ModuleWithLoad;
  const originalLoad = moduleWithLoad._load;
  if (typeof originalLoad === 'function') {
    const require = createRequire(import.meta.url);
    let replacement: string | null = null;
    try {
      // Prefer the package that mirrors Node's legacy API while avoiding the builtin.
      require.resolve('punycode/');
      replacement = 'punycode/';
    } catch {
      try {
        require.resolve('punycode.js');
        replacement = 'punycode.js';
      } catch {
        replacement = null;
      }
    }

    if (replacement) {
      moduleWithLoad._load = function patchedLoad(request, parent, isMain) {
        if (request === 'punycode') {
          request = replacement;
        }
        return originalLoad.call(this, request, parent, isMain);
      };
    }
  }

  globalThis[globalKey] = true;
}
