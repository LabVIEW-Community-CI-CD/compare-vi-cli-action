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
        "if ($lv) { $pids = ($lv | ForEach-Object Id); $msg = \"::error::LabVIEW.exe is running (PID(s): {0})\" -f ([string]::Join(\",\", $pids)); Write-Host $msg; exit 1 }",
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


def _mk_hosted_notice_step() -> dict:
    # Normalize the hosted Windows notice-only step to avoid -join folding
    lines = [
        "$cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'",
        'if (-not (Test-Path -LiteralPath $cli)) {',
        '  Write-Host "::notice::LVCompare.exe not found at canonical path: $cli (hosted preflight)"',
        '} else {',
        '  Write-Host "LVCompare present: $cli"',
        '}',
        "$lv = Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue",
        "if ($lv) { $pids = ($lv | ForEach-Object Id); $msg = '::notice::LabVIEW.exe is running (PID(s): {0}).' -f ([string]::Join(',', $pids)); Write-Host $msg } else { Write-Host 'LabVIEW not running.' }",
        "Write-Host 'Preflight check complete.'",
    ]
    body = "\n".join(lines)
    return {
        'name': 'Verify LVCompare and idle LabVIEW state (notice-only on hosted)',
        'shell': 'pwsh',
        'run': LIT(body),
    }


def ensure_hosted_notice(doc, job_key: str) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
    steps = job.setdefault('steps', [])
    idx_notice = None
    for i, st in enumerate(steps):
        if isinstance(st, dict) and 'Verify LVCompare and idle LabVIEW state' in str(st.get('name', '')):
            idx_notice = i
            break
    new_step = _mk_hosted_notice_step()
    if idx_notice is None:
        steps.append(new_step)
        job['steps'] = steps
        return True
    # Update run body to canonical hosted content
    if steps[idx_notice].get('run') != new_step['run']:
        steps[idx_notice]['run'] = new_step['run']
        steps[idx_notice]['shell'] = 'pwsh'
        changed = True
    return changed


def normalize_hosted_preflight_steps(doc) -> bool:
    """Normalize any hosted Windows preflight/notice steps across all jobs by name.
    Safe no-op if steps are absent or names differ.
    """
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return False
    preflight_tmpl = _mk_hosted_preflight_step()
    notice_tmpl = _mk_hosted_notice_step()
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        for i, st in enumerate(steps):
            if not isinstance(st, dict):
                continue
            nm = str(st.get('name', ''))
            if nm == preflight_tmpl['name']:
                if st.get('run') != preflight_tmpl['run'] or st.get('shell') != 'pwsh':
                    st['run'] = preflight_tmpl['run']
                    st['shell'] = 'pwsh'
                    changed = True
            elif nm == notice_tmpl['name']:
                if st.get('run') != notice_tmpl['run'] or st.get('shell') != 'pwsh':
                    st['run'] = notice_tmpl['run']
                    st['shell'] = 'pwsh'
                    changed = True
    return changed


def _insert_wire_j1_j2_in_job(job: dict, results_dir: str = 'tests/results') -> bool:
    changed = False
    if not isinstance(job, dict):
        return changed
    steps = job.setdefault('steps', [])
    # Remove existing J1/J2 so we can reinsert after checkout
    kept = []
    removed = False
    for st in steps:
        if isinstance(st, dict) and st.get('name') in ('Wire Probe (J1)', 'Wire Probe (J2)'):
            removed = True
            changed = True
            continue
        kept.append(st)
    steps = kept
    job['steps'] = steps
    checkout_idx = next((i for i, s in enumerate(steps) if isinstance(s, dict) and str(s.get('uses', '')).startswith('actions/checkout@')), None)
    if checkout_idx is None:
        return changed
    insert_after = checkout_idx + 1
    steps.insert(insert_after, {
        'name': 'Wire Probe (J1)',
        'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
        'uses': './.github/actions/wire-probe',
        'with': {
            'phase': 'J1',
            'results-dir': results_dir,
        },
    })
    insert_after += 1
    steps.insert(insert_after, {
        'name': 'Wire Probe (J2)',
        'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
        'uses': './.github/actions/wire-probe',
        'with': {
            'phase': 'J2',
            'results-dir': results_dir,
        },
    })
    job['steps'] = steps
    return True


def ensure_wire_probes_all_jobs(doc, default_results_dir: str = 'tests/results') -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        # Choose results-dir per job when known
        rd = default_results_dir
        if jn == 'pester-category':
            rd = 'tests/results/${{ matrix.category }}'
        elif jn == 'drift':
            rd = 'results/fixture-drift'
        elif jn == 'publish':
            rd = 'tests/results'
        elif jn == 'lint':
            rd = 'tests/results'
        elif jn == 'normalize':
            rd = 'tests/results'
        if _insert_wire_j1_j2_in_job(job, rd):
            jobs[jn] = job
            changed = True
    if changed:
        doc['jobs'] = jobs
    return changed


def ensure_wire_T1_for_tests(doc) -> bool:
    """Insert Wire Probe (T1) before major test execution steps in orchestrated workflows."""
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        def has_t1():
            return any(isinstance(s, dict) and s.get('name') == 'Wire Probe (T1)' for s in steps)
        # anchors to check
        anchors = ['Run Pester tests via local dispatcher (category)', 'Pester categories (serial, deterministic)']
        insert_idx = None
        for i, st in enumerate(steps):
            if not isinstance(st, dict):
                continue
            nm = st.get('name', '')
            if nm in anchors:
                insert_idx = i
                break
        if insert_idx is not None and not has_t1():
            # results-dir selection
            rd = 'tests/results'
            if jn == 'pester-category':
                rd = 'tests/results/${{ matrix.category }}'
            steps.insert(insert_idx, {
                'name': 'Wire Probe (T1)',
                'uses': './.github/actions/wire-probe',
                'with': { 'phase': 'T1', 'results-dir': rd },
            })
            job['steps'] = steps
            jobs[jn] = job
            changed = True
    if changed:
        doc['jobs'] = jobs
    return changed


def _mk_wire_step(name: str, phase: str, results_dir: str) -> dict:
    return {
        'name': name,
        'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
        'uses': './.github/actions/wire-probe',
        'with': { 'phase': phase, 'results-dir': results_dir },
    }


def _insert_before(steps: list, anchor_name: str, step: dict) -> bool:
    for i, st in enumerate(steps):
        if isinstance(st, dict) and st.get('name') == anchor_name:
            steps.insert(i, step)
            return True
    return False


def _insert_after(steps: list, anchor_name: str, step: dict) -> bool:
    for i, st in enumerate(steps):
        if isinstance(st, dict) and st.get('name') == anchor_name:
            steps.insert(i + 1, step)
            return True
    return False


def ensure_wire_S1_before_session_index(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        # target anchors
        target_names = [
            'Session index post',
            'Session index post (best-effort)',
            'Session index post (single)'
        ]
        # decide results-dir
        rd = 'tests/results'
        if jn == 'pester-category':
            rd = 'tests/results/${{ matrix.category }}'
        elif jn == 'drift':
            rd = 'results/fixture-drift'
        exists = any(isinstance(s, dict) and str(s.get('uses','')) == './.github/actions/wire-session-index' for s in steps)
        if exists:
            continue
        s1 = {
            'name': 'Wire Session Index (S1)',
            'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
            'uses': './.github/actions/wire-session-index',
            'with': { 'results-dir': rd },
        }
        inserted = False
        for tn in target_names:
            if _insert_before(steps, tn, s1):
                inserted = True
                break
        if inserted:
            job['steps'] = steps
            jobs[jn] = job
            changed = True
    if changed:
        doc['jobs'] = jobs
    return changed


def ensure_wire_C1C2_around_drift(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    drift = jobs.get('drift')
    if not isinstance(drift, dict):
        return changed
    steps = drift.get('steps') or []
    idx = None
    for i, st in enumerate(steps):
        if isinstance(st, dict) and str(st.get('uses','')).endswith('/fixture-drift'):
            idx = i
            break
    if idx is None:
        return changed
    has_c1 = any(isinstance(s, dict) and s.get('name') == 'Wire Probe (C1)' for s in steps)
    has_c2 = any(isinstance(s, dict) and s.get('name') == 'Wire Probe (C2)' for s in steps)
    if not has_c1:
        steps.insert(idx, _mk_wire_step('Wire Probe (C1)', 'C1', 'results/fixture-drift'))
        changed = True
        idx += 1
    if not has_c2:
        steps.insert(idx + 1, _mk_wire_step('Wire Probe (C2)', 'C2', 'results/fixture-drift'))
        changed = True
    drift['steps'] = steps
    jobs['drift'] = drift
    doc['jobs'] = jobs
    return changed


def ensure_wire_I1I2_invoker(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        if not any(isinstance(s, dict) and s.get('name') == 'Wire Invoker (start)' for s in steps):
            if _insert_before(steps, 'Ensure Invoker (start)', {
                'name': 'Wire Invoker (start)',
                'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
                'uses': './.github/actions/wire-invoker-start',
                'with': { 'results-dir': 'tests/results' },
            }):
                changed = True
        if not any(isinstance(s, dict) and s.get('name') == 'Wire Invoker (stop)' for s in steps):
            if _insert_after(steps, 'Ensure Invoker (stop)', {
                'name': 'Wire Invoker (stop)',
                'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
                'uses': './.github/actions/wire-invoker-stop',
                'with': { 'results-dir': 'tests/results' },
            }):
                changed = True
        job['steps'] = steps
        jobs[jn] = job
    if changed:
        doc['jobs'] = jobs
    return changed


def ensure_wire_G0G1_guard(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        if _find_step_index(steps, 'Runner Unblock Guard') is None:
            continue
        if not any(isinstance(s, dict) and s.get('name') == 'Wire Guard (pre)' for s in steps):
            _insert_before(steps, 'Runner Unblock Guard', {
                'name': 'Wire Guard (pre)',
                'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
                'uses': './.github/actions/wire-guard-pre',
                'with': { 'results-dir': 'tests/results' },
            })
            changed = True
        if not any(isinstance(s, dict) and s.get('name') == 'Wire Guard (post)' for s in steps):
            _insert_after(steps, 'Runner Unblock Guard', {
                'name': 'Wire Guard (post)',
                'if': SQS("${{ vars.WIRE_PROBES != '0' }}"),
                'uses': './.github/actions/wire-guard-post',
                'with': { 'results-dir': 'tests/results' },
            })
            changed = True
        job['steps'] = steps
        jobs[jn] = job
    if changed:
        doc['jobs'] = jobs
    return changed


def ensure_wire_P1_after_final(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    if not isinstance(jobs, dict):
        return changed
    anchors = ['Append final summary (single)', 'Summarize orchestrated run']
    for jn, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get('steps') or []
        if any(isinstance(s, dict) and s.get('name') == 'Wire Probe (P1)' for s in steps):
            continue
        inserted = False
        for a in anchors:
            if _insert_after(steps, a, _mk_wire_step('Wire Probe (P1)', 'P1', 'tests/results')):
                inserted = True
                break
        if inserted:
            job['steps'] = steps
            jobs[jn] = job
            changed = True
    if changed:
        doc['jobs'] = jobs
    return changed

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
    # Ensure job-level env has ACTIONLINT_VERSION wired to repo vars with default
    changed = False
    job_env = job.setdefault('env', {})
    desired = SQS("${{ vars.ACTIONLINT_VERSION || '1.7.7' }}")
    if job_env.get('ACTIONLINT_VERSION') != desired:
        job_env['ACTIONLINT_VERSION'] = desired
        job['env'] = job_env
        changed = True

    steps = job.setdefault('steps', [])

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
        "ver=\"${ACTIONLINT_VERSION:-1.7.7}\"\n"
        "for i in 1 2 3; do\n"
        "  if curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash -s -- \"$ver\" ./bin; then\n"
        "    break\n"
        "  else\n"
        "    echo \"retry $i\"; sleep 2\n"
        "  fi\n"
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
        "for i in 1 2 3; do\n"
        "  if node tools/npm/cli.mjs install -g markdownlint-cli; then\n"
        "    break\n"
        "  else\n"
        "    node tools/npm/cli.mjs cache clean --force || true\n"
        "    echo \"retry $i\"\n"
        "    sleep 2\n"
        "  fi\n"
        "done\n"
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


def ensure_orchestrated_drift_gate_defaults(doc) -> bool:
    """Ensure the orchestrated lint job gates drift checks on the repository default branch."""
    jobs = doc.get('jobs') or {}
    lint = jobs.get('lint')
    if not isinstance(lint, dict):
        return False
    steps: List[dict] = lint.get('steps') or []
    target = None
    for st in steps:
        if isinstance(st, dict) and st.get('name') == 'Non-LabVIEW checks (Docker)':
            target = st
            break
    if target is None:
        return False
    default_branch_expr = (
        "${{ github.event.repository.default_branch || github.event.pull_request.base.repo.default_branch || "
        "github.event.workflow_run.repository.default_branch || '' }}"
    )
    expected_env = {
        'DEFAULT_BRANCH': default_branch_expr,
    }
    expected_body = (
        "$params = @()\n"
        "$defaultBranch = $env:DEFAULT_BRANCH\n"
        "if ('${{ github.ref_name }}' -eq $defaultBranch -or '${{ github.base_ref }}' -eq $defaultBranch) {\n"
        "  $params += '-FailOnWorkflowDrift'\n"
        "}\n"
        "$params += '-SkipDotnetCliBuild'\n"
        "# Skip linting this workflow while it is executing to avoid orchestration deadlocks.\n"
        "$params += '-ExcludeWorkflowPaths'\n"
        "$params += '.github/workflows/ci-orchestrated.yml'\n"
        "pwsh -File ./tools/Run-NonLVChecksInDocker.ps1 @params\n"
    )
    changed = False
    if target.get('shell') != 'pwsh':
        target['shell'] = 'pwsh'
        changed = True
    cur_env = target.get('env') or {}
    if dict(cur_env) != expected_env:
        target['env'] = expected_env
        changed = True
    current_run = target.get('run')
    if not isinstance(current_run, LIT) or str(current_run) != expected_body:
        target['run'] = LIT(expected_body)
        changed = True
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


def _ensure_job_concurrency(doc, job_key: str, group: str, cancel_in_progress: bool) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
    want = {
        'group': group,
        'cancel-in-progress': cancel_in_progress,
    }
    cur = job.get('concurrency')
    if cur != want:
        job['concurrency'] = want
        changed = True
    return changed


def _mk_wire_probe_step(phase: str, results_dir: str = 'results/fixture-drift') -> dict:
    return {
        'name': f'Wire Probe ({phase})',
        'uses': './.github/actions/wire-probe',
        'with': {
            'phase': phase,
            'results-dir': results_dir,
        },
    }


def _mk_lv_guard_pre_step() -> dict:
    return {
        'name': 'LV Guard (pre)',
        'uses': './.github/actions/runner-unblock-guard',
        'with': {
            'snapshot-path': 'results/fixture-drift/lv-guard-pre.json',
            'cleanup': DQS("${{ env.CLEAN_LV_BEFORE == 'true' }}"),
            'process-names': 'LVCompare,LabVIEW',
        },
    }


def _mk_wire_guard_pre_step() -> dict:
    return {
        'name': 'Wire Guard (pre)',
        'uses': './.github/actions/wire-guard-pre',
        'with': {
            'results-dir': 'results/fixture-drift',
        },
    }


def _mk_wire_guard_post_step() -> dict:
    return {
        'name': 'Wire Guard (post)',
        'uses': './.github/actions/wire-guard-post',
        'with': {
            'results-dir': 'results/fixture-drift',
        },
    }


def _mk_warmup_step() -> dict:
    return {
        'name': 'LabVIEW warmup (best-effort)',
        'shell': 'pwsh',
        'run': LIT('pwsh -File tools/Warmup-LabVIEWRuntime.ps1\n'),
    }


def _mk_wire_invoker_start_step() -> dict:
    return {
        'name': 'Wire Invoker (start)',
        'uses': './.github/actions/wire-invoker-start',
        'with': {
            'results-dir': 'results/fixture-drift',
        },
    }


def _mk_wire_invoker_stop_step() -> dict:
    return {
        'name': 'Wire Invoker (stop)',
        'uses': './.github/actions/wire-invoker-stop',
        'with': {
            'results-dir': 'results/fixture-drift',
        },
    }


def _mk_wire_session_index_step() -> dict:
    return {
        'name': 'Wire Session Index (S1)',
        'if': SQS('${{ always() }}'),
        'uses': './.github/actions/wire-session-index',
        'with': {
            'results-dir': 'results/fixture-drift',
        },
    }


def _step_exists(steps: list, predicate) -> bool:
    for st in steps:
        try:
            if predicate(st):
                return True
        except Exception:
            continue
    return False


def _insert_step_relative(steps: list, anchor_name: str, new_step: dict, where: str = 'after') -> bool:
    """Insert new_step relative to the first step with name==anchor_name.
    where: 'before' or 'after'
    """
    for idx, st in enumerate(steps):
        if isinstance(st, dict) and st.get('name') == anchor_name:
            insert_at = idx if where == 'before' else idx + 1
            steps.insert(insert_at, new_step)
            return True
    return False


def ensure_long_wire_fixture_drift_windows(doc) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get('validate-windows')
    if not isinstance(job, dict):
        return changed
    # job-level serialization
    c0 = _ensure_job_concurrency(doc, 'validate-windows', 'lv-fixture-win', False)
    changed = changed or c0
    steps = job.setdefault('steps', [])

    # Ensure J1 before checkout and J2 after checkout
    checkout_idx = next((i for i, s in enumerate(steps) if isinstance(s, dict) and str(s.get('uses','')).startswith('actions/checkout@')), None)
    if checkout_idx is not None:
        # J1
        if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (J1)'):
            steps.insert(checkout_idx, _mk_wire_probe_step('J1'))
            changed = True
            checkout_idx += 1  # shift due to insertion
        # J2
        if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (J2)'):
            steps.insert(checkout_idx + 1, _mk_wire_probe_step('J2'))
            changed = True

    # After docs-only detection: LV Guard (pre), Wire Guard (pre), Warmup, Wire Invoker (start)
    anchor = 'Detect docs-only change'
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'LV Guard (pre)'):
        if _insert_step_relative(steps, anchor, _mk_lv_guard_pre_step(), 'after'):
            changed = True
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Guard (pre)'):
        if _insert_step_relative(steps, anchor, _mk_wire_guard_pre_step(), 'after'):
            changed = True
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'LabVIEW warmup (best-effort)'):
        if _insert_step_relative(steps, anchor, _mk_warmup_step(), 'after'):
            changed = True
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Invoker (start)'):
        if _insert_step_relative(steps, anchor, _mk_wire_invoker_start_step(), 'after'):
            changed = True

    # C1 before orchestrator, C2 after orchestrator
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (C1)'):
        if _insert_step_relative(steps, 'Fixture Drift Orchestrator', _mk_wire_probe_step('C1'), 'before'):
            changed = True
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (C2)'):
        if _insert_step_relative(steps, 'Fixture Drift Orchestrator', _mk_wire_probe_step('C2'), 'after'):
            changed = True

    # After Verify fixture step: C3 and V1
    ver_name = 'Verify fixture vs LVCompare (notice-only)'
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (C3)'):
        if _insert_step_relative(steps, ver_name, _mk_wire_probe_step('C3'), 'after'):
            changed = True
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (V1)'):
        if _insert_step_relative(steps, ver_name, _mk_wire_probe_step('V1'), 'after'):
            changed = True

    # Ensure wire session index S1 before session-index-post
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('uses','') == './.github/actions/wire-session-index'):
        # Insert before Session index post (best-effort)
        if _insert_step_relative(steps, 'Session index post (best-effort)', _mk_wire_session_index_step(), 'before'):
            changed = True

    # After Runner Unblock Guard, add Wire Invoker (stop)
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Invoker (stop)'):
        if _insert_step_relative(steps, 'Runner Unblock Guard', _mk_wire_invoker_stop_step(), 'after'):
            changed = True

    # After Ensure Invoker (stop), add P1
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('name') == 'Wire Probe (P1)'):
        if _insert_step_relative(steps, 'Ensure Invoker (stop)', _mk_wire_probe_step('P1'), 'after'):
            changed = True

    # After LV Guard (post), add wire-guard-post
    if not _step_exists(steps, lambda s: isinstance(s, dict) and s.get('uses','') == './.github/actions/wire-guard-post'):
        if _insert_step_relative(steps, 'LV Guard (post)', _mk_wire_guard_post_step(), 'after'):
            changed = True

    job['steps'] = steps
    jobs['validate-windows'] = job
    doc['jobs'] = jobs
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
        c4 = ensure_hosted_notice(doc, 'preflight-windows')
        c5 = ensure_session_index_post_in_job(doc, 'validate-windows', 'results/fixture-drift', 'fixture-drift-session-index')
        lw = ensure_long_wire_fixture_drift_windows(doc)
        changed = changed or c3 or c4 or c5 or lw
    # Normalize hosted preflight steps across any workflow
    c_global = normalize_hosted_preflight_steps(doc)
    changed = changed or c_global
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
        dg = ensure_orchestrated_drift_gate_defaults(doc)
        wp = ensure_wire_probes_all_jobs(doc, 'tests/results')
        s1 = ensure_wire_S1_before_session_index(doc)
        t1 = ensure_wire_T1_for_tests(doc)
        cdrift = ensure_wire_C1C2_around_drift(doc)
        i12 = ensure_wire_I1I2_invoker(doc)
        gg = ensure_wire_G0G1_guard(doc)
        p1f = ensure_wire_P1_after_final(doc)
        changed = changed or c5 or c6 or c7 or g1 or g2 or g3 or r1 or r2 or r3 or p1 or w1 or w2 or pc1 or pc2 or lr1 or dg or wp or s1 or t1 or cdrift or i12 or gg or p1f
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
    # pester-reusable.yml: add a Runner Unblock Guard to preflight with cleanup gating
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
                            'cleanup': DQS("${{ env.CLEAN_LV_BEFORE == 'true' }}"),
                            'process-names': 'LabVIEW,LVCompare',
                        },
                    }
                    steps.insert(insert_at, guard)
                    job['steps'] = steps
                    changed = True
        except Exception:
            pass
    if path.name == 'validate.yml':
        # Make markdownlint non-blocking in Validate to avoid PR noise; the upstream policy guard enforces branch protection.
        lr2 = ensure_lint_resiliency(doc, 'lint', include_node=True, markdown_non_blocking=True)
        wp2 = ensure_wire_probes_all_jobs(doc, 'tests/results')
        s12 = ensure_wire_S1_before_session_index(doc)
        changed = changed or lr2 or wp2 or s12


    if changed:
        new = dump_yaml(doc, path)
        if new == orig:
            return False, orig
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
