/**
 * Minimal Node.js type declarations used as a fallback when `@types/node`
 * is unavailable. The signatures intentionally favour broad `unknown`
 * shapes so they can coexist with the official typings when present.
 */

declare module 'node:child_process' {
  interface SpawnSyncResult {
    status: number | null;
    stdout: string;
    stderr: string;
    error?: unknown;
  }

  interface SpawnSyncOptions {
    encoding?: string;
    cwd?: string;
    env?: Record<string, string | undefined>;
  }

  function spawnSync(
    command: string,
    args?: readonly string[],
    options?: SpawnSyncOptions,
  ): SpawnSyncResult;

  function execSync(command: string, options?: SpawnSyncOptions): string;

  export { execSync, spawnSync, SpawnSyncOptions, SpawnSyncResult };
}

declare module 'node:crypto' {
  function randomUUID(): string;
  export { randomUUID };
}

declare module 'node:fs' {
  function existsSync(path: string): boolean;
  function readFileSync(path: string, options?: unknown): string;
  function writeFileSync(path: string, data: string, options?: unknown): void;
  function mkdirSync(path: string, options?: unknown): void;

  export { existsSync, readFileSync, writeFileSync, mkdirSync };
}

declare module 'fs' {
  interface Dirent {
    name: string;
    isDirectory(): boolean;
    isFile(): boolean;
  }

  interface MkdirOptions {
    recursive?: boolean;
  }

  function readFileSync(path: string, options?: unknown): string;
  function writeFileSync(path: string, data: string, options?: unknown): void;
  function appendFileSync(path: string, data: string, options?: unknown): void;
  function mkdirSync(path: string, options?: MkdirOptions): void;
  function readdirSync(path: string, options?: { withFileTypes?: boolean }): Dirent[];

  export { readFileSync, writeFileSync, appendFileSync, mkdirSync, readdirSync, Dirent, MkdirOptions };
  export default {
    readFileSync,
    writeFileSync,
    appendFileSync,
    mkdirSync,
    readdirSync,
  } as const;
}

declare module 'node:fs/promises' {
  function mkdir(path: string, options?: unknown): Promise<void>;
  function writeFile(path: string, data: string, options?: unknown): Promise<void>;

  export { mkdir, writeFile };
}

declare module 'path' {
  function join(...paths: string[]): string;
  function resolve(...paths: string[]): string;
  function dirname(path: string): string;
  function relative(from: string, to: string): string;

  export { join, resolve, dirname, relative };
  export default {
    join,
    resolve,
    dirname,
    relative,
  } as const;
}

declare module 'node:path' {
  function join(...paths: string[]): string;
  function resolve(...paths: string[]): string;
  function dirname(path: string): string;

  export { join, resolve, dirname };
}

declare module 'node:process' {
  interface WritableStream {
    write(data: string): void;
  }

  interface NodeProcess {
    argv: string[];
    env: Record<string, string | undefined>;
    stdout: WritableStream;
    stderr: WritableStream;
    exitCode: number | null;
    platform: string;
    execPath: string;
    cwd(): string;
    exit(code?: number): never;
  }

  const process: NodeProcess;
  export default process;
}

declare module 'node:timers/promises' {
  function setTimeout<T>(delay: number, value?: T): Promise<T>;
  export { setTimeout };
}

declare module 'node:url' {
  interface FileUrl {
    href: string;
  }

  function pathToFileURL(path: string): FileUrl;
  export { pathToFileURL, FileUrl };
}

declare module 'node:module' {
  interface RequireFunction {
    (id: string): unknown;
  }

  function createRequire(filename: string | { href?: string }): RequireFunction;
  export { createRequire, RequireFunction };
}

declare module 'module' {
  interface ModuleType {
    _load: (request: string, parent: NodeModule | null | undefined, isMain: boolean) => unknown;
  }

  const Module: ModuleType;
  export = Module;
}

interface NodeModule {
  exports: unknown;
  require: (id: string) => unknown;
  filename: string;
  paths: string[];
}

declare var process: import('node:process').NodeProcess;
declare var module: NodeModule;
declare function require(id: string): any;
