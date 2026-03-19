comparevi_flag_matrix_find_cli() {
  local cli_path=""
  cli_path="$(command -v LabVIEWCLI 2>/dev/null || true)"
  if [ -n "${cli_path}" ]; then
    printf '%s\n' "${cli_path}"
    return 0
  fi
  cli_path="$(command -v labviewcli 2>/dev/null || true)"
  if [ -n "${cli_path}" ]; then
    printf '%s\n' "${cli_path}"
    return 0
  fi
  cli_path="$(command -v LabVIEWCLI.sh 2>/dev/null || true)"
  if [ -n "${cli_path}" ]; then
    printf '%s\n' "${cli_path}"
    return 0
  fi
  return 1
}

COMPAREVI_FLAG_MATRIX_RESULTS_DIR="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR:-}"
if [ -z "${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}" ]; then
  echo "COMPAREVI_FLAG_MATRIX_RESULTS_DIR is required for the single-container flag matrix bootstrap." 1>&2
  return 2
fi

if ! COMPAREVI_FLAG_MATRIX_REAL_CLI="$(comparevi_flag_matrix_find_cli)"; then
  echo "LabVIEWCLI must be available before the single-container flag matrix bootstrap runs." 1>&2
  return 2
fi

COMPAREVI_FLAG_MATRIX_WRAPPER_DIR="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}/wrapper-bin"
COMPAREVI_FLAG_MATRIX_WRAPPER_PATH="${COMPAREVI_FLAG_MATRIX_WRAPPER_DIR}/LabVIEWCLI"
mkdir -p "${COMPAREVI_FLAG_MATRIX_WRAPPER_DIR}" || return 2

cat > "${COMPAREVI_FLAG_MATRIX_WRAPPER_PATH}" <<EOF
#!/usr/bin/env bash
set -u

REAL_CLI_PATH="${COMPAREVI_FLAG_MATRIX_REAL_CLI}"
RESULTS_DIR="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}"
LEDGER_PATH="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}/flag-matrix-ledger.tsv"
MARKER_PATH="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}/flag-matrix-ran.txt"

BASE_VI=""
HEAD_VI=""
REPORT_PATH=""
COMMON_ARGS=()

comparevi_flag_matrix_arg_has_value() {
  if [ "\$#" -lt 2 ]; then
    return 1
  fi
  case "\$2" in
    ""|-*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -VI1)
      BASE_VI="\${2:-}"
      shift 2
      ;;
    -VI2)
      HEAD_VI="\${2:-}"
      shift 2
      ;;
    -ReportPath)
      REPORT_PATH="\${2:-}"
      shift 2
      ;;
    -OperationName|-ReportType|-LabVIEWPath)
      COMMON_ARGS+=("\$1" "\${2:-}")
      shift 2
      ;;
    -Headless)
      COMMON_ARGS+=("\$1")
      if comparevi_flag_matrix_arg_has_value "\$@"; then
        COMMON_ARGS+=("\${2}")
        shift 2
      else
        COMMON_ARGS+=("true")
        shift
      fi
      ;;
    *)
      COMMON_ARGS+=("\$1")
      shift
      ;;
  esac
done

if [ -z "\${BASE_VI}" ] || [ -z "\${HEAD_VI}" ] || [ -z "\${REPORT_PATH}" ]; then
  echo "Flag matrix wrapper requires -VI1, -VI2, and -ReportPath." 1>&2
  exit 2
fi

mkdir -p "\${RESULTS_DIR}" || exit 2
: > "\${LEDGER_PATH}" || exit 2

scenario_names=()
scenario_flags=()
scenario_catalog_path="\${COMPAREVI_FLAG_MATRIX_SCENARIO_CATALOG:-}"

if [ -n "\${scenario_catalog_path}" ]; then
  if [ ! -f "\${scenario_catalog_path}" ]; then
    echo "COMPAREVI_FLAG_MATRIX_SCENARIO_CATALOG does not exist: \${scenario_catalog_path}" 1>&2
    exit 2
  fi

  while IFS=$'\t' read -r scenario_name scenario_flag_text || [ -n "\${scenario_name:-}" ]; do
    if [ -z "\${scenario_name:-}" ]; then
      continue
    fi
    scenario_names+=("\${scenario_name}")
    scenario_flags+=("\${scenario_flag_text:-}")
  done < "\${scenario_catalog_path}"
else
  scenario_names=(
    "baseline"
    "noattr"
    "nofppos"
    "nobdcosm"
    "noattr__nofppos"
    "noattr__nobdcosm"
    "nofppos__nobdcosm"
    "noattr__nofppos__nobdcosm"
  )
  scenario_flags=(
    ""
    "-noattr"
    "-nofppos"
    "-nobdcosm"
    "-noattr -nofppos"
    "-noattr -nobdcosm"
    "-nofppos -nobdcosm"
    "-noattr -nofppos -nobdcosm"
  )
fi

if [ "\${#scenario_names[@]}" -eq 0 ]; then
  echo "Flag matrix bootstrap resolved no scenarios." 1>&2
  exit 2
fi

processed=0
diffs=0
errors=0
overall_exit=0
index_rows=""

for i in "\${!scenario_names[@]}"; do
  name="\${scenario_names[\$i]}"
  flags_text="\${scenario_flags[\$i]}"
  scenario_report="\${RESULTS_DIR}/\${name}-report.html"
  scenario_report_assets_dir="\${RESULTS_DIR}/\${name}-report_files"
  scenario_log="\${RESULTS_DIR}/\${name}-cli-output.log"
  run_args=("\${COMMON_ARGS[@]}" "-VI1" "\${BASE_VI}" "-VI2" "\${HEAD_VI}" "-ReportPath" "\${scenario_report}")
  if [ -n "\${flags_text}" ]; then
    read -r -a flag_array <<< "\${flags_text}"
    run_args+=("\${flag_array[@]}")
  fi

  rm -f "\${scenario_report}" || exit 2
  rm -rf "\${scenario_report_assets_dir}" || exit 2
  cli_output="\$("\${REAL_CLI_PATH}" "\${run_args[@]}" 2>&1)"
  exit_code=\$?
  printf '%s\n' "\${cli_output}" > "\${scenario_log}" || exit 2
  status="completed"
  diff="false"
  has_diff_markers="false"

  if [ -f "\${scenario_report}" ] && grep -Eiq 'difference-image|difference-heading|diff-detail' "\${scenario_report}"; then
    has_diff_markers="true"
    diff="true"
  fi

  if [ "\${exit_code}" = "1" ]; then
    if [ "\${has_diff_markers}" != "true" ]; then
      status="error"
      diff="false"
    fi
  elif [ "\${exit_code}" != "0" ]; then
    status="error"
    diff="false"
  fi

  processed=\$((processed + 1))
  if [ "\${diff}" = "true" ]; then
    diffs=\$((diffs + 1))
    if [ "\${overall_exit}" = "0" ]; then
      overall_exit=1
    fi
  fi
  if [ "\${status}" = "error" ]; then
    errors=\$((errors + 1))
    overall_exit=2
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "\$((i + 1))" "\${name}" "\${flags_text}" "\${exit_code}" "\${status}" "\${diff}" "\${scenario_report}" "\${scenario_log}" >> "\${LEDGER_PATH}" || exit 2
  index_rows="\${index_rows}  <li>\${name}: status=\${status}; diff=\${diff}; <a href=\"\${name}-report.html\">report</a>; <a href=\"\${name}-cli-output.log\">cli-log</a></li>
"
done

cat > "\${REPORT_PATH}" <<INDEX
<html><body><h1>NI Linux Flag Matrix</h1><ul>
  <li>processed=\${processed}</li>
  <li>diffs=\${diffs}</li>
  <li>errors=\${errors}</li>
</ul><ul>
\${index_rows}</ul></body></html>
INDEX

cat > "\${MARKER_PATH}" <<MARKER
processed=\${processed}
diffs=\${diffs}
errors=\${errors}
overallExit=\${overall_exit}
MARKER

exit "\${overall_exit}"
EOF

chmod +x "${COMPAREVI_FLAG_MATRIX_WRAPPER_PATH}" || return 2

export PATH="${COMPAREVI_FLAG_MATRIX_WRAPPER_DIR}:${PATH}"
export COMPAREVI_FLAG_MATRIX_LEDGER="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}/flag-matrix-ledger.tsv"
export COMPAREVI_FLAG_MATRIX_MARKER="${COMPAREVI_FLAG_MATRIX_RESULTS_DIR}/flag-matrix-ran.txt"
export COMPAREVI_FLAG_MATRIX_WRAPPER_PATH="${COMPAREVI_FLAG_MATRIX_WRAPPER_PATH}"
