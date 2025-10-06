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

