#!/usr/bin/env node
import process from 'node:process';
import { runLocalCollaborationPhase } from '../../local-collab/orchestrator/run-phase.mjs';

const result = await runLocalCollaborationPhase({
  phase: 'pre-commit',
  repoRoot: process.cwd(),
  env: process.env
});

process.exit(result.exitCode);
