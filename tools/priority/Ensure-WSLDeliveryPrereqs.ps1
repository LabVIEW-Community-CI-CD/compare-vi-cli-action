#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [string]$NodeVersion = 'v24.13.1',
  [string]$ReportPath = 'tests/results/_agent/runtime/wsl-delivery-prereqs.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Convert-ToWslPath {
  param([Parameter(Mandatory)][string]$Path)

  try {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
  } catch {
    $resolved = [System.IO.Path]::GetFullPath($Path)
  }
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = ($Matches[2] -replace '\\', '/')
    return "/mnt/$drive/$rest"
  }

  throw "Unable to convert to WSL path: $Path"
}

function Resolve-CommandPath {
  param([Parameter(Mandatory)][string]$Name)

  $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw "Required command not found on the Windows host: $Name"
  }
  return $command.Source
}

function Invoke-TypeScriptBuild {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'tools\npm\run-script.mjs'
  & $nodePath $scriptPath build | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "TypeScript build failed for $RepoRoot"
  }
}

function Repair-CrossPlaneRuntimeWorktrees {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'tools\priority\repair-runtime-worktrees.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [pscustomobject]@{
      repaired = $false
      reason = 'script-missing'
      reportPath = $null
    }
  }

  $reportPath = Join-Path $RepoRoot 'tests\results\_agent\runtime\cross-plane-worktree-repair.json'
  $output = & $nodePath $scriptPath --repo-root $RepoRoot --report $reportPath
  if ($LASTEXITCODE -ne 0) {
    throw "Cross-plane runtime worktree repair failed for $RepoRoot"
  }

  try {
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
  } catch {
    return [pscustomobject]@{
      repaired = $false
      reason = 'report-parse-failed'
      reportPath = $reportPath
    }
  }
}

function Repair-CodexState {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'tools\priority\codex-state-hygiene.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [pscustomobject]@{
      status = 'skipped'
      reason = 'script-missing'
      reportPath = $null
    }
  }

  $reportPath = Join-Path $RepoRoot 'tests\results\_agent\runtime\codex-state-hygiene.json'
  $output = & $nodePath --no-warnings $scriptPath --apply --report $reportPath
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    return [pscustomobject]@{
      status = 'error'
      reason = 'tool-failed'
      exitCode = $exitCode
      reportPath = $reportPath
    }
  }

  try {
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
  } catch {
    return [pscustomobject]@{
      status = 'error'
      reason = 'report-parse-failed'
      reportPath = $reportPath
    }
  }
}

function Repair-RepoGitWorktreeConfig {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $gitDirPath = Join-Path $RepoRoot '.git'
  if (-not (Test-Path -LiteralPath $gitDirPath -PathType Container)) {
    return [pscustomobject]@{
      repaired = $false
      previousWorktree = $null
      reason = 'gitdir-not-directory'
    }
  }

  $currentWorktree = (& git -C $RepoRoot config --local --get core.worktree 2>$null)
  if ([string]::IsNullOrWhiteSpace($currentWorktree)) {
    return [pscustomobject]@{
      repaired = $false
      previousWorktree = $null
      reason = 'already-unset'
    }
  }

  & git -C $RepoRoot config --local --unset-all core.worktree
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to unset core.worktree for $RepoRoot"
  }

  return [pscustomobject]@{
    repaired = $true
    previousWorktree = [string]$currentWorktree
    reason = 'unset-invalid-worktree'
  }
}

function Get-WslDefaultUser {
  param([Parameter(Mandatory)][string]$Distro)

  $user = (& wsl.exe -d $Distro -- bash -lc 'id -un' 2>$null | Select-Object -Last 1)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$user)) {
    throw "Unable to resolve the default WSL user for distro '$Distro'."
  }

  return ([string]$user).Trim()
}

function Ensure-NativeWslDocker {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$TargetUser
  )

  $runtimeDirPath = Join-Path $RepoRoot 'tests\results\_agent\runtime'
  New-Item -ItemType Directory -Path $runtimeDirPath -Force | Out-Null
  $scriptPath = Join-Path $runtimeDirPath 'ensure-native-wsl-docker.sh'
  $reportPath = Join-Path $runtimeDirPath 'wsl-native-docker.json'
  $scriptPathWsl = Convert-ToWslPath -Path $scriptPath

  $bashScript = @'
set -euo pipefail

target_user="${COMPAREVI_WSL_TARGET_USER:?missing target user}"
apt_updated='false'
docker_installed='false'
proxy_killed='false'
service_enabled='false'
native_override_written='false'

export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1 || ! command -v dockerd >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt_updated='true'
  apt-get install -y docker.io >/tmp/comparevi-wsl-native-docker-install.log 2>&1
  docker_installed='true'
fi

mkdir -p /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/comparevi-native.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
EOF
native_override_written='true'

systemctl daemon-reload
systemctl disable --now docker.socket >/dev/null 2>&1 || true
systemctl stop docker.service >/dev/null 2>&1 || true
if pkill -f '^docker-desktop($| )' >/dev/null 2>&1; then
  proxy_killed='true'
fi
pkill -f '/mnt/wsl/docker-desktop' >/dev/null 2>&1 || true
rm -f /var/run/docker.sock /var/run/docker-cli.sock >/dev/null 2>&1 || true

if id -u "$target_user" >/dev/null 2>&1; then
  usermod -aG docker "$target_user" >/dev/null 2>&1 || true
fi

systemctl enable docker.service >/dev/null 2>&1 && service_enabled='true' || true
systemctl restart docker.service

systemd_state="$(systemctl is-system-running 2>/dev/null || true)"
service_state="$(systemctl is-active docker 2>/dev/null || true)"
context_value=''
docker_info_b64=''
server_version=''
attempts=0
for attempt in $(seq 1 30); do
  attempts="$attempt"
  docker_info_b64="$(DOCKER_HOST='unix:///var/run/docker.sock' docker info --format '{{json .}}' 2>/dev/null | base64 -w0 || true)"
  server_version="$(DOCKER_HOST='unix:///var/run/docker.sock' docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  if [ -n "$docker_info_b64" ] && [ -n "$server_version" ]; then
    break
  fi
  sleep 2
done
context_value="$(DOCKER_HOST='unix:///var/run/docker.sock' docker context show 2>/dev/null || true)"
socket_present='false'
socket_owner=''
socket_mode=''
if [ -S /var/run/docker.sock ]; then
  socket_present='true'
  socket_owner="$(stat -c '%U:%G' /var/run/docker.sock 2>/dev/null || true)"
  socket_mode="$(stat -c '%a' /var/run/docker.sock 2>/dev/null || true)"
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
printf '  "serverVersion": "%s",\n' "$server_version"
printf '  "dockerInfoBase64": "%s",\n' "$docker_info_b64"
printf '  "attempts": %s\n' "$attempts"
printf '}\n'
'@

  $bashScript | Set-Content -LiteralPath $scriptPath -Encoding utf8
  $output = & wsl.exe -d $Distro -u root -- env "COMPAREVI_WSL_TARGET_USER=$TargetUser" bash $scriptPathWsl
  if ($LASTEXITCODE -ne 0) {
    throw "Native WSL Docker bootstrap failed for distro '$Distro'."
  }

  $report = (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 10 -ErrorAction Stop)
  $dockerInfoText = ''
  if ($report.PSObject.Properties['dockerInfoBase64'] -and -not [string]::IsNullOrWhiteSpace([string]$report.dockerInfoBase64)) {
    $dockerInfoText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$report.dockerInfoBase64))
  }
  $dockerInfo = if ([string]::IsNullOrWhiteSpace($dockerInfoText)) {
    $null
  } else {
    $dockerInfoText | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  }

  $platformName = if ($dockerInfo -and $dockerInfo.PSObject.Properties['Platform']) { [string]$dockerInfo.Platform.Name } else { '' }
  $operatingSystem = if ($dockerInfo -and $dockerInfo.PSObject.Properties['OperatingSystem']) { [string]$dockerInfo.OperatingSystem } else { '' }
  $serverName = if ($dockerInfo -and $dockerInfo.PSObject.Properties['Name']) { [string]$dockerInfo.Name } else { '' }
  $isDockerDesktop = @($platformName, $operatingSystem, $serverName) -join ' ' -match 'Docker Desktop|docker-desktop'
  $nativeOwned = -not $isDockerDesktop -and `
    ($report.socketPresent -eq $true) -and `
    ($report.serviceState -eq 'active') -and `
    ($dockerInfo -ne $null) -and `
    (-not [string]::IsNullOrWhiteSpace([string]$report.serverVersion)) -and `
    ($dockerInfo.PSObject.Properties['OSType']) -and `
    ([string]$dockerInfo.OSType -eq 'linux')

  $report | Add-Member -NotePropertyName ensuredAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
  $report | Add-Member -NotePropertyName distro -NotePropertyValue $Distro -Force
  $report | Add-Member -NotePropertyName dockerInfo -NotePropertyValue $dockerInfo -Force
  $report | Add-Member -NotePropertyName isDockerDesktop -NotePropertyValue $isDockerDesktop -Force
  $report | Add-Member -NotePropertyName nativeOwned -NotePropertyValue $nativeOwned -Force
  $report.PSObject.Properties.Remove('dockerInfoBase64')

  $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8
  if (-not $nativeOwned) {
    throw "WSL Docker bootstrap did not produce a native distro-owned daemon for '$Distro'. See $reportPath"
  }

  return $report
}

function Invoke-DeliveryHostSignal {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Distro
  )

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'dist\tools\priority\delivery-host-signal.js'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Compiled delivery host signal collector not found: $scriptPath"
  }
  $reportPath = Join-Path $RepoRoot 'tests\results\_agent\runtime\daemon-host-signal.json'
  $isolationPath = Join-Path $RepoRoot 'tests\results\_agent\runtime\delivery-agent-host-isolation.json'
  $output = & $nodePath $scriptPath `
    --mode collect `
    --repo-root $RepoRoot `
    --distro $Distro `
    --docker-host 'unix:///var/run/docker.sock' `
    --report $reportPath `
    --isolation $isolationPath `
    --reset-fingerprint-baseline `
    --allow-runner-services
  if ($LASTEXITCODE -ne 0) {
    throw "Delivery host signal collection failed for distro '$Distro'."
  }

  return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
}

$repoRoot = Resolve-RepoRoot
$reportPath = Join-Path $repoRoot $ReportPath
$ghPath = Resolve-CommandPath -Name 'gh'
$pwshVersion = $PSVersionTable.PSVersion.ToString()
$gitUserName = (& git config --global user.name 2>$null)
$gitUserEmail = (& git config --global user.email 2>$null)
$codexVersion = (& npm view @openai/codex version)
$codexHomePath = Join-Path $HOME '.codex'
$repoGitWorktreeRepair = Repair-RepoGitWorktreeConfig -RepoRoot $repoRoot
$crossPlaneWorktreeRepair = Repair-CrossPlaneRuntimeWorktrees -RepoRoot $repoRoot
$codexStateHygiene = Repair-CodexState -RepoRoot $repoRoot
Invoke-TypeScriptBuild -RepoRoot $repoRoot
$wslDefaultUser = Get-WslDefaultUser -Distro $Distro
$wslNativeDocker = Ensure-NativeWslDocker -RepoRoot $repoRoot -Distro $Distro -TargetUser $wslDefaultUser
$hostSignal = Invoke-DeliveryHostSignal -RepoRoot $repoRoot -Distro $Distro

$env:COMPAREVI_WSL_NODE_VERSION = $NodeVersion
$env:COMPAREVI_WSL_GH_EXE = Convert-ToWslPath -Path $ghPath
$env:COMPAREVI_WSL_PWSH_VERSION = $pwshVersion
$env:COMPAREVI_WSL_CODEX_VERSION = $codexVersion
$env:COMPAREVI_WSL_CODEX_HOME = Convert-ToWslPath -Path $codexHomePath

$runtimeDirPath = Join-Path $repoRoot 'tests/results/_agent/runtime'
New-Item -ItemType Directory -Path $runtimeDirPath -Force | Out-Null
$scriptPath = Join-Path $runtimeDirPath 'ensure-wsl-delivery-prereqs.sh'

$bashScript = @'
set -euo pipefail

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/comparevi-runtime"

node_dist="node-${COMPAREVI_WSL_NODE_VERSION}-linux-x64"
node_root="$HOME/.local/share/comparevi-runtime/$node_dist"

if [ ! -x "$node_root/bin/node" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  node_url="https://nodejs.org/dist/${COMPAREVI_WSL_NODE_VERSION}/${node_dist}.tar.xz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$node_url" -o "$tmp_dir/node.tar.xz"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_dir/node.tar.xz" "$node_url"
  else
    echo "Neither curl nor wget is available inside WSL." >&2
    exit 1
  fi
  tar -xJf "$tmp_dir/node.tar.xz" -C "$HOME/.local/share/comparevi-runtime"
fi

ln -sfn "$node_root/bin/node" "$HOME/.local/bin/node"
ln -sfn "$node_root/bin/npm" "$HOME/.local/bin/npm"
ln -sfn "$node_root/bin/npx" "$HOME/.local/bin/npx"

pwsh_dist="powershell-${COMPAREVI_WSL_PWSH_VERSION}-linux-x64"
pwsh_root="$HOME/.local/share/comparevi-runtime/$pwsh_dist"

if [ ! -x "$pwsh_root/pwsh" ]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  pwsh_url="https://github.com/PowerShell/PowerShell/releases/download/v${COMPAREVI_WSL_PWSH_VERSION}/powershell-${COMPAREVI_WSL_PWSH_VERSION}-linux-x64.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$pwsh_url" -o "$tmp_dir/pwsh.tar.gz"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_dir/pwsh.tar.gz" "$pwsh_url"
  else
    echo "Neither curl nor wget is available inside WSL." >&2
    exit 1
  fi
  mkdir -p "$pwsh_root"
  tar -xzf "$tmp_dir/pwsh.tar.gz" -C "$pwsh_root"
  chmod +x "$pwsh_root/pwsh"
fi

ln -sfn "$pwsh_root/pwsh" "$HOME/.local/bin/pwsh"

write_wrapper() {
  name="$1"
  target="$2"
  wrapper="$HOME/.local/bin/$name"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$target" > "$wrapper"
  chmod +x "$wrapper"
}

export PATH="$HOME/.local/bin:$PATH"
export npm_config_prefix="$HOME/.local"

if [ -n "${COMPAREVI_WSL_CODEX_HOME:-}" ] && [ ! -e "$HOME/.codex" ] && [ -d "${COMPAREVI_WSL_CODEX_HOME}" ]; then
  ln -s "${COMPAREVI_WSL_CODEX_HOME}" "$HOME/.codex"
fi

codex_needs_install=0
if [ ! -x "$HOME/.local/bin/codex" ]; then
  codex_needs_install=1
elif grep -Fq 'wslpath -w "$arg"' "$HOME/.local/bin/codex" 2>/dev/null; then
  codex_needs_install=1
else
  existing_codex_version="$("$HOME/.local/bin/codex" --version 2>/dev/null | awk '{print $NF}')"
  if [ "$existing_codex_version" != "$COMPAREVI_WSL_CODEX_VERSION" ]; then
    codex_needs_install=1
  fi
fi

if [ "$codex_needs_install" -eq 1 ]; then
  rm -f "$HOME/.local/bin/codex"
  install_log="$(mktemp)"
  if ! npm install -g --silent "@openai/codex@${COMPAREVI_WSL_CODEX_VERSION}" >"$install_log" 2>&1; then
    cat "$install_log" >&2
    rm -f "$install_log"
    exit 1
  fi
  rm -f "$install_log"
fi

write_path_converting_wrapper() {
  name="$1"
  target="$2"
  wrapper="$HOME/.local/bin/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'args=()\n'
    printf 'for arg in "$@"; do\n'
    printf '  if [[ "$arg" == /mnt/* ]]; then\n'
    printf '    converted="$(wslpath -w "$arg" 2>/dev/null || printf "%%s" "$arg")"\n'
    printf '    args+=("$converted")\n'
    printf '  else\n'
    printf '    args+=("$arg")\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'exec "%s" "${args[@]}"\n' "$target"
  } > "$wrapper"
  chmod +x "$wrapper"
}

write_path_converting_wrapper gh "$COMPAREVI_WSL_GH_EXE"

if [ -n "${COMPAREVI_WSL_GIT_USER_NAME:-}" ]; then
  git config --global user.name "$COMPAREVI_WSL_GIT_USER_NAME"
fi

if [ -n "${COMPAREVI_WSL_GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "$COMPAREVI_WSL_GIT_USER_EMAIL"
fi

printf '{\n'
printf '  "schema": "priority/wsl-delivery-prereqs@v1",\n'
printf '  "nodeVersion": "%s",\n' "$("$HOME/.local/bin/node" --version)"
printf '  "npmVersion": "%s",\n' "$("$HOME/.local/bin/npm" --version)"
printf '  "codexVersion": "%s",\n' "$("$HOME/.local/bin/codex" --version)"
printf '  "codexPath": "%s",\n' "$HOME/.local/bin/codex"
printf '  "ghPath": "%s",\n' "$HOME/.local/bin/gh"
printf '  "pwshPath": "%s",\n' "$HOME/.local/bin/pwsh"
printf '  "gitUserName": "%s",\n' "$(git config --global user.name)"
printf '  "gitUserEmail": "%s"\n' "$(git config --global user.email)"
printf '}\n'
'@

$bashScript | Set-Content -LiteralPath $scriptPath -Encoding utf8
$scriptPathWsl = Convert-ToWslPath -Path $scriptPath

$output = & wsl.exe -d $Distro -- env `
  "COMPAREVI_WSL_NODE_VERSION=$NodeVersion" `
  "COMPAREVI_WSL_GH_EXE=$($env:COMPAREVI_WSL_GH_EXE)" `
  "COMPAREVI_WSL_PWSH_VERSION=$pwshVersion" `
  "COMPAREVI_WSL_CODEX_VERSION=$codexVersion" `
  "COMPAREVI_WSL_CODEX_HOME=$($env:COMPAREVI_WSL_CODEX_HOME)" `
  "COMPAREVI_WSL_GIT_USER_NAME=$gitUserName" `
  "COMPAREVI_WSL_GIT_USER_EMAIL=$gitUserEmail" `
  bash $scriptPathWsl
if ($LASTEXITCODE -ne 0) {
  throw "WSL delivery prerequisite bootstrap failed for distro '$Distro'."
}

$report = $output | ConvertFrom-Json -Depth 10
$report | Add-Member -NotePropertyName ensuredAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
$report | Add-Member -NotePropertyName distro -NotePropertyValue $Distro -Force
$report | Add-Member -NotePropertyName nodeRequested -NotePropertyValue $NodeVersion -Force
$report | Add-Member -NotePropertyName pwshRequested -NotePropertyValue $pwshVersion -Force
$report | Add-Member -NotePropertyName codexRequested -NotePropertyValue $codexVersion -Force
$report | Add-Member -NotePropertyName repoGitWorktreeRepair -NotePropertyValue $repoGitWorktreeRepair -Force
$report | Add-Member -NotePropertyName crossPlaneWorktreeRepair -NotePropertyValue $crossPlaneWorktreeRepair -Force
$report | Add-Member -NotePropertyName codexStateHygiene -NotePropertyValue $codexStateHygiene -Force
$report | Add-Member -NotePropertyName wslDefaultUser -NotePropertyValue $wslDefaultUser -Force
$report | Add-Member -NotePropertyName wslNativeDocker -NotePropertyValue $wslNativeDocker -Force
$report | Add-Member -NotePropertyName hostSignal -NotePropertyValue $hostSignal.report -Force

$directory = Split-Path -Parent $reportPath
if ($directory) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | ConvertTo-Json -Depth 10
