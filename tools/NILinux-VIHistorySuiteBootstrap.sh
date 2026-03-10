comparevi_vi_history_json_escape() {
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e ':a' -e 'N' -e '$!ba' \
    -e 's/\r/\\r/g' \
    -e 's/\n/\\n/g'
}

comparevi_vi_history_git() {
  if [ -n "${COMPAREVI_VI_HISTORY_GIT_DIR:-}" ]; then
    git --git-dir="${COMPAREVI_VI_HISTORY_GIT_DIR}" --work-tree="${COMPAREVI_VI_HISTORY_GIT_WORK_TREE:-${COMPAREVI_VI_HISTORY_REPO_PATH}}" "$@"
    return $?
  fi
  git -C "${COMPAREVI_VI_HISTORY_REPO_PATH}" "$@"
}

comparevi_vi_history_resolve_ref() {
  comparevi_vi_history_git rev-parse "${1}^{commit}" 2>/dev/null | head -n 1
}

comparevi_vi_history_git_field() {
  comparevi_vi_history_git show -s --format="$2" "$1" 2>/dev/null | head -n 1
}

comparevi_vi_history_ensure_git() {
  if command -v git >/dev/null 2>&1; then
    export COMPAREVI_VI_HISTORY_GIT_BOOTSTRAP_STATUS="${COMPAREVI_VI_HISTORY_GIT_BOOTSTRAP_STATUS:-present}"
    return 0
  fi

  if [ "${COMPAREVI_VI_HISTORY_AUTO_INSTALL_GIT:-1}" != "1" ]; then
    echo "git is required for VI history bootstrap inside the container." 1>&2
    return 2
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "git is required for VI history bootstrap and apt-get is unavailable in the container." 1>&2
    return 2
  fi

  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update; then
    echo "Failed to update apt metadata while bootstrapping git for VI history." 1>&2
    return 2
  fi
  if ! apt-get install -y --no-install-recommends git; then
    echo "Failed to install git for VI history bootstrap." 1>&2
    return 2
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "git installation completed but git is still unavailable in PATH." 1>&2
    return 2
  fi

  export COMPAREVI_VI_HISTORY_GIT_BOOTSTRAP_STATUS="installed"
  return 0
}

comparevi_vi_history_count_lines() {
  if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo 0
    return 0
  fi
  awk 'END { print NR + 0 }' "$1"
}

comparevi_vi_history_prepare_pair_plan() {
  local results_dir="${COMPAREVI_VI_HISTORY_RESULTS_DIR}"
  local work_root="${results_dir}/bootstrap-work"
  local mode_dir="${results_dir}/default"
  local refs_file="${work_root}/pair-candidates.txt"
  local plan_path="${results_dir}/pair-plan.tsv"
  local ledger_path="${results_dir}/pair-results.tsv"
  local requested_report_path="${COMPARE_REPORT_PATH:-${results_dir}/linux-compare-report.html}"
  local max_pairs="${COMPAREVI_VI_HISTORY_MAX_PAIRS:-1}"
  local resolved_baseline="${COMPAREVI_VI_HISTORY_BASELINE_REF:-}"
  local selected_pairs=0
  local total_candidates=0
  local preset_stop_reason="complete"
  local first_head_ref=""
  local last_base_ref=""
  local target_leaf=""

  case "${max_pairs}" in
    ''|*[!0-9]*)
      echo "COMPAREVI_VI_HISTORY_MAX_PAIRS must be an integer." 1>&2
      return 2
      ;;
  esac

  mkdir -p "${work_root}" "${mode_dir}" || return 2
  : > "${refs_file}" || return 2
  : > "${plan_path}" || return 2
  : > "${ledger_path}" || return 2

  if [ -n "${resolved_baseline}" ] && [ "${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}" != "${resolved_baseline}" ]; then
    comparevi_vi_history_git rev-list --first-parent "${resolved_baseline}..${COMPAREVI_VI_HISTORY_HEAD_REF}" -- "${COMPAREVI_VI_HISTORY_TARGET_PATH}" 2>/dev/null > "${refs_file}" || return 2
  else
    comparevi_vi_history_git rev-list --first-parent "${COMPAREVI_VI_HISTORY_HEAD_REF}" -- "${COMPAREVI_VI_HISTORY_TARGET_PATH}" 2>/dev/null > "${refs_file}" || return 2
  fi

  if [ ! -s "${refs_file}" ]; then
    printf '%s\n' "${COMPAREVI_VI_HISTORY_HEAD_REF}" > "${refs_file}" || return 2
  fi

  total_candidates="$(comparevi_vi_history_count_lines "${refs_file}")"
  if [ "${total_candidates}" -gt "${max_pairs}" ]; then
    preset_stop_reason="max-pairs"
  fi

  target_leaf="$(basename "${COMPAREVI_VI_HISTORY_TARGET_PATH}")"
  while IFS= read -r head_ref; do
    local pair_index
    local pair_label
    local pair_dir
    local base_ref
    local base_vi_path
    local head_vi_path
    local pair_report_path

    [ -z "${head_ref}" ] && continue
    if [ "${selected_pairs}" -ge "${max_pairs}" ]; then
      break
    fi

    selected_pairs=$((selected_pairs + 1))
    pair_index="$(printf '%03d' "${selected_pairs}")"
    pair_label="pair-${pair_index}"
    pair_dir="${work_root}/${pair_label}"
    base_ref="$(comparevi_vi_history_git rev-parse "${head_ref}^" 2>/dev/null | head -n 1)"
    if [ -z "${base_ref}" ] && [ -n "${resolved_baseline}" ] && [ "${head_ref}" != "$(comparevi_vi_history_resolve_ref "${resolved_baseline}")" ]; then
      base_ref="$(comparevi_vi_history_resolve_ref "${resolved_baseline}")"
    fi
    if [ -z "${base_ref}" ]; then
      echo "Unable to derive a VI history base ref for ${head_ref}." 1>&2
      return 2
    fi

    mkdir -p "${pair_dir}" || return 2
    base_vi_path="${pair_dir}/base-${target_leaf}"
    head_vi_path="${pair_dir}/head-${target_leaf}"
    pair_report_path="${mode_dir}/${pair_label}-report.html"

    if ! comparevi_vi_history_git show "${base_ref}:${COMPAREVI_VI_HISTORY_TARGET_PATH}" > "${base_vi_path}" 2>/dev/null; then
      echo "Unable to materialize base VI ${COMPAREVI_VI_HISTORY_TARGET_PATH} at ${base_ref}." 1>&2
      return 2
    fi
    if ! comparevi_vi_history_git show "${head_ref}:${COMPAREVI_VI_HISTORY_TARGET_PATH}" > "${head_vi_path}" 2>/dev/null; then
      echo "Unable to materialize head VI ${COMPAREVI_VI_HISTORY_TARGET_PATH} at ${head_ref}." 1>&2
      return 2
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${selected_pairs}" "${base_ref}" "${head_ref}" "${base_vi_path}" "${head_vi_path}" "${pair_report_path}" "${pair_label}" >> "${plan_path}" || return 2
    if [ -z "${first_head_ref}" ]; then
      first_head_ref="${head_ref}"
      export COMPARE_BASE_VI="${base_vi_path}"
      export COMPARE_HEAD_VI="${head_vi_path}"
    fi
    last_base_ref="${base_ref}"
  done < "${refs_file}"

  if [ "${selected_pairs}" -le 0 ]; then
    echo "No VI history pairs were prepared for ${COMPAREVI_VI_HISTORY_TARGET_PATH}." 1>&2
    return 2
  fi

  export COMPARE_REPORT_PATH="${requested_report_path}"
  export COMPAREVI_VI_HISTORY_PAIR_PLAN="${plan_path}"
  export COMPAREVI_VI_HISTORY_RESULT_LEDGER="${ledger_path}"
  export COMPAREVI_VI_HISTORY_SELECTED_PAIR_COUNT="${selected_pairs}"
  export COMPAREVI_VI_HISTORY_TOTAL_PAIR_COUNT="${total_candidates}"
  export COMPAREVI_VI_HISTORY_PRESET_STOP_REASON="${preset_stop_reason}"
  export COMPAREVI_VI_HISTORY_REQUESTED_START_REF="${COMPAREVI_VI_HISTORY_HEAD_REF}"
  export COMPAREVI_VI_HISTORY_START_REF="${first_head_ref}"
  export COMPAREVI_VI_HISTORY_END_REF="${last_base_ref}"
  export COMPAREVI_VI_HISTORY_EMIT_SUITE_BUNDLE=1

  touch "${COMPAREVI_VI_HISTORY_SUITE_MANIFEST}" "${COMPAREVI_VI_HISTORY_CONTEXT}" || return 2
  return 0
}

comparevi_vi_history_emit_suite_bundle() {
  local exit_code="${1:-1}"
  local report_path="${2:-${COMPARE_REPORT_PATH:-}}"
  local generated_at="${3:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

  if [ "${COMPAREVI_VI_HISTORY_EMIT_SUITE_BUNDLE:-0}" != "1" ]; then
    return 0
  fi

  local results_dir="${COMPAREVI_VI_HISTORY_RESULTS_DIR}"
  local suite_manifest="${COMPAREVI_VI_HISTORY_SUITE_MANIFEST}"
  local history_context="${COMPAREVI_VI_HISTORY_CONTEXT}"
  local receipt_path="${COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT:-${results_dir}/vi-history-bootstrap-receipt.json}"
  local mode_dir="${results_dir}/default"
  local mode_manifest="${mode_dir}/manifest.json"
  local plan_path="${COMPAREVI_VI_HISTORY_PAIR_PLAN:-}"
  local ledger_path="${COMPAREVI_VI_HISTORY_RESULT_LEDGER:-}"
  local report_format="html"

  mkdir -p "${mode_dir}" || return 2

  if [ -n "${plan_path}" ] && [ -f "${plan_path}" ] && [ -n "${ledger_path}" ] && [ -f "${ledger_path}" ]; then
    local mode_results_dir="${mode_dir}"
    local requested_start_ref="${COMPAREVI_VI_HISTORY_REQUESTED_START_REF:-${COMPAREVI_VI_HISTORY_HEAD_REF}}"
    local start_ref="${COMPAREVI_VI_HISTORY_START_REF:-${COMPAREVI_VI_HISTORY_HEAD_REF}}"
    local end_ref="${COMPAREVI_VI_HISTORY_END_REF:-}"
    local max_pairs_json="null"
    local max_signal_pairs_json="null"
    local selected_pair_total
    local processed=0
    local mode_diffs=0
    local signal_diffs=0
    local error_count=0
    local last_diff_index="null"
    local last_diff_commit="null"
    local stop_reason="${COMPAREVI_VI_HISTORY_PRESET_STOP_REASON:-complete}"
    local suite_status="ok"
    local comparisons_json=""
    local context_comparisons_json=""
    local comparison_separator=""
    local target_path_escaped
    local results_dir_escaped
    local mode_results_dir_escaped
    local mode_manifest_escaped
    local requested_start_ref_escaped
    local start_ref_escaped
    local end_ref_json="null"
    local branch_ref_escaped
    local branch_budget_json=""

    if [ -n "${COMPAREVI_VI_HISTORY_MAX_PAIRS:-}" ]; then
      max_pairs_json="${COMPAREVI_VI_HISTORY_MAX_PAIRS}"
      max_signal_pairs_json="${COMPAREVI_VI_HISTORY_MAX_PAIRS}"
    fi

    selected_pair_total="$(comparevi_vi_history_count_lines "${plan_path}")"
    target_path_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_TARGET_PATH}")"
    results_dir_escaped="$(comparevi_vi_history_json_escape "${results_dir}")"
    mode_results_dir_escaped="$(comparevi_vi_history_json_escape "${mode_results_dir}")"
    mode_manifest_escaped="$(comparevi_vi_history_json_escape "${mode_manifest}")"
    requested_start_ref_escaped="$(comparevi_vi_history_json_escape "${requested_start_ref}")"
    start_ref_escaped="$(comparevi_vi_history_json_escape "${start_ref}")"
    if [ -n "${end_ref}" ]; then
      end_ref_json="\"$(comparevi_vi_history_json_escape "${end_ref}")\""
    fi
    branch_ref_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_SOURCE_BRANCH:-HEAD}")"

    if [ -n "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS:-}" ]; then
      local baseline_json="null"
      local branch_commit_count_json="null"
      if [ -n "${COMPAREVI_VI_HISTORY_BASELINE_REF:-}" ]; then
        baseline_json="\"$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BASELINE_REF}")\""
      fi
      if [ -n "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT:-}" ]; then
        branch_commit_count_json="${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT}"
      fi
      branch_budget_json=$(
        cat <<EOF
,
  "branchBudget": {
    "sourceBranchRef": "${branch_ref_escaped}",
    "baselineRef": ${baseline_json},
    "maxCommitCount": ${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS},
    "commitCount": ${branch_commit_count_json},
    "status": "ok",
    "reason": "within-limit"
  }
EOF
      )
    fi

    exec 3< "${ledger_path}"
    while IFS="$(printf '\t')" read -r plan_index base_ref head_ref base_vi_path head_vi_path pair_report_path out_name; do
      local ledger_index
      local pair_exit_code
      local pair_status
      local pair_diff
      local ledger_report_path
      local pair_generated_at
      local effective_report_path
      local report_path_escaped
      local result_status
      local diff_value
      local base_short
      local head_short
      local base_subject
      local head_subject
      local base_author
      local head_author
      local base_email
      local head_email
      local base_date
      local head_date
      local depth_value

      IFS="$(printf '\t')" read -r ledger_index pair_exit_code pair_status pair_diff ledger_report_path pair_generated_at <&3 || break
      [ -z "${plan_index}" ] && continue
      processed=$((processed + 1))
      effective_report_path="${ledger_report_path:-${pair_report_path}}"
      report_path_escaped="$(comparevi_vi_history_json_escape "${effective_report_path}")"
      result_status="${pair_status:-completed}"
      diff_value="false"
      if [ "${pair_diff:-false}" = "true" ] || [ "${pair_exit_code:-0}" = "1" ]; then
        diff_value="true"
        mode_diffs=$((mode_diffs + 1))
        signal_diffs=$((signal_diffs + 1))
        last_diff_index="${processed}"
        last_diff_commit="\"$(comparevi_vi_history_json_escape "${head_ref}")\""
      fi
      if [ "${pair_exit_code:-0}" != "0" ] && [ "${pair_exit_code:-0}" != "1" ]; then
        result_status="error"
        error_count=$((error_count + 1))
      fi

      base_short="$(printf '%.12s' "${base_ref}")"
      head_short="$(printf '%.12s' "${head_ref}")"
      base_subject="$(comparevi_vi_history_git_field "${base_ref}" '%s')"
      head_subject="$(comparevi_vi_history_git_field "${head_ref}" '%s')"
      base_author="$(comparevi_vi_history_git_field "${base_ref}" '%an')"
      head_author="$(comparevi_vi_history_git_field "${head_ref}" '%an')"
      base_email="$(comparevi_vi_history_git_field "${base_ref}" '%ae')"
      head_email="$(comparevi_vi_history_git_field "${head_ref}" '%ae')"
      base_date="$(comparevi_vi_history_git_field "${base_ref}" '%cI')"
      head_date="$(comparevi_vi_history_git_field "${head_ref}" '%cI')"
      depth_value=$((processed - 1))

      comparisons_json="${comparisons_json}${comparison_separator}
    {
      \"index\": ${processed},
      \"base\": {
        \"ref\": \"$(comparevi_vi_history_json_escape "${base_ref}")\",
        \"short\": \"$(comparevi_vi_history_json_escape "${base_short}")\"
      },
      \"head\": {
        \"ref\": \"$(comparevi_vi_history_json_escape "${head_ref}")\",
        \"short\": \"$(comparevi_vi_history_json_escape "${head_short}")\"
      },
      \"lineage\": {
        \"type\": \"mainline\",
        \"parentIndex\": ${processed},
        \"parentCount\": ${selected_pair_total},
        \"depth\": ${depth_value}
      },
      \"outName\": \"$(comparevi_vi_history_json_escape "${out_name}")\",
      \"result\": {
        \"diff\": ${diff_value},
        \"exitCode\": ${pair_exit_code:-0},
        \"duration_s\": 0,
        \"status\": \"${result_status}\",
        \"reportPath\": \"${report_path_escaped}\",
        \"categories\": [],
        \"categoryDetails\": [],
        \"categoryBuckets\": [],
        \"categoryBucketDetails\": [],
        \"highlights\": []
      }
    }"

      context_comparisons_json="${context_comparisons_json}${comparison_separator}
    {
      \"mode\": \"default\",
      \"index\": ${processed},
      \"base\": {
        \"full\": \"$(comparevi_vi_history_json_escape "${base_ref}")\",
        \"short\": \"$(comparevi_vi_history_json_escape "${base_short}")\",
        \"subject\": \"$(comparevi_vi_history_json_escape "${base_subject}")\",
        \"author\": \"$(comparevi_vi_history_json_escape "${base_author}")\",
        \"authorEmail\": \"$(comparevi_vi_history_json_escape "${base_email}")\",
        \"date\": \"$(comparevi_vi_history_json_escape "${base_date}")\"
      },
      \"head\": {
        \"full\": \"$(comparevi_vi_history_json_escape "${head_ref}")\",
        \"short\": \"$(comparevi_vi_history_json_escape "${head_short}")\",
        \"subject\": \"$(comparevi_vi_history_json_escape "${head_subject}")\",
        \"author\": \"$(comparevi_vi_history_json_escape "${head_author}")\",
        \"authorEmail\": \"$(comparevi_vi_history_json_escape "${head_email}")\",
        \"date\": \"$(comparevi_vi_history_json_escape "${head_date}")\"
      },
      \"lineage\": {
        \"type\": \"mainline\",
        \"parentIndex\": ${processed},
        \"parentCount\": ${selected_pair_total},
        \"depth\": ${depth_value}
      },
      \"lineageLabel\": \"Mainline\",
      \"result\": {
        \"diff\": ${diff_value},
        \"status\": \"${result_status}\",
        \"duration_s\": 0,
        \"reportPath\": \"${report_path_escaped}\",
        \"categories\": [],
        \"categoryDetails\": [],
        \"categoryBuckets\": [],
        \"categoryBucketDetails\": [],
        \"highlights\": []
      },
      \"highlights\": []
    }"
      comparison_separator=","
    done < "${plan_path}"
    exec 3<&-

    if [ "${processed}" -le 0 ]; then
      stop_reason="no-pairs"
    fi
    if [ "${error_count}" -gt 0 ] || [ "${exit_code}" -gt 1 ]; then
      stop_reason="error"
      suite_status="failed"
    fi

    cat > "${mode_manifest}" <<EOF
{
  "schema": "vi-compare/history@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${requested_start_ref_escaped}",
  "startRef": "${start_ref_escaped}",
  "endRef": ${end_ref_json},
  "maxPairs": ${max_pairs_json},
  "maxSignalPairs": ${max_signal_pairs_json},
  "noisePolicy": "collapse",
  "failFast": false,
  "failOnDiff": false,
  "mode": "default",
  "slug": "default",
  "reportFormat": "${report_format}",
  "flags": [],
  "resultsDir": "${mode_results_dir_escaped}",
  "comparisons": [${comparisons_json}
  ],
  "stats": {
    "processed": ${processed},
    "diffs": ${mode_diffs},
    "signalDiffs": ${signal_diffs},
    "noiseCollapsed": 0,
    "lastDiffIndex": ${last_diff_index},
    "lastDiffCommit": ${last_diff_commit},
    "stopReason": "${stop_reason}",
    "errors": ${error_count},
    "missing": 0,
    "categoryCounts": {},
    "bucketCounts": {},
    "collapsedNoise": {
      "count": 0,
      "indices": [],
      "commits": [],
      "categoryCounts": {},
      "bucketCounts": {}
    }
  },
  "status": "${suite_status}"
}
EOF

    cat > "${suite_manifest}" <<EOF
{
  "schema": "vi-compare/history-suite@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${requested_start_ref_escaped}",
  "startRef": "${start_ref_escaped}",
  "endRef": ${end_ref_json},
  "maxPairs": ${max_pairs_json},
  "maxSignalPairs": ${max_signal_pairs_json},
  "noisePolicy": "collapse",
  "failFast": false,
  "failOnDiff": false,
  "reportFormat": "${report_format}",
  "resultsDir": "${results_dir_escaped}",
  "requestedModes": ["default"],
  "executedModes": ["default"]${branch_budget_json},
  "modes": [
    {
      "name": "default",
      "slug": "default",
      "reportFormat": "${report_format}",
      "flags": [],
      "manifestPath": "${mode_manifest_escaped}",
      "resultsDir": "${mode_results_dir_escaped}",
      "stats": {
        "processed": ${processed},
        "diffs": ${mode_diffs},
        "signalDiffs": ${signal_diffs},
        "noiseCollapsed": 0,
        "lastDiffIndex": ${last_diff_index},
        "lastDiffCommit": ${last_diff_commit},
        "stopReason": "${stop_reason}",
        "errors": ${error_count},
        "missing": 0,
        "categoryCounts": {},
        "bucketCounts": {},
        "collapsedNoise": {
          "count": 0,
          "indices": [],
          "commits": [],
          "categoryCounts": {},
          "bucketCounts": {}
        }
      },
      "status": "${suite_status}"
    }
  ],
  "stats": {
    "modes": 1,
    "processed": ${processed},
    "diffs": ${mode_diffs},
    "signalDiffs": ${signal_diffs},
    "noiseCollapsed": 0,
    "errors": ${error_count},
    "missing": 0,
    "categoryCounts": {},
    "bucketCounts": {}
  },
  "status": "${suite_status}"
}
EOF

    cat > "${history_context}" <<EOF
{
  "schema": "vi-compare/history-context@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${requested_start_ref_escaped}",
  "startRef": "${start_ref_escaped}",
  "endRef": ${end_ref_json},
  "maxPairs": ${max_pairs_json}${branch_budget_json},
  "requestedModes": ["default"],
  "executedModes": ["default"],
  "comparisons": [${context_comparisons_json}
  ]
}
EOF

    cat > "${receipt_path}" <<EOF
{
  "schema": "ni-linux-runtime-bootstrap-receipt@v1",
  "generatedAt": "${generated_at}",
  "mode": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE:-vi-history-suite-smoke}")",
  "repoPath": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_REPO_PATH}")",
  "targetPath": "${target_path_escaped}",
  "sourceBranchRef": "${branch_ref_escaped}",
  "baselineRef": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BASELINE_REF:-}")",
  "gitBootstrap": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_GIT_BOOTSTRAP_STATUS:-unknown}")",
  "requestedStartRef": "${requested_start_ref_escaped}",
  "startRef": "${start_ref_escaped}",
  "endRef": ${end_ref_json},
  "resultsDir": "${results_dir_escaped}",
  "suiteManifestPath": "$(comparevi_vi_history_json_escape "${suite_manifest}")",
  "historyContextPath": "$(comparevi_vi_history_json_escape "${history_context}")",
  "pairPlanPath": "$(comparevi_vi_history_json_escape "${plan_path}")",
  "resultLedgerPath": "$(comparevi_vi_history_json_escape "${ledger_path}")",
  "processedPairs": ${processed},
  "selectedPairs": ${selected_pair_total},
  "reportPath": "$(comparevi_vi_history_json_escape "${report_path}")",
  "compareExitCode": ${exit_code}
}
EOF

    return 0
  fi

  local diff_value="false"
  local result_status="completed"
  local suite_status="ok"
  local mode_diffs=0
  local signal_diffs=0
  local last_diff_index="null"
  local last_diff_commit="null"
  local error_count=0
  local stop_reason="complete"

  case "${exit_code}" in
    0)
      ;;
    1)
      diff_value="true"
      mode_diffs=1
      signal_diffs=1
      last_diff_index=1
      last_diff_commit="\"$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_HEAD_REF}")\""
      ;;
    *)
      result_status="error"
      suite_status="error"
      error_count=1
      stop_reason="error"
      ;;
  esac

  local target_path_escaped
  target_path_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_TARGET_PATH}")"
  local base_ref_escaped
  base_ref_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BASE_REF}")"
  local head_ref_escaped
  head_ref_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_HEAD_REF}")"
  local base_short
  base_short="$(printf '%.12s' "${COMPAREVI_VI_HISTORY_BASE_REF}")"
  local head_short
  head_short="$(printf '%.12s' "${COMPAREVI_VI_HISTORY_HEAD_REF}")"
  local base_subject
  base_subject="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_BASE_REF}" '%s')"
  local head_subject
  head_subject="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_HEAD_REF}" '%s')"
  local base_author
  base_author="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_BASE_REF}" '%an')"
  local head_author
  head_author="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_HEAD_REF}" '%an')"
  local base_email
  base_email="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_BASE_REF}" '%ae')"
  local head_email
  head_email="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_HEAD_REF}" '%ae')"
  local base_date
  base_date="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_BASE_REF}" '%cI')"
  local head_date
  head_date="$(comparevi_vi_history_git_field "${COMPAREVI_VI_HISTORY_HEAD_REF}" '%cI')"
  local results_dir_escaped
  results_dir_escaped="$(comparevi_vi_history_json_escape "${results_dir}")"
  local mode_manifest_escaped
  mode_manifest_escaped="$(comparevi_vi_history_json_escape "${mode_manifest}")"
  local report_path_escaped
  report_path_escaped="$(comparevi_vi_history_json_escape "${report_path}")"
  local branch_ref_escaped
  branch_ref_escaped="$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_SOURCE_BRANCH:-HEAD}")"
  local branch_budget_json=""

  if [ -n "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS:-}" ]; then
    local baseline_json="null"
    if [ -n "${COMPAREVI_VI_HISTORY_BASELINE_REF:-}" ]; then
      baseline_json="\"$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BASELINE_REF}")\""
    fi
    local branch_commit_count_json="null"
    if [ -n "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT:-}" ]; then
      branch_commit_count_json="${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT}"
    fi
    branch_budget_json=$(
      cat <<EOF
,
  "branchBudget": {
    "sourceBranchRef": "${branch_ref_escaped}",
    "baselineRef": ${baseline_json},
    "maxCommitCount": ${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS},
    "commitCount": ${branch_commit_count_json},
    "status": "ok",
    "reason": "within-limit"
  }
EOF
    )
  fi

  cat > "${mode_manifest}" <<EOF
{
  "schema": "vi-compare/history@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${base_ref_escaped}",
  "startRef": "${base_ref_escaped}",
  "endRef": "${head_ref_escaped}",
  "maxPairs": 1,
  "maxSignalPairs": 1,
  "noisePolicy": "collapse",
  "failFast": false,
  "failOnDiff": false,
  "mode": "default",
  "slug": "default",
  "reportFormat": "${report_format}",
  "flags": [],
  "resultsDir": "${results_dir_escaped}",
  "comparisons": [
    {
      "index": 1,
      "base": {
        "ref": "${base_ref_escaped}",
        "short": "$(comparevi_vi_history_json_escape "${base_short}")"
      },
      "head": {
        "ref": "${head_ref_escaped}",
        "short": "$(comparevi_vi_history_json_escape "${head_short}")"
      },
      "lineage": {
        "type": "mainline",
        "parentIndex": 1,
        "parentCount": 1,
        "depth": 0
      },
      "outName": "pair-001",
      "result": {
        "diff": ${diff_value},
        "exitCode": ${exit_code},
        "duration_s": 0,
        "status": "${result_status}",
        "reportPath": "${report_path_escaped}",
        "categories": [],
        "categoryDetails": [],
        "categoryBuckets": [],
        "categoryBucketDetails": [],
        "highlights": []
      }
    }
  ],
  "stats": {
    "processed": 1,
    "diffs": ${mode_diffs},
    "signalDiffs": ${signal_diffs},
    "noiseCollapsed": 0,
    "lastDiffIndex": ${last_diff_index},
    "lastDiffCommit": ${last_diff_commit},
    "stopReason": "${stop_reason}",
    "errors": ${error_count},
    "missing": 0,
    "categoryCounts": {},
    "bucketCounts": {},
    "collapsedNoise": {
      "count": 0,
      "indices": [],
      "commits": [],
      "categoryCounts": {},
      "bucketCounts": {}
    }
  },
  "status": "${suite_status}"
}
EOF

  cat > "${suite_manifest}" <<EOF
{
  "schema": "vi-compare/history-suite@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${base_ref_escaped}",
  "startRef": "${base_ref_escaped}",
  "endRef": "${head_ref_escaped}",
  "maxPairs": 1,
  "maxSignalPairs": 1,
  "noisePolicy": "collapse",
  "failFast": false,
  "failOnDiff": false,
  "reportFormat": "${report_format}",
  "resultsDir": "${results_dir_escaped}",
  "requestedModes": ["default"],
  "executedModes": ["default"]${branch_budget_json},
  "modes": [
    {
      "name": "default",
      "slug": "default",
      "reportFormat": "${report_format}",
      "flags": [],
      "manifestPath": "${mode_manifest_escaped}",
      "resultsDir": "${results_dir_escaped}",
      "stats": {
        "processed": 1,
        "diffs": ${mode_diffs},
        "signalDiffs": ${signal_diffs},
        "noiseCollapsed": 0,
        "lastDiffIndex": ${last_diff_index},
        "lastDiffCommit": ${last_diff_commit},
        "stopReason": "${stop_reason}",
        "errors": ${error_count},
        "missing": 0,
        "categoryCounts": {},
        "bucketCounts": {},
        "collapsedNoise": {
          "count": 0,
          "indices": [],
          "commits": [],
          "categoryCounts": {},
          "bucketCounts": {}
        }
      },
      "status": "${suite_status}"
    }
  ],
  "stats": {
    "modes": 1,
    "processed": 1,
    "diffs": ${mode_diffs},
    "signalDiffs": ${signal_diffs},
    "noiseCollapsed": 0,
    "errors": ${error_count},
    "missing": 0,
    "categoryCounts": {},
    "bucketCounts": {}
  },
  "status": "${suite_status}"
}
EOF

  cat > "${history_context}" <<EOF
{
  "schema": "vi-compare/history-context@v1",
  "generatedAt": "${generated_at}",
  "targetPath": "${target_path_escaped}",
  "requestedStartRef": "${base_ref_escaped}",
  "startRef": "${base_ref_escaped}",
  "maxPairs": 1,
  "requestedModes": ["default"],
  "executedModes": ["default"],
  "comparisons": [
    {
      "mode": "default",
      "index": 1,
      "base": {
        "full": "${base_ref_escaped}",
        "short": "$(comparevi_vi_history_json_escape "${base_short}")",
        "subject": "$(comparevi_vi_history_json_escape "${base_subject}")",
        "author": "$(comparevi_vi_history_json_escape "${base_author}")",
        "authorEmail": "$(comparevi_vi_history_json_escape "${base_email}")",
        "date": "$(comparevi_vi_history_json_escape "${base_date}")"
      },
      "head": {
        "full": "${head_ref_escaped}",
        "short": "$(comparevi_vi_history_json_escape "${head_short}")",
        "subject": "$(comparevi_vi_history_json_escape "${head_subject}")",
        "author": "$(comparevi_vi_history_json_escape "${head_author}")",
        "authorEmail": "$(comparevi_vi_history_json_escape "${head_email}")",
        "date": "$(comparevi_vi_history_json_escape "${head_date}")"
      },
      "lineage": {
        "type": "mainline",
        "parentIndex": 1,
        "parentCount": 1,
        "depth": 0
      },
      "lineageLabel": "Mainline",
      "result": {
        "diff": ${diff_value},
        "status": "${result_status}",
        "duration_s": 0,
        "reportPath": "${report_path_escaped}",
        "categories": [],
        "categoryDetails": [],
        "categoryBuckets": [],
        "categoryBucketDetails": [],
        "highlights": []
      },
      "highlights": []
    }
  ]
}
EOF

  cat > "${receipt_path}" <<EOF
{
  "schema": "ni-linux-runtime-bootstrap-receipt@v1",
  "generatedAt": "${generated_at}",
  "mode": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE:-vi-history-suite-smoke}")",
  "repoPath": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_REPO_PATH}")",
  "targetPath": "${target_path_escaped}",
  "sourceBranchRef": "${branch_ref_escaped}",
  "baselineRef": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_BASELINE_REF:-}")",
  "gitBootstrap": "$(comparevi_vi_history_json_escape "${COMPAREVI_VI_HISTORY_GIT_BOOTSTRAP_STATUS:-unknown}")",
  "baseRef": "${base_ref_escaped}",
  "headRef": "${head_ref_escaped}",
  "resultsDir": "${results_dir_escaped}",
  "suiteManifestPath": "$(comparevi_vi_history_json_escape "${suite_manifest}")",
  "historyContextPath": "$(comparevi_vi_history_json_escape "${history_context}")",
  "reportPath": "${report_path_escaped}",
  "compareExitCode": ${exit_code}
}
EOF

  return 0
}

if [ -z "${COMPAREVI_VI_HISTORY_SUITE_MANIFEST:-}" ] || [ ! -f "${COMPAREVI_VI_HISTORY_SUITE_MANIFEST}" ]; then
  if [ -n "${COMPAREVI_VI_HISTORY_REPO_PATH:-}" ] || [ -n "${COMPAREVI_VI_HISTORY_TARGET_PATH:-}" ]; then
    :
  else
    echo "VI history suite manifest not found: ${COMPAREVI_VI_HISTORY_SUITE_MANIFEST:-}" 1>&2
    return 2
  fi
fi

if [ -z "${COMPAREVI_VI_HISTORY_CONTEXT:-}" ] || [ ! -f "${COMPAREVI_VI_HISTORY_CONTEXT}" ]; then
  if [ -n "${COMPAREVI_VI_HISTORY_REPO_PATH:-}" ] || [ -n "${COMPAREVI_VI_HISTORY_TARGET_PATH:-}" ]; then
    :
  else
    echo "VI history context not found: ${COMPAREVI_VI_HISTORY_CONTEXT:-}" 1>&2
    return 2
  fi
fi

if [ -z "${COMPAREVI_VI_HISTORY_RESULTS_DIR:-}" ]; then
  echo "COMPAREVI_VI_HISTORY_RESULTS_DIR is required." 1>&2
  return 2
fi

mkdir -p "${COMPAREVI_VI_HISTORY_RESULTS_DIR}" || return 2

if [ -n "${COMPAREVI_VI_HISTORY_REPO_PATH:-}" ] || [ -n "${COMPAREVI_VI_HISTORY_TARGET_PATH:-}" ]; then
  if ! comparevi_vi_history_ensure_git; then
    return 2
  fi
  if [ -z "${COMPAREVI_VI_HISTORY_REPO_PATH:-}" ] || [ ! -d "${COMPAREVI_VI_HISTORY_REPO_PATH}" ]; then
    echo "COMPAREVI_VI_HISTORY_REPO_PATH is required and must point to a directory." 1>&2
    return 2
  fi
  if [ -n "${COMPAREVI_VI_HISTORY_GIT_DIR:-}" ] && [ ! -d "${COMPAREVI_VI_HISTORY_GIT_DIR}" ]; then
    echo "COMPAREVI_VI_HISTORY_GIT_DIR is not available: ${COMPAREVI_VI_HISTORY_GIT_DIR}" 1>&2
    return 2
  fi
  if ! comparevi_vi_history_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "COMPAREVI_VI_HISTORY_REPO_PATH is not a git working tree: ${COMPAREVI_VI_HISTORY_REPO_PATH}" 1>&2
    return 2
  fi
  if [ -z "${COMPAREVI_VI_HISTORY_TARGET_PATH:-}" ]; then
    echo "COMPAREVI_VI_HISTORY_TARGET_PATH is required." 1>&2
    return 2
  fi

  COMPAREVI_VI_HISTORY_SOURCE_BRANCH="${COMPAREVI_VI_HISTORY_SOURCE_BRANCH:-HEAD}"
  export COMPAREVI_VI_HISTORY_SOURCE_BRANCH
  local_target_path="${COMPAREVI_VI_HISTORY_TARGET_PATH//\\//}"
  COMPAREVI_VI_HISTORY_TARGET_PATH="${local_target_path}"
  export COMPAREVI_VI_HISTORY_TARGET_PATH

  COMPAREVI_VI_HISTORY_HEAD_REF="$(comparevi_vi_history_resolve_ref "${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}")"
  if [ -z "${COMPAREVI_VI_HISTORY_HEAD_REF}" ]; then
    echo "Unable to resolve VI history source branch: ${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}" 1>&2
    return 2
  fi
  export COMPAREVI_VI_HISTORY_HEAD_REF

  resolved_baseline=""
  if [ -n "${COMPAREVI_VI_HISTORY_BASELINE_REF:-}" ] && comparevi_vi_history_resolve_ref "${COMPAREVI_VI_HISTORY_BASELINE_REF}" >/dev/null 2>&1; then
    resolved_baseline="${COMPAREVI_VI_HISTORY_BASELINE_REF}"
  fi
  if [ -n "${resolved_baseline}" ]; then
    export COMPAREVI_VI_HISTORY_BASELINE_REF="${resolved_baseline}"
  fi

  if [ -n "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS:-}" ] && [ -z "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT:-}" ]; then
    case "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS}" in
      ''|*[!0-9]*)
        echo "COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS must be an integer." 1>&2
        return 2
        ;;
    esac
    count_range="${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}"
    if [ -n "${resolved_baseline}" ]; then
      if [ "${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}" = "${resolved_baseline}" ]; then
        count_range="${resolved_baseline}..${resolved_baseline}"
      else
        count_range="${resolved_baseline}..${COMPAREVI_VI_HISTORY_SOURCE_BRANCH}"
      fi
    fi
    COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT="$(comparevi_vi_history_git rev-list --count --first-parent "${count_range}" 2>/dev/null | head -n 1)"
    export COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT
  fi

  if [ -n "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS:-}" ] && [ -n "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT:-}" ]; then
    case "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS}" in
      ''|*[!0-9]*)
        echo "COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS must be an integer." 1>&2
        return 2
        ;;
    esac
    case "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT}" in
      ''|*[!0-9]*)
        echo "COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT must be an integer." 1>&2
        return 2
        ;;
    esac
    if [ "${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT}" -gt "${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS}" ]; then
      echo "VI history source branch exceeds the commit safeguard (${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT} > ${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS})." 1>&2
      return 2
    fi
  fi

  if ! comparevi_vi_history_prepare_pair_plan; then
    return 2
  fi
fi

BOOTSTRAP_MARKER="${COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER:-${COMPAREVI_VI_HISTORY_RESULTS_DIR}/vi-history-bootstrap-ran.txt}"
cat > "${BOOTSTRAP_MARKER}" <<EOF
mode=${COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE:-vi-history-suite-smoke}
branch=${COMPAREVI_VI_HISTORY_SOURCE_BRANCH:-}
maxCommits=${COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS:-}
commitCount=${COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT:-}
manifest=${COMPAREVI_VI_HISTORY_SUITE_MANIFEST:-}
context=${COMPAREVI_VI_HISTORY_CONTEXT:-}
results=${COMPAREVI_VI_HISTORY_RESULTS_DIR}
target=${COMPAREVI_VI_HISTORY_TARGET_PATH:-}
EOF

export COMPAREVI_VI_HISTORY_BOOTSTRAP_READY=1
