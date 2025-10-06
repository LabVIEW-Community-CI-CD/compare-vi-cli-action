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
from ruamel.yaml.scalarstring import SingleQuotedScalarString as SQS, LiteralScalarString as LIT


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


def ensure_hosted_preflight(doc, job_key: str) -> bool:
    changed = False
    jobs = doc.get('jobs') or {}
    job = jobs.get(job_key)
    if not isinstance(job, dict):
        return changed
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
                'cleanup': SQS('${{ env.UNBLOCK_GUARD == '"' + '1' + '"' + ' }}'),
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
    # ci-orchestrated.yml hosted preflight + pester matrix session index post
    if path.name == 'ci-orchestrated.yml':
        c5 = ensure_hosted_preflight(doc, 'preflight')
        # The matrix job may be named 'pester' or 'pester-category'; try both
        c6 = ensure_session_index_post_in_pester_matrix(doc, 'pester')
        c7 = ensure_session_index_post_in_pester_matrix(doc, 'pester-category')
        # Guard normalization
        g1 = ensure_runner_unblock_guard(doc, 'drift', 'results/fixture-drift/runner-unblock-snapshot.json')
        g2 = ensure_runner_unblock_guard(doc, 'pester', 'tests/results/${{ matrix.category }}/runner-unblock-snapshot.json')
        g3 = ensure_runner_unblock_guard(doc, 'pester-category', 'tests/results/${{ matrix.category }}/runner-unblock-snapshot.json')
        changed = changed or c5 or c6 or c7 or g1 or g2 or g3
    # ci-orchestrated-v2.yml: hosted preflight + pester matrix (or single job) session index post
    if path.name == 'ci-orchestrated-v2.yml':
        c8 = ensure_hosted_preflight(doc, 'preflight')
        c9 = ensure_session_index_post_in_pester_matrix(doc, 'pester-category') or ensure_session_index_post_in_pester_matrix(doc, 'pester')
        g4 = ensure_runner_unblock_guard(doc, 'orchestrated', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c8 or c9 or g4
    # pester-integration-on-label.yml: ensure session index post in integration job
    if path.name == 'pester-integration-on-label.yml':
        c10 = ensure_session_index_post_in_job(doc, 'pester-integration', 'tests/results', 'pester-integration-session-index')
        g5 = ensure_runner_unblock_guard(doc, 'pester-integration', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c10 or g5
    # smoke.yml: ensure session index post
    if path.name == 'smoke.yml':
        c11 = ensure_session_index_post_in_job(doc, 'compare', 'tests/results', 'smoke-session-index')
        g6 = ensure_runner_unblock_guard(doc, 'compare', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c11 or g6
    # compare-artifacts.yml: ensure session index post in publish job
    if path.name == 'compare-artifacts.yml':
        c12 = ensure_session_index_post_in_job(doc, 'publish', 'tests/results', 'compare-session-index')
        g7 = ensure_runner_unblock_guard(doc, 'publish', 'tests/results/runner-unblock-snapshot.json')
        changed = changed or c12 or g7
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
