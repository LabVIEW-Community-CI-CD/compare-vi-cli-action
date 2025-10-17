import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const Module = require('module');
const marker = Symbol.for('compare-vi-cli-action.punycode-userland');
const globalRegistry = globalThis;
if (!globalRegistry[marker]) {
    const originalLoad = Module._load;
    Module._load = function patchedLoad(request, parent, isMain) {
        if (request === 'punycode') {
            request = 'punycode/';
        }
        return originalLoad.call(this, request, parent, isMain);
    };
    globalRegistry[marker] = true;
}
