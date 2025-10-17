import Module from 'node:module';

const marker = Symbol.for('compare-vi-cli-action.punycode-userland');
const registry = /** @type {Record<symbol, boolean>} */ (globalThis);

if (!registry[marker]) {
  const originalLoad = Module._load;

  Module._load = function patchedLoad(request, parent, isMain) {
    if (request === 'punycode') {
      request = 'punycode/';
    }

    return originalLoad.call(this, request, parent, isMain);
  };

  registry[marker] = true;
}
