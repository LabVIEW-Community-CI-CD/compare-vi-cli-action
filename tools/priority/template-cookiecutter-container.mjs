#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const modulePath = fileURLToPath(import.meta.url);
const moduleDir = path.dirname(modulePath);
const repoRoot = path.resolve(moduleDir, '..', '..');

export const DEFAULT_POLICY_PATH = path.join(repoRoot, 'tools', 'policy', 'template-dependency.json');
export const DEFAULT_OUTPUT_PATH = path.join(
  repoRoot,
  'tests',
  'results',
  '_agent',
  'template-cookiecutter',
  'template-cookiecutter-container.json'
);
const DEFAULT_CONTAINER_MOUNT_ROOT = '/workspace';

function getPlatformPath(platform = os.platform()) {
  return platform === 'win32' ? path.win32 : path.posix;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

export function isDirectExecution(currentModulePath = modulePath, currentArgvPath = process.argv[1] ?? null) {
  if (!currentArgvPath) {
    return false;
  }

  return path.resolve(currentArgvPath) === path.resolve(currentModulePath);
}

export function parseArgs(argv = process.argv) {
  const options = {
    policyPath: DEFAULT_POLICY_PATH,
    outputPath: DEFAULT_OUTPUT_PATH,
    workspaceRoot: null,
    laneId: 'template-cookiecutter',
    runId: null,
    contextFilePath: null,
    containerImage: null,
    dryRun: false,
    failOnError: true
  };

  for (let index = 2; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--policy-path') {
      options.policyPath = argv[++index];
    } else if (token === '--output') {
      options.outputPath = argv[++index];
    } else if (token === '--workspace-root') {
      options.workspaceRoot = argv[++index];
    } else if (token === '--lane-id') {
      options.laneId = argv[++index];
    } else if (token === '--run-id') {
      options.runId = argv[++index];
    } else if (token === '--context-file') {
      options.contextFilePath = argv[++index];
    } else if (token === '--container-image') {
      options.containerImage = argv[++index];
    } else if (token === '--dry-run') {
      options.dryRun = true;
    } else if (token === '--no-fail-on-error') {
      options.failOnError = false;
    } else {
      throw new Error(`Unknown argument: ${token}`);
    }
  }

  return options;
}

export function loadTemplateDependencyPolicy(policyPath = DEFAULT_POLICY_PATH) {
  const policy = readJson(policyPath);
  if (!policy || typeof policy !== 'object') {
    throw new Error(`Template dependency policy must be a JSON object: ${policyPath}`);
  }
  return policy;
}

export function slugifySegment(value, fallback = 'template-cookiecutter') {
  const normalized = String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');

  return normalized || fallback;
}

export function resolveWorkspaceRoot(policy, platform = os.platform(), overrideRoot = null) {
  const platformPath = getPlatformPath(platform);
  if (overrideRoot) {
    return platformPath.normalize(overrideRoot);
  }

  if (platform === 'win32') {
    return platformPath.normalize(
      policy.workspaceRoots?.win32 ??
        policy.workspaceRoots?.posix ??
        platformPath.join(os.tmpdir(), 'comparevi-template-consumers')
    );
  }

  return platformPath.normalize(
    policy.workspaceRoots?.posix ??
      policy.workspaceRoots?.win32 ??
      platformPath.join(os.tmpdir(), 'comparevi-template-consumers')
  );
}

export function createRunToken(now = new Date(), uniqueSuffix = crypto.randomBytes(3).toString('hex')) {
  const stamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z').replace('T', 't').replace('Z', 'z');
  return `${stamp}-${process.pid}-${uniqueSuffix}`;
}

export function buildContainerName(policy, laneId, runToken) {
  const prefix = slugifySegment(policy.rendering?.uniqueContainerNamePrefix ?? 'comparevi-template', 'comparevi-template');
  const laneSlug = slugifySegment(laneId);
  const tokenSlug = slugifySegment(runToken, 'run');
  return `${prefix}-${laneSlug}-${tokenSlug}`.slice(0, 120);
}

export function loadTemplateContext(options = {}) {
  if (options.context) {
    return options.context;
  }

  const contextFilePath = options.contextFilePath ?? options.defaultContextFilePath ?? null;
  if (contextFilePath) {
    return readJson(contextFilePath);
  }

  return {};
}

export function resolveContainerUser(platform = os.platform(), currentProcess = process) {
  if (platform === 'win32') {
    return null;
  }

  if (typeof currentProcess?.getuid !== 'function' || typeof currentProcess?.getgid !== 'function') {
    return null;
  }

  return `${currentProcess.getuid()}:${currentProcess.getgid()}`;
}

export function buildCookiecutterPythonScript({
  templateRepositoryUrl,
  templateDirectory,
  checkout,
  outputDir,
  context
}) {
  const contextJson = JSON.stringify(context ?? {});
  const lines = [
    'import json',
    'import os',
    'from cookiecutter.main import cookiecutter',
    'template_repo = os.environ["COMPAREVI_TEMPLATE_REPOSITORY_URL"]',
    'template_directory = os.environ.get("COMPAREVI_TEMPLATE_DIRECTORY") or None',
    'output_dir = os.environ["COMPAREVI_TEMPLATE_OUTPUT_DIR"]',
    'extra_context = json.loads(os.environ.get("COMPAREVI_TEMPLATE_EXTRA_CONTEXT_JSON", "{}"))',
    `checkout = ${JSON.stringify(checkout)}`,
    'kwargs = {',
    '    "checkout": checkout,',
    '    "no_input": True,',
    '    "overwrite_if_exists": True,',
    '    "output_dir": output_dir,',
    '    "extra_context": extra_context,',
    '    "accept_hooks": "yes",',
    '}',
    'if template_directory:',
    '    kwargs["directory"] = template_directory',
    'project_dir = cookiecutter(template_repo, **kwargs)',
    'print(json.dumps({',
    '    "schema": "comparevi-cookiecutter-run@v1",',
    '    "project_dir": project_dir,',
    '    "template_repository_url": template_repo,',
    '    "template_directory": template_directory,',
    '    "checkout": checkout,',
    '    "output_dir": output_dir,',
    '    "context_keys": sorted(extra_context.keys()),',
    '}, indent=None))'
  ];

  return {
    script: lines.join('\n'),
    contextJson,
    templateRepositoryUrl,
    templateDirectory,
    checkout,
    outputDir
  };
}

export function buildTemplateCookiecutterContainerPlan(options = {}, deps = {}) {
  const policy = loadTemplateDependencyPolicy(options.policyPath ?? DEFAULT_POLICY_PATH);
  const platform = deps.platform ?? os.platform();
  const currentProcess = deps.currentProcess ?? process;
  const now = deps.now ?? new Date();
  const uniqueSuffixFn = deps.uniqueSuffixFn ?? (() => crypto.randomBytes(3).toString('hex'));
  const uniqueSuffix = uniqueSuffixFn();
  const platformPath = getPlatformPath(platform);
  const runToken = options.runId ? slugifySegment(options.runId, 'run') : createRunToken(now, uniqueSuffix);
  const laneId = options.laneId ?? 'template-cookiecutter';
  const laneSlug = slugifySegment(laneId);
  const hostWorkspaceRoot = resolveWorkspaceRoot(policy, platform, options.workspaceRoot);
  const hostRunRoot = platformPath.join(hostWorkspaceRoot, laneSlug, runToken);
  const hostOutputRoot = platformPath.join(hostRunRoot, 'output');
  const containerWorkspaceRoot = path.posix.join(DEFAULT_CONTAINER_MOUNT_ROOT, laneSlug, runToken);
  const containerOutputRoot = path.posix.join(containerWorkspaceRoot, 'output');
  const templateDirectory = options.templateDirectory ?? policy.templateDirectory ?? null;
  const defaultContextFilePath = policy.rendering?.defaultContextPath
    ? path.resolve(repoRoot, policy.rendering.defaultContextPath)
    : null;
  const context = loadTemplateContext({
    ...options,
    defaultContextFilePath
  });
  const containerName = buildContainerName(policy, laneSlug, runToken);
  const templateRepositoryUrl = policy.templateRepositoryUrl;
  const checkout = policy.rendering?.checkout ?? policy.templateReleaseRef;
  const containerImage = options.containerImage ?? policy.container?.image;
  const containerUser = resolveContainerUser(platform, currentProcess);

  if (!templateRepositoryUrl) {
    throw new Error('Template dependency policy is missing templateRepositoryUrl.');
  }
  if (!containerImage) {
    throw new Error('Template dependency policy is missing container.image.');
  }
  if (!checkout) {
    throw new Error('Template dependency policy is missing rendering.checkout.');
  }

  const script = buildCookiecutterPythonScript({
    templateRepositoryUrl,
    templateDirectory,
    checkout,
    outputDir: containerOutputRoot,
    context
  });

  const dockerArgs = [
    'run',
    '--rm',
    '--name',
    containerName
  ];

  if (containerUser) {
    dockerArgs.push('--user', containerUser);
  }

  dockerArgs.push(
    '--volume',
    `${hostWorkspaceRoot}:${DEFAULT_CONTAINER_MOUNT_ROOT}`,
    '--workdir',
    containerWorkspaceRoot,
    '--env',
    `COMPAREVI_TEMPLATE_REPOSITORY_URL=${templateRepositoryUrl}`,
    '--env',
    `COMPAREVI_TEMPLATE_OUTPUT_DIR=${containerOutputRoot}`,
    '--env',
    `COMPAREVI_TEMPLATE_EXTRA_CONTEXT_JSON=${script.contextJson}`,
    '--env',
    `COMPAREVI_TEMPLATE_DIRECTORY=${templateDirectory ?? ''}`,
    '--env',
    `COMPAREVI_TEMPLATE_CHECKOUT=${checkout}`,
    containerImage,
    'python3',
    '-c',
    script.script
  );

  return {
    policyPath: options.policyPath ?? DEFAULT_POLICY_PATH,
    policy,
    laneId,
    runToken,
    hostWorkspaceRoot,
    hostRunRoot,
    hostOutputRoot,
    containerName,
    containerWorkspaceRoot,
    containerOutputRoot,
    templateRepositoryUrl,
    templateDirectory,
    checkout,
    containerImage,
    context,
    containerUser,
    dockerArgs,
    command: 'docker',
    now: now.toISOString(),
    dryRun: Boolean(options.dryRun),
    outputPath: options.outputPath ?? DEFAULT_OUTPUT_PATH,
    failOnError: options.failOnError ?? true
  };
}

export function runTemplateCookiecutterContainer(options = {}, deps = {}) {
  const plan = buildTemplateCookiecutterContainerPlan(options, deps);
  fs.mkdirSync(plan.hostOutputRoot, { recursive: true });
  const defaultContextPath = plan.policy.rendering?.defaultContextPath ?? null;
  const contextSource = options.context
    ? 'inline'
    : options.contextFilePath
      ? 'file'
      : defaultContextPath
        ? 'policy-default-file'
        : 'default-empty';

  const receipt = {
    schema: 'priority/template-cookiecutter-container@v1',
    generatedAt: plan.now,
    status: plan.dryRun ? 'dry-run' : 'pending',
    policyPath: plan.policyPath,
    policy: {
      schema: plan.policy.schema,
      schemaVersion: plan.policy.schemaVersion,
      templateRepositorySlug: plan.policy.templateRepositorySlug,
      templateRepositoryUrl: plan.policy.templateRepositoryUrl,
      templateReleaseRef: plan.policy.templateReleaseRef,
      templateDirectory: plan.policy.templateDirectory,
      cookiecutterVersion: plan.policy.cookiecutterVersion,
      executionPlane: plan.policy.container?.executionPlane ?? null,
      containerRuntime: plan.policy.container?.runtime ?? null,
      containerImage: plan.policy.container?.image ?? null,
      effectiveContainerImage: plan.containerImage,
      workspaceRoots: plan.policy.workspaceRoots,
      rendering: plan.policy.rendering
    },
    run: {
      laneId: plan.laneId,
      runToken: plan.runToken,
      hostWorkspaceRoot: plan.hostWorkspaceRoot,
      hostRunRoot: plan.hostRunRoot,
      hostOutputRoot: plan.hostOutputRoot,
      containerName: plan.containerName,
      containerWorkspaceRoot: plan.containerWorkspaceRoot,
      containerOutputRoot: plan.containerOutputRoot,
      containerUser: plan.containerUser,
      contextSource,
      contextFilePath: options.contextFilePath ?? defaultContextPath,
      contextKeys: Object.keys(plan.context).sort(),
      deterministicInput: true,
      uniqueContainerName: true,
      uniqueWorkspaceRoot: true
    },
    command: {
      executable: plan.command,
      args: plan.dockerArgs,
      containerImage: plan.containerImage
    },
    result: {
      exitCode: null,
      projectDir: null,
      stdout: null,
      stderr: null
    }
  };

  if (plan.dryRun) {
    writeJson(plan.outputPath, receipt);
    return { plan, receipt };
  }

  const result = (deps.spawnSyncFn ?? spawnSync)(plan.command, plan.dockerArgs, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });

  const stdout = String(result.stdout ?? '').trim();
  const stderr = String(result.stderr ?? '').trim();
  let childReceipt = null;

  if (stdout) {
    const lastLine = stdout.split(/\r?\n/).filter(Boolean).at(-1);
    try {
      childReceipt = JSON.parse(lastLine);
    } catch (error) {
      throw new Error(`Cookiecutter container produced non-JSON stdout: ${error.message}`);
    }
  }

  receipt.status = result.status === 0 ? 'pass' : 'failed';
  receipt.result = {
    exitCode: result.status,
    projectDir: childReceipt?.project_dir ?? childReceipt?.projectDir ?? null,
    stdout: stdout || null,
    stderr: stderr || null
  };

  writeJson(plan.outputPath, receipt);

  if (result.status !== 0 && plan.failOnError) {
    const error = new Error(`docker run failed with exit code ${result.status}`);
    error.receipt = receipt;
    throw error;
  }

  return { plan, receipt, spawnResult: result };
}

if (isDirectExecution()) {
  const options = parseArgs(process.argv);
  const { receipt } = runTemplateCookiecutterContainer(options);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
