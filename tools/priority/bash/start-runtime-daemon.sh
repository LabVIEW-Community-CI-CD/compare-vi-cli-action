#!/usr/bin/env bash
set -euo pipefail

: "${COMPAREVI_RUNTIME_DAEMON_LOG:?missing runtime log path}"
: "${COMPAREVI_RUNTIME_DAEMON_CWD:?missing runtime cwd}"
: "${COMPAREVI_RUNTIME_DAEMON_REPO:?missing runtime repo}"
: "${COMPAREVI_RUNTIME_DAEMON_RUNTIME_DIR:?missing runtime dir}"
: "${COMPAREVI_RUNTIME_DAEMON_LEASE_ROOT:?missing lease root}"
: "${COMPAREVI_RUNTIME_DAEMON_POLL_INTERVAL:?missing poll interval}"

exec >> "$COMPAREVI_RUNTIME_DAEMON_LOG" 2>&1

export PATH="$HOME/.local/bin:$PATH"
export AGENT_WRITER_LEASE_OWNER="${AGENT_WRITER_LEASE_OWNER:?missing lease owner}"
export AGENT_WRITER_LEASE_ROOT="${COMPAREVI_RUNTIME_DAEMON_LEASE_ROOT}"
export AGENT_WRITER_LEASE_FORCE_TAKEOVER="${AGENT_WRITER_LEASE_FORCE_TAKEOVER:-true}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export COMPAREVI_DOCKER_RUNTIME_PROVIDER="${COMPAREVI_DOCKER_RUNTIME_PROVIDER:-native-wsl}"
export COMPAREVI_DOCKER_EXPECTED_CONTEXT="${COMPAREVI_DOCKER_EXPECTED_CONTEXT:-}"

cd "$COMPAREVI_RUNTIME_DAEMON_CWD"

args=(
  node
  dist/tools/priority/runtime-daemon.js
  --repo "$COMPAREVI_RUNTIME_DAEMON_REPO"
  --runtime-dir "$COMPAREVI_RUNTIME_DAEMON_RUNTIME_DIR"
  --lease-root "$COMPAREVI_RUNTIME_DAEMON_LEASE_ROOT"
  --poll-interval-seconds "$COMPAREVI_RUNTIME_DAEMON_POLL_INTERVAL"
  --execute-turn
)

if [ "${COMPAREVI_RUNTIME_DAEMON_STOP_ON_IDLE:-false}" = "true" ]; then
  args+=(--stop-on-idle)
fi

exec "${args[@]}"
