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

$directory = Split-Path -Parent $reportPath
if ($directory) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
$report | ConvertTo-Json -Depth 10
