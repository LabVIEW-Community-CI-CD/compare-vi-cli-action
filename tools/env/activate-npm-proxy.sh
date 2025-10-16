#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="$(cd -- "$SCRIPT_DIR/../npm/bin" && pwd)"
case ":$PATH:" in
  *":$WRAPPER_DIR:"*) ;;
  *) export PATH="$WRAPPER_DIR:$PATH" ;;
esac
