#!/usr/bin/env node

import { runRuntimeSupervisor } from './index.mjs';

export async function runRuntimeWorkerStatus(options = {}, deps = {}) {
  return runRuntimeSupervisor({ ...options, action: 'status' }, deps);
}

export async function runRuntimeWorkerStep(options = {}, deps = {}) {
  return runRuntimeSupervisor({ ...options, action: 'step' }, deps);
}

export async function runRuntimeWorkerStop(options = {}, deps = {}) {
  return runRuntimeSupervisor({ ...options, action: 'stop' }, deps);
}

export async function runRuntimeWorkerResume(options = {}, deps = {}) {
  return runRuntimeSupervisor({ ...options, action: 'resume' }, deps);
}
