#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/comparevi-runtime"

node_dist="node-${COMPAREVI_WSL_NODE_VERSION:?missing}-linux-x64"
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

pwsh_dist="powershell-${COMPAREVI_WSL_PWSH_VERSION:?missing}-linux-x64"
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
  if [ "$existing_codex_version" != "${COMPAREVI_WSL_CODEX_VERSION:?missing}" ]; then
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

write_path_converting_wrapper gh "${COMPAREVI_WSL_GH_EXE:?missing}"

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
