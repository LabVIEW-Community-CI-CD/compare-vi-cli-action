#!/usr/bin/env python3
"""
Workflow updater (ruamel.yaml round-trip)

Initial transforms (safe, minimal):
- pester-selfhosted.yml
  * Ensure workflow_dispatch.inputs.force_run exists
  * In jobs.pre-init:
      - Gate pre-init-gate step with `if: ${{ inputs.force_run != 'true' }}`
      - Add `Compute docs_only (force_run aware)` step (id: out)
      - Set outputs.docs_only to `${{ steps.out.outputs.docs_only }}`

Usage:
  python tools/workflows/update_workflows.py --check .github/workflows/pester-selfhosted.yml
  python tools/workflows/update_workflows.py --write .github/workflows/pester-selfhosted.yml
"""
from __future__ import annotations
import sys
from pathlib import Path
from typing import List

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import SingleQuotedScalarString as SQS, LiteralScalarString as LIT, DoubleQuotedScalarString as DQS


yaml = YAML(typ='rt')
yaml.preserve_quotes = True
yaml.width = 4096  # avoid folding


def load_yaml(path: Path):
    with path.open('r', encoding='utf-8') as fp:
        return yaml.load(fp)


def dump_yaml(doc, path: Path) -> str:
    from io import StringIO
    sio = StringIO()
    yaml.dump(doc, sio)
    return sio.getvalue()


def ensure_force_run_input(doc) -> bool:
    changed = False
    on = doc.get('on') or doc.get('on:') or {}
    if not on:
        return changed
    wd = on.get('workflow_dispatch')
    if wd is None:
        return changed
    inputs = wd.setdefault('inputs', {})
    if 'force_run' not in inputs:
        inputs['force_run'] = {
            'description': 'Force run (bypass docs-only gate)',
            'required': False,
            'default': 'false',
            'type': 'choice',
            'options': ['true', 'false'],
        }
        changed = True
    return changed


def ensure_preinit_force_run_outputs(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    pre = jobs.get('pre-init')
    if not isinstance(pre, dict):
        return changed
    # outputs.docs_only -> steps.out.outputs.docs_only
    outputs = pre.setdefault('outputs', {})
    want = SQS("${{ steps.out.outputs.docs_only }}")
    if outputs.get('docs_only') != want:
        outputs['docs_only'] = want
        changed = True
    # steps: add `if` on id=g and add out step if missing
    steps: List[dict] = pre.setdefault('steps', [])
    # find index of id: g pre-init gate step
    idx_g = None
    for i, st in enumerate(steps):
        if isinstance(st, dict) and st.get('id') == 'g' and st.get('uses', '').endswith('pre-init-gate'):
            idx_g = i
            break
    if idx_g is not None:
        if steps[idx_g].get('if') != SQS("${{ inputs.force_run != 'true' }}"):
            steps[idx_g]['if'] = SQS("${{ inputs.force_run != 'true' }}")
            changed = True
        # ensure out step exists after g
        has_out = any(isinstance(st, dict) and st.get('id') == 'out' for st in steps)
        if not has_out:
            run_body = (
                "$force = '${{ inputs.force_run }}'\n"
                "if ($force -ieq 'true') { $val = 'false' } else { $val = '${{ steps.g.outputs.docs_only || ''false'' }}' }\n"
                '"docs_only=$val" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8\n'
            )
            out_step = {
                'name': 'Compute docs_only (force_run aware)',
                'id': 'out',
                'shell': 'pwsh',
                'run': LIT(run_body),
            }
            steps.insert(idx_g + 1, out_step)
            changed = True
    return changed


def _mk_hosted_preflight_step() -> dict:
    lines = [
        'Write-Host "Runner: $([System.Environment]::OSVersion.VersionString)"',
        'Write-Host "Pwsh:   $($PSVersionTable.PSVersion)"',
        "$cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'",
        'if (-not (Test-Path -LiteralPath $cli)) {',
        '  Write-Host "::notice::LVCompare.exe not found at canonical path: $cli (hosted preflight)"',
        '} else { Write-Host "LVCompare present: $cli" }',
        "$lv = Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue",
        'if ($lv) { Write-Host "::error::LabVIEW.exe is running (PID(s): $($lv.Id -join ','))"; exit 1 }',
        "Write-Host 'Preflight OK: Windows runner healthy; LabVIEW not running.'",
        'if ($env:GITHUB_STEP_SUMMARY) {',
        "  $note = @('Note:', '- This preflight runs on hosted Windows (windows-latest); LVCompare presence is not required here.', '- Self-hosted Windows steps later in this workflow enforce LVCompare at the canonical path.') -join \"`n\"",
        '  $note | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8',
        '}',
    ]
    body = "\n".join(lines)
    return {
        'name': 'Verify Windows runner and idle LabVIEW (surface LVCompare notice)',
        'shell': 'pwsh',
        'run': LIT(body),
    }


def _mk_rerun_hint_step(default_strategy: str) -> dict:
    """Create the 'Re-run With Same Inputs' step body for job summaries.

    default_strategy: 'matrix' for publish, 'single' for windows-single
    """
    lines = [
        f"$strategy = if ($env:GH_STRATEGY) {{ $env:GH_STRATEGY }} else {{ '{default_strategy}' }}",
        "$include = if ($env:GH_INCLUDE) { $env:GH_INCLUDE } else { 'true' }",
        "$sid = if ($env:GH_SAMPLE_ID) { $env:GH_SAMPLE_ID } else { '<id>' }",
        "$cmd = \"/run orchestrated strategy={0} include_integration={1} sample_id={2}\" -f $strategy,$include,$sid",
        "$lines = @('### Re-run With Same Inputs','',\"$ $cmd\")",
        "if ($env:GITHUB_STEP_SUMMARY) { $lines -join \"`n\" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }",
    ]
    step = {
        'if': SQS("${{ always() }}"),
        'name': 'Re-run with same inputs' if default_strategy == 'matrix' else 'Re-run with same inputs (single)',
        'shell': 'pwsh',
        'env': {
            'GH_STRATEGY': SQS("${{ inputs.strategy }}"),
            'GH_INCLUDE': SQS("${{ inputs.include_integration }}"),
            'GH_SAMPLE_ID': SQS("${{ inputs.sample_id }}"),
        },
        'run': LIT("\n".join(lines)),
    }
    return step


def ensure_rerun_hint_in_job(doc, job_name: str, default_strategy: str) -> bool:
    """Ensure the rerun hint step exists (and is normalized) in the given job."""
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        return False
    steps = job.setdefault('steps', [])
    want = _mk_rerun_hint_step(default_strategy)
    label = want['name']
    changed = False
    # try to find by exact name
    for i, st in enumerate(steps):
        if isinstance(st, dict) and st.get('name') == label:
            # normalize fields
            for k in ('if', 'shell', 'env', 'run'):
                if st.get(k) != want[k]:
                    st[k] = want[k]
                    changed = True
            break
    else:
        # Not found; append at the end
        steps.append(want)
        job['steps'] = steps
        changed = True
    return changed


def ensure_rerun_hint_after_summary(doc, default_strategy: str) -> bool:
    """Inject rerun hint into the job that aggregates summaries (heuristic: contains 'Summarize Pester categories')."""
    jobs = doc.get('jobs') or {}
    changed = False
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        idx = None
        for i, st in enumerate(steps):
            if isinstance(st, dict) and st.get('name', '').strip().startswith('Summarize Pester categories'):
                idx = i
                break
        if idx is None:
            continue
        want = _mk_rerun_hint_step(default_strategy)
        label = want['name']
        # If it already exists anywhere in the job, normalize it; otherwise insert right after summary
        existing = None
        for i, st in enumerate(steps):
            if isinstance(st, dict) and st.get('name') == label:
                existing = i
                break
        if existing is not None:
            for k in ('if', 'shell', 'env', 'run'):
                if steps[existing].get(k) != want[k]:
                    steps[existing][k] = want[k]
                    changed = True
        else:
            steps.insert(idx + 1, want)
            job['steps'] = steps
            changed = True
    return changed


def ensure_interactivity_probe_job(doc) -> bool:
    """Add a lightweight 'probe' job to check interactivity on self-hosted Windows.
    Wires outputs.ok from steps.out.outputs.ok and depends on normalize+preflight.
    """
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return False
    if 'probe' in jobs:
        return False
    job = {
        'if': SQS("${{ inputs.strategy == 'single' || vars.ORCH_STRATEGY == 'single' }}"),
        'runs-on': ['self-hosted', 'Windows', 'X64'],
        'timeout-minutes': 2,
        'needs': ['normalize', 'preflight'],
        'outputs': {
            'ok': SQS("${{ steps.out.outputs.ok }}"),
        },
        'steps': [
            {'uses': 'actions/checkout@v5'},
            {
                'name': 'Run interactivity probe',
                'id': 'out',
                'shell': 'pwsh',
                'run': LIT(
                    "pwsh -File tools/Write-InteractivityProbe.ps1\n"
                    "$ui = [System.Environment]::UserInteractive\n"
                    "$in = $false; try { $in  = [Console]::IsInputRedirected } catch {}\n"
                    "$ok = ($ui -and -not $in)\n"
                    '"ok=$ok" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8\n'
                ),
            },
        ],
    }
    jobs['probe'] = job
    doc['jobs'] = jobs
    return True


def _ensure_job_needs(doc, job_name: str, need: str) -> bool:
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        return False
    needs = job.get('needs')
    changed = False
    if needs is None:
        job['needs'] = [need]
        changed = True
    elif isinstance(needs, list) and need not in needs:
        needs.append(need)
        job['needs'] = needs
        changed = True
    return changed


def _set_job_if(doc, job_name: str, new_if: str) -> bool:
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        return False
    want = SQS(new_if)
    if job.get('if') != want:
        job['if'] = want
        return True
    return False


def _find_step_index(steps: list, name: str) -> int | None:
    for idx, st in enumerate(steps):
        if isinstance(st, dict) and st.get('name') == name:
            return idx
    return None


def ensure_lint_resiliency(doc, job_name: str, include_node: bool = True, markdown_non_blocking: bool = False) -> bool:
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        return False
    steps = job.setdefault('steps', [])
    changed = False

    # Determine checkout index for insertion points
    checkout_idx = _find_step_index(steps, 'actions/checkout@v5')
    if checkout_idx is None:
        checkout_idx = next((i for i, st in enumerate(steps) if isinstance(st, dict) and str(st.get('uses', '')).startswith('actions/checkout@')), None)

    def insert_after_checkout(step_dict):
        nonlocal changed
        idx = checkout_idx + 1 if checkout_idx is not None else 0
        steps.insert(idx, step_dict)
        changed = True

    # Install actionlint step
    install_body = (
        "set -euo pipefail\n"
        "mkdir -p ./bin\n"
        "for i in 1 2 3; do \\\n"
        "  curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \\\n"
        "    | bash -s -- latest ./bin && break || { echo \"retry $i\"; sleep 2; }; \\\n"
        "done\n"
    )
    idx_install = _find_step_index(steps, 'Install actionlint (retry)')
    install_step = {
        'name': 'Install actionlint (retry)',
        'shell': 'bash',
        'run': LIT(install_body),
    }
    if idx_install is None:
        insert_after_checkout(install_step)
    else:
        cur = steps[idx_install]
        if cur.get('shell') != 'bash' or cur.get('run') != install_step['run']:
            steps[idx_install] = install_step
            changed = True

    # Run actionlint step
    idx_run = _find_step_index(steps, 'Run actionlint')
    run_step = {
        'name': 'Run actionlint',
        'run': LIT('./bin/actionlint -color\n'),
    }
    if idx_run is None:
        # place directly after install step if possible
        idx_install = _find_step_index(steps, 'Install actionlint (retry)')
        insert_at = idx_install + 1 if idx_install is not None else (checkout_idx + 1 if checkout_idx is not None else len(steps))
        steps.insert(insert_at, run_step)
        changed = True
    else:
        cur = steps[idx_run]
        if cur.get('run') != run_step['run']:
            steps[idx_run]['run'] = run_step['run']
            changed = True

    # Node setup step
    if include_node:
        node_step = {
            'name': 'Setup Node with cache',
            'uses': 'actions/setup-node@v4',
            'with': {
                'node-version': DQS('20'),
                'cache': DQS('npm'),
            },
        }
        idx_node = _find_step_index(steps, 'Setup Node with cache')
        if idx_node is None:
            insert_at = _find_step_index(steps, 'Install markdownlint-cli (retry)')
            if insert_at is None:
                insert_at = len(steps)
            steps.insert(insert_at, node_step)
            changed = True
        else:
            # Ensure with block is normalized
            cur_with = steps[idx_node].setdefault('with', {})
            if cur_with.get('node-version') != DQS('20') or cur_with.get('cache') != DQS('npm'):
                steps[idx_node]['with'] = node_step['with']
                changed = True

    # Install markdownlint step
    md_body = (
        "set -euo pipefail\n"
        "for i in 1 2 3; do npm install -g markdownlint-cli && break || { npm cache clean --force || true; echo \"retry $i\"; sleep 2; }; done\n"
    )
    md_install_step = {
        'name': 'Install markdownlint-cli (retry)',
        'shell': 'bash',
        'run': LIT(md_body),
    }
    idx_md_install = _find_step_index(steps, 'Install markdownlint-cli (retry)')
    if idx_md_install is None:
        steps.append(md_install_step)
        changed = True
    else:
        cur = steps[idx_md_install]
        if cur.get('shell') != 'bash' or cur.get('run') != md_install_step['run']:
            steps[idx_md_install] = md_install_step
            changed = True

    # Run markdownlint step
    idx_md_run = _find_step_index(steps, 'Run markdownlint (non-blocking)' if markdown_non_blocking else 'Run markdownlint')
    name_md = 'Run markdownlint (non-blocking)' if markdown_non_blocking else 'Run markdownlint'
    md_run_step = {
        'name': name_md,
        'run': LIT('markdownlint "**/*.md" --ignore node_modules\n'),
    }
    if markdown_non_blocking:
        md_run_step['continue-on-error'] = True
    idx_target = _find_step_index(steps, name_md)
    if idx_target is None:
        steps.append(md_run_step)
        changed = True
    else:
        cur = steps[idx_target]
        need_update = False
        if cur.get('run') != md_run_step['run']:
            need_update = True
        if markdown_non_blocking:
            if cur.get('continue-on-error') is not True:
                need_update = True
        else:
            if 'continue-on-error' in cur:
                del cur['continue-on-error']
                changed = True
        if need_update:
            steps[idx_target] = md_run_step
            changed = True

    job['steps'] = steps
    return changed


def ensure_hosted_preflight(doc, job_key: str) -> bool:
    changed = False
    # Ensure jobs map exists
    jobs = doc.get('jobs')
    if not isinstance(jobs, dict):
        doc['jobs'] = jobs = {}
        changed = True
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        # Create a minimal hosted preflight job
        job = {
            'runs-on': 'windows-latest',
            'timeout-minutes': 3,
            'steps': [
                {'uses': 'actions/checkout@v5'},
            ],
        }
        jobs[job_key] = job
        changed = True
    # Ensure runs-on windows-latest
    if job.get('runs-on') != 'windows-latest':
        job['runs-on'] = 'windows-latest'
        changed = True
    steps = job.setdefault('steps', [])
    # Ensure checkout exists
    has_checkout = any(isinstance(s, dict) and str(s.get('uses', '')).startswith('actions/checkout@') for s in steps)
    if not has_checkout:
        steps.insert(0, {'uses': 'actions/checkout@v5'})
        changed = True
    # Ensure verify step exists/updated
    idx_verify = None
    for i, st in enumerate(steps):
        if isinstance(st, dict) and 'Verify Windows runner' in str(st.get('name', '')):
            idx_verify = i
            break
    new_step = _mk_hosted_preflight_step()
    if idx_verify is None:
        # Insert after checkout if present
        insert_at = 1 if has_checkout else 0
        steps.insert(insert_at, new_step)
        changed = True
    else:
        # Update run body to canonical hosted content
        if steps[idx_verify].get('run') != new_step['run']:
            steps[idx_verify]['run'] = new_step['run']
            steps[idx_verify]['shell'] = 'pwsh'
            changed = True
    return changed


def ensure_session_index_post_in_pester_matrix(doc, job_key: str) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
    steps = job.get('steps') or []
    # Find if session-index-post exists
    exists = any(isinstance(s, dict) and str(s.get('uses', '')).endswith('session-index-post') for s in steps)
    if not exists:
        step = {
            'name': 'Session index post',
            'if': SQS('${{ always() }}'),
            'uses': './.github/actions/session-index-post',
            'with': {
                'results-dir': SQS('tests/results/${{ matrix.category }}'),
                'validate-schema': True,
                'upload': True,
                'artifact-name': SQS('session-index-${{ matrix.category }}'),
            },
        }
        steps.append(step)
        job['steps'] = steps
        changed = True
    return changed


def ensure_session_index_post_in_job(doc, job_key: str, results_dir: str, artifact_name: str) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
    steps = job.get('steps') or []
    exists = any(isinstance(s, dict) and str(s.get('uses', '')).endswith('session-index-post') for s in steps)
    if not exists:
        step = {
            'name': 'Session index post (best-effort)',
            'if': SQS('${{ always() }}'),
            'uses': './.github/actions/session-index-post',
            'with': {
                'results-dir': results_dir,
                'validate-schema': True,
                'upload': True,
                'artifact-name': artifact_name,
            },
        }
        steps.append(step)
        job['steps'] = steps
        changed = True
    return changed

def ensure_runner_unblock_guard(doc, job_key: str, snapshot_path: str) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
    steps = job.get('steps') or []
    # Check if guard exists
    exists = any(isinstance(s, dict) and str(s.get('uses', '')).endswith('runner-unblock-guard') for s in steps)
    if not exists:
        step = {
            'name': 'Runner Unblock Guard',
            'if': SQS('${{ always() }}'),
            'uses': './.github/actions/runner-unblock-guard',
            'with': {
                'snapshot-path': snapshot_path,
                'cleanup': DQS("${{ env.UNBLOCK_GUARD == '1' }}"),
                'process-names': 'conhost,pwsh,LabVIEW,LVCompare',
            },
        }
        steps.append(step)
        job['steps'] = steps
        changed = True
    return changed


def apply_transforms(path: Path) -> tuple[bool, str]:
    orig = path.read_text(encoding='utf-8')
    doc = load_yaml(path)
    changed = False
    name = doc.get('name', '')
    # Only transform self-hosted Pester workflow here
    if name in ('Pester (self-hosted)', 'Pester (integration)') or path.name == 'pester-selfhosted.yml':
        c1 = ensure_force_run_input(doc)
        c2 = ensure_preinit_force_run_outputs(doc)
        changed = c1 or c2
        # Hosted preflight note for self-hosted preflight lives in separate workflows; skip here.
    # fixture-drift.yml hosted preflight + session index post in validate-windows
    if path.name == 'fixture-drift.yml':
        c3 = ensure_hosted_preflight(doc, 'preflight-windows')
        c4 = ensure_session_index_post_in_job(doc, 'validate-windows', 'results/fixture-drift', 'fixture-drift-session-index')
        changed = changed or c3 or c4
    # ci-orchestrated.yml hosted preflight + pester matrix session index post + rerun hints + interactivity probe wiring
    if path.name == 'ci-orchestrated.yml':
        c5 = ensure_hosted_preflight(doc, 'preflight')
        # The matrix job may be named 'pester' or 'pester-category'; try both
        c6 = ensure_session_index_post_in_pester_matrix(doc, 'pester')
        c7 = ensure_session_index_post_in_pester_matrix(doc, 'pester-category')
        # Guard normalization
        g1 = ensure_runner_unblock_guard(doc, 'drift', 'results/fixture-drift/runner-unblock-snapshot.json')
        g2 = ensure_runner_unblock_guard(doc, 'pester', 'tests/results/${{ matrix.category }}/runner-unblock-snapshot.json')
        g3 = ensure_runner_unblock_guard(doc, 'pester-category', 'tests/results/${{ matrix.category }}/runner-unblock-snapshot.json')
        # Rerun hints across jobs
        r1 = ensure_rerun_hint_after_summary(doc, 'matrix')
        r2 = ensure_rerun_hint_in_job(doc, 'windows-single', 'single')
        r3 = ensure_rerun_hint_in_job(doc, 'publish', 'matrix')
        # Interactivity probe job + gating
        p1 = ensure_interactivity_probe_job(doc)
        # windows-single needs probe and requires ok==true
        w_if = "${{ (inputs.strategy == 'single' || vars.ORCH_STRATEGY == 'single') && needs.probe.outputs.ok == 'true' }}"
        w1 = _set_job_if(doc, 'windows-single', w_if)
        w2 = _ensure_job_needs(doc, 'windows-single', 'probe')
        # pester-category runs matrix or fallback when single is requested but probe is false
        pc_if = "${{ inputs.strategy == 'matrix' || vars.ORCH_STRATEGY == 'matrix' || (inputs.strategy == '' && vars.ORCH_STRATEGY == '') || (inputs.strategy == 'single' && needs.probe.outputs.ok == 'false') }}"
        pc1 = _set_job_if(doc, 'pester-category', pc_if)
        pc2 = _ensure_job_needs(doc, 'pester-category', 'probe')
        lr1 = ensure_lint_resiliency(doc, 'lint', include_node=True, markdown_non_blocking=True)
        changed = changed or c5 or c6 or c7 or g1 or g2 or g3 or r1 or r2 or r3 or p1 or w1 or w2 or pc1 or pc2 or lr1
    # Skip transforms for deprecated ci-orchestrated-v2.yml (kept as a stub/manual only)
    if path.name == 'ci-orchestrated-v2.yml':
        pass
    # pester-integration-on-label.yml: ensure session index post in integration job
    if path.name == 'pester-integration-on-label.yml':
        # Do not inject steps into a reusable workflow job (uses: ...)
        try:
            jobs = doc.get('jobs') or {}
            j = jobs.get('pester-integration')
            is_reusable = isinstance(j, dict) and 'uses' in j and isinstance(j.get('uses'), str)
        except Exception:
            is_reusable = False
        if not is_reusable:
            c10 = ensure_session_index_post_in_job(doc, 'pester-integration', 'tests/results', 'pester-integration-session-index')
            g5 = ensure_runner_unblock_guard(doc, 'pester-integration', 'tests/results/runner-unblock-snapshot.json')
            changed = changed or c10 or g5
    # smoke.yml: ensure session index post
    if path.name == 'smoke.yml':
        c11 = ensure_session_index_post_in_job(doc, 'compare', 'tests/results', 'smoke-session-index')
        g6 = ensure_runner_unblock_guard(doc, 'compare', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c11 or g6
    if path.name == 'compare-artifacts.yml':
        c12 = ensure_session_index_post_in_job(doc, 'publish', 'tests/results', 'compare-session-index')
        g7 = ensure_runner_unblock_guard(doc, 'publish', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c12 or g7
    # pester-reusable.yml: add a Runner Unblock Guard to preflight with CLEAN_LVCOMPARE cleanup gating
    if path.name == 'pester-reusable.yml':
        try:
            jobs = doc.get('jobs') or {}
            job = jobs.get('preflight')
            if isinstance(job, dict):
                steps = job.setdefault('steps', [])
                insert_at = 1 if steps and isinstance(steps[0], dict) and str(steps[0].get('uses','')).startswith('actions/checkout') else 0
                has_guard = any(isinstance(st, dict) and str(st.get('uses','')).endswith('runner-unblock-guard') for st in steps)
                if not has_guard:
                    guard = {
                        'name': 'Runner Unblock Guard (preflight)',
                        'uses': './.github/actions/runner-unblock-guard',
                        'with': {
                            'snapshot-path': 'tests/results/runner-unblock-snapshot.json',
                            'cleanup': DQS("${{ env.CLEAN_LVCOMPARE == '1' }}"),
                            'process-names': 'LabVIEW,LVCompare',
                        },
                    }
                    steps.insert(insert_at, guard)
                    job['steps'] = steps
                    changed = True
        except Exception:
            pass
    if path.name == 'validate.yml':
        lr2 = ensure_lint_resiliency(doc, 'lint', include_node=True, markdown_non_blocking=False)
        changed = changed or lr2


    if changed:
        new = dump_yaml(doc, path)
        return True, new
    return False, orig


def main(argv: List[str]) -> int:
    if not argv or argv[0] not in ('--check', '--write'):
        print('Usage: update_workflows.py (--check|--write) <files...>')
        return 2
    mode = argv[0]
    files = [Path(p) for p in argv[1:]]
    if not files:
        print('No files provided')
        return 2
    changed_any = False
    for f in files:
        try:
            was_changed, new_text = apply_transforms(f)
        except Exception as e:
            print(f'::warning::Skipping {f}: {e}')
            continue
        if was_changed:
            changed_any = True
            if mode == '--write':
                f.write_text(new_text, encoding='utf-8', newline='\n')
                print(f'updated: {f}')
            else:
                print(f'NEEDS UPDATE: {f}')
    if mode == '--check' and changed_any:
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
