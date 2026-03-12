#!/usr/bin/env bash
set -euo pipefail

target_user="${COMPAREVI_WSL_TARGET_USER:?missing target user}"
apt_updated='false'
docker_installed='false'
proxy_killed='false'
service_enabled='false'
native_override_written='false'
lock_acquired='false'
healthy_service_reused='false'
service_restarted='false'
desktop_backed_before_repair='false'

export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1 || ! command -v dockerd >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt_updated='true'
  apt-get install -y docker.io >/tmp/comparevi-wsl-native-docker-install.log 2>&1
  docker_installed='true'
fi

mkdir -p /etc/systemd/system/docker.service.d
mkdir -p /etc/cdi /var/run/cdi /var/lock
cat >/etc/systemd/system/docker.service.d/comparevi-native.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
EOF
native_override_written='true'

exec 9>/var/lock/comparevi-native-docker.lock
flock -w 120 9
lock_acquired='true'

systemctl daemon-reload
systemctl disable docker.socket >/dev/null 2>&1 || true

if id -u "$target_user" >/dev/null 2>&1; then
  usermod -aG docker "$target_user" >/dev/null 2>&1 || true
fi

systemctl enable docker.service >/dev/null 2>&1 && service_enabled='true' || true
systemctl reset-failed docker.service docker.socket >/dev/null 2>&1 || true

collect_docker_state() {
  systemd_state="$(systemctl is-system-running 2>/dev/null || true)"
  service_state="$(systemctl is-active docker.service 2>/dev/null || true)"
  context_value=''
  docker_info_json=''
  docker_info_b64=''
  operating_system=''
  server_name=''
  platform_name=''
  labels_json=''
  server_version=''
  attempts=0
  for attempt in $(seq 1 30); do
    attempts="$attempt"
    docker_info_json="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{json .}}' 2>/dev/null || true)"
    operating_system="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
    server_name="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{.Name}}' 2>/dev/null || true)"
    platform_name="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{if .Platform}}{{.Platform.Name}}{{end}}' 2>/dev/null || true)"
    labels_json="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{json .Labels}}' 2>/dev/null || true)"
    server_version="$(DOCKER_HOST='unix:///var/run/docker.sock' docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    if [ -n "$docker_info_json" ] && [ -n "$server_version" ]; then
      break
    fi
    sleep 2
  done
  docker_info_b64="$(printf '%s' "$docker_info_json" | base64 -w0 || true)"
  context_value="$(DOCKER_HOST='unix:///var/run/docker.sock' docker context show 2>/dev/null || true)"
  socket_present='false'
  socket_owner=''
  socket_mode=''
  if [ -S /var/run/docker.sock ]; then
    socket_present='true'
    socket_owner="$(stat -c '%U:%G' /var/run/docker.sock 2>/dev/null || true)"
    socket_mode="$(stat -c '%a' /var/run/docker.sock 2>/dev/null || true)"
  fi
  desktop_backed_before_repair='false'
  if printf '%s\n%s\n%s\n%s\n' "$operating_system" "$server_name" "$platform_name" "$labels_json" | grep -Eiq 'Docker Desktop|docker-desktop|com\.docker\.desktop'; then
    desktop_backed_before_repair='true'
  fi
}

collect_docker_state
if [ "$service_state" = 'active' ] && [ "$socket_present" = 'true' ] && [ -n "$docker_info_b64" ] && [ -n "$server_version" ] && [ "$desktop_backed_before_repair" != 'true' ]; then
  healthy_service_reused='true'
else
  systemctl disable --now docker.socket >/dev/null 2>&1 || true
  systemctl stop docker.service >/dev/null 2>&1 || true
  if pkill -f '^docker-desktop($| )' >/dev/null 2>&1; then
    proxy_killed='true'
  fi
  pkill -f '/mnt/wsl/docker-desktop' >/dev/null 2>&1 || true
  rm -f /var/run/docker.sock /var/run/docker-cli.sock >/dev/null 2>&1 || true
  systemctl start docker.service
  service_restarted='true'
  collect_docker_state
fi

printf '{\n'
printf '  "schema": "priority/wsl-native-docker@v1",\n'
printf '  "systemdState": "%s",\n' "$systemd_state"
printf '  "serviceState": "%s",\n' "$service_state"
printf '  "context": "%s",\n' "$context_value"
printf '  "dockerHost": "unix:///var/run/docker.sock",\n'
printf '  "socketPresent": %s,\n' "$socket_present"
printf '  "socketOwner": "%s",\n' "$socket_owner"
printf '  "socketMode": "%s",\n' "$socket_mode"
printf '  "targetUser": "%s",\n' "$target_user"
printf '  "aptUpdated": %s,\n' "$apt_updated"
printf '  "dockerInstalled": %s,\n' "$docker_installed"
printf '  "proxyKilled": %s,\n' "$proxy_killed"
printf '  "serviceEnabled": %s,\n' "$service_enabled"
printf '  "overrideWritten": %s,\n' "$native_override_written"
printf '  "lockAcquired": %s,\n' "$lock_acquired"
printf '  "healthyServiceReused": %s,\n' "$healthy_service_reused"
printf '  "serviceRestarted": %s,\n' "$service_restarted"
printf '  "desktopBackedBeforeRepair": %s,\n' "$desktop_backed_before_repair"
printf '  "serverVersion": "%s",\n' "$server_version"
printf '  "dockerInfoBase64": "%s",\n' "$docker_info_b64"
printf '  "attempts": %s\n' "$attempts"
printf '}\n'
