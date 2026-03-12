#!/usr/bin/env node
// @ts-nocheck

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { DEFAULTS } from './lib/delivery-agent-common.js';
import { ensureManagerCommand, emitStatus, runManagerLoop, stopManagerCommand } from './lib/delivery-agent-manager.js';
import { runPrereqsCommand } from './lib/delivery-agent-prereqs.js';

export function parseArgs(argv = process.argv) {
  const tokens = argv.slice(2);
  let command = 'status';
  const knownCommands = new Set(['ensure', 'status', 'stop', 'run', 'prereqs']);
  let index = 0;
  if (knownCommands.has(tokens[0])) {
    command = tokens[0];
    index = 1;
  }

  const options = {
    command,
    repo: DEFAULTS.repo,
    runtimeDir: DEFAULTS.runtimeDir,
    daemonPollIntervalSeconds: DEFAULTS.daemonPollIntervalSeconds,
    cycleIntervalSeconds: DEFAULTS.cycleIntervalSeconds,
    maxCycles: DEFAULTS.maxCycles,
    stopWaitSeconds: DEFAULTS.stopWaitSeconds,
    wslDistro: DEFAULTS.wslDistro,
    sleepMode: DEFAULTS.sleepMode,
    stopWhenNoOpenIssues: DEFAULTS.stopWhenNoOpenIssues,
    reportPath: DEFAULTS.reportPath,
    nodeVersion: DEFAULTS.nodeVersion,
    pwshVersion: DEFAULTS.pwshVersion,
    help: false,
    queueApply: false,
    noPortfolioApply: false,
    projectStatus: 'In Progress',
    projectProgram: 'Shared Infra',
    projectPhase: 'Helper Workflow',
    projectEnvironmentClass: 'Infra',
    projectBlockingSignal: 'Scope',
    projectEvidenceState: 'Partial',
    projectPortfolioTrack: 'Agent UX',
    queuePauseRecoveryThresholdCycles: 2,
    queuePauseRecoveryCooldownMinutes: 30,
    queuePauseRecoveryMaxAttempts: 8,
    queuePauseRecoveryRef: 'develop',
    dispatchValidateOnQueuePause: false,
    queuePauseRecoveryAllowFork: false,
    onlyRecoverQueueWhenEligible: false,
    maxConsecutiveCycleFailures: 0,
    autoBootstrapOnFailure: false,
    autoPrioritySyncLane: false,
    autoDevelopSync: false,
    codexHygieneIntervalCycles: 3,
  };

  const valueOptions = new Set([
    '--repo',
    '--runtime-dir',
    '--daemon-poll-interval-seconds',
    '--cycle-interval-seconds',
    '--max-cycles',
    '--stop-wait-seconds',
    '--wsl-distro',
    '--report-path',
    '--node-version',
    '--pwsh-version',
    '--project-status',
    '--project-program',
    '--project-phase',
    '--project-environment-class',
    '--project-blocking-signal',
    '--project-evidence-state',
    '--project-portfolio-track',
    '--queue-pause-recovery-threshold-cycles',
    '--queue-pause-recovery-cooldown-minutes',
    '--queue-pause-recovery-max-attempts',
    '--queue-pause-recovery-ref',
    '--max-consecutive-cycle-failures',
    '--codex-hygiene-interval-cycles',
  ]);
  const booleanMap = {
    '--sleep-mode': 'sleepMode',
    '--stop-when-no-open-issues': 'stopWhenNoOpenIssues',
    '--queue-apply': 'queueApply',
    '--no-portfolio-apply': 'noPortfolioApply',
    '--dispatch-validate-on-queue-pause': 'dispatchValidateOnQueuePause',
    '--queue-pause-recovery-allow-fork': 'queuePauseRecoveryAllowFork',
    '--only-recover-queue-when-eligible': 'onlyRecoverQueueWhenEligible',
    '--auto-bootstrap-on-failure': 'autoBootstrapOnFailure',
    '--auto-priority-sync-lane': 'autoPrioritySyncLane',
    '--auto-develop-sync': 'autoDevelopSync',
  };

  for (; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (booleanMap[token]) {
      options[booleanMap[token]] = true;
      continue;
    }
    if (valueOptions.has(token)) {
      const value = tokens[index + 1];
      if (!value || value.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      index += 1;
      switch (token) {
        case '--repo': options.repo = value; break;
        case '--runtime-dir': options.runtimeDir = value; break;
        case '--daemon-poll-interval-seconds': options.daemonPollIntervalSeconds = Number(value); break;
        case '--cycle-interval-seconds': options.cycleIntervalSeconds = Number(value); break;
        case '--max-cycles': options.maxCycles = Number(value); break;
        case '--stop-wait-seconds': options.stopWaitSeconds = Number(value); break;
        case '--wsl-distro': options.wslDistro = value; break;
        case '--report-path': options.reportPath = value; break;
        case '--node-version': options.nodeVersion = value; break;
        case '--pwsh-version': options.pwshVersion = value; break;
        case '--project-status': options.projectStatus = value; break;
        case '--project-program': options.projectProgram = value; break;
        case '--project-phase': options.projectPhase = value; break;
        case '--project-environment-class': options.projectEnvironmentClass = value; break;
        case '--project-blocking-signal': options.projectBlockingSignal = value; break;
        case '--project-evidence-state': options.projectEvidenceState = value; break;
        case '--project-portfolio-track': options.projectPortfolioTrack = value; break;
        case '--queue-pause-recovery-threshold-cycles': options.queuePauseRecoveryThresholdCycles = Number(value); break;
        case '--queue-pause-recovery-cooldown-minutes': options.queuePauseRecoveryCooldownMinutes = Number(value); break;
        case '--queue-pause-recovery-max-attempts': options.queuePauseRecoveryMaxAttempts = Number(value); break;
        case '--queue-pause-recovery-ref': options.queuePauseRecoveryRef = value; break;
        case '--max-consecutive-cycle-failures': options.maxConsecutiveCycleFailures = Number(value); break;
        case '--codex-hygiene-interval-cycles': options.codexHygieneIntervalCycles = Number(value); break;
        default: break;
      }
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }
  return options;
}

function printUsage() {
  console.log('Usage: node dist/tools/priority/delivery-agent.js <ensure|status|stop|run|prereqs> [options]');
  console.log('');
  console.log('Commands:');
  console.log('  ensure   Start the detached unattended delivery manager.');
  console.log('  status   Print the current manager/daemon/runtime status report.');
  console.log('  stop     Stop the detached manager and restore runner services.');
  console.log('  run      Execute the manager loop in-process (used by ensure).');
  console.log('  prereqs  Provision the native WSL Docker and delivery prerequisites.');
}

export async function runCli(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printUsage();
    return 0;
  }

  switch (options.command) {
    case 'ensure':
      process.stdout.write(`${JSON.stringify(await ensureManagerCommand(options), null, 2)}\n`);
      return 0;
    case 'status':
      process.stdout.write(`${JSON.stringify(emitStatus({ ...options, outcome: 'status' }), null, 2)}\n`);
      return 0;
    case 'stop':
      process.stdout.write(`${JSON.stringify(await stopManagerCommand(options), null, 2)}\n`);
      return 0;
    case 'prereqs':
      process.stdout.write(`${JSON.stringify(await runPrereqsCommand(options), null, 2)}\n`);
      return 0;
    case 'run':
      await runManagerLoop(options);
      return 0;
    default:
      throw new Error(`Unsupported command: ${options.command}`);
  }
}

const modulePath = path.resolve(fileURLToPath(import.meta.url));
const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath && invokedPath === modulePath) {
  runCli(process.argv).then(
    (exitCode) => process.exit(exitCode),
    (error) => {
      process.stderr.write(`${error?.stack || error?.message || String(error)}\n`);
      process.exit(1);
    },
  );
}
