import test from 'node:test';
import assert from 'node:assert/strict';

import { resolveProxyUrl, shouldBypassProxy } from '../sync-standing-priority.mjs';

const EMPTY = process.platform === 'win32' ? undefined : '';

async function withEnv(overrides, fn) {
  const keys = Object.keys(overrides);
  const previous = new Map();

  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(process.env, key)) {
      previous.set(key, process.env[key]);
    } else {
      previous.set(key, undefined);
    }
    const value = overrides[key];
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }

  try {
    await fn();
  } finally {
    for (const [key, value] of previous.entries()) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  }
}

test('resolveProxyUrl selects HTTPS proxy when available', async () => {
  await withEnv(
    {
      https_proxy: EMPTY,
      HTTPS_PROXY: 'http://proxy.example:8443',
      http_proxy: EMPTY,
      HTTP_PROXY: '',
      all_proxy: EMPTY,
      ALL_PROXY: '',
      no_proxy: EMPTY,
      NO_PROXY: ''
    },
    () => {
      assert.equal(resolveProxyUrl('https://api.github.com'), 'http://proxy.example:8443');
      assert.equal(resolveProxyUrl('http://example.com'), null);
    }
  );
});

test('resolveProxyUrl falls back to HTTP proxy for HTTPS when needed', async () => {
  await withEnv(
    {
      https_proxy: EMPTY,
      HTTPS_PROXY: '',
      http_proxy: EMPTY,
      HTTP_PROXY: 'http://proxy.example:8080',
      all_proxy: EMPTY,
      ALL_PROXY: '',
      no_proxy: EMPTY,
      NO_PROXY: ''
    },
    () => {
      assert.equal(resolveProxyUrl('https://api.github.com'), 'http://proxy.example:8080');
      assert.equal(resolveProxyUrl('http://example.com'), 'http://proxy.example:8080');
    }
  );
});

test('resolveProxyUrl respects NO_PROXY patterns and wildcards', async () => {
  await withEnv(
    {
      https_proxy: EMPTY,
      HTTPS_PROXY: 'http://proxy.example:8443',
      http_proxy: EMPTY,
      HTTP_PROXY: '',
      no_proxy: EMPTY,
      NO_PROXY: '.github.com,localhost'
    },
    () => {
      assert.equal(resolveProxyUrl('https://api.github.com'), null);
      assert.equal(resolveProxyUrl('https://example.com'), 'http://proxy.example:8443');
    }
  );

  await withEnv(
    {
      no_proxy: EMPTY,
      HTTPS_PROXY: 'http://proxy.example:8443',
      NO_PROXY: '*'
    },
    () => {
      assert.equal(resolveProxyUrl('https://api.github.com'), null);
    }
  );
});

test('shouldBypassProxy handles IPv6 and port-specific exclusions', async () => {
  await withEnv(
    {
      NO_PROXY: '::1,[2001:db8::1]:443,example.com:8443'
    },
    () => {
      assert.equal(shouldBypassProxy('https://[::1]/'), true);
      assert.equal(shouldBypassProxy('https://[2001:db8::1]:443/path'), true);
      assert.equal(shouldBypassProxy('https://[2001:db8::1]:444/path'), false);
      assert.equal(shouldBypassProxy('https://service.example.com:8443/api'), true);
      assert.equal(shouldBypassProxy('https://service.example.com:443/api'), false);
    }
  );
});
