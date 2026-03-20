from __future__ import annotations

import json
from pathlib import Path


project_dir = Path.cwd()
replay_path = project_dir / "cookiecutter-replay.json"
context = {
    "target_slug": "{{ cookiecutter.target_slug }}",
    "target_label": "{{ cookiecutter.target_label }}",
    "repo_slug": "{{ cookiecutter.repo_slug }}",
    "repo_url": "{{ cookiecutter.repo_url }}",
    "license_spdx": "{{ cookiecutter.license_spdx }}",
    "target_path": "{{ cookiecutter.target_path }}",
    "change_kind": "{{ cookiecutter.change_kind }}",
    "pinned_commit": "{{ cookiecutter.pinned_commit }}",
    "plane_applicability_csv": "{{ cookiecutter.plane_applicability_csv }}",
    "public_pr_url": "{{ cookiecutter.public_pr_url }}",
    "public_workflow_run_url": "{{ cookiecutter.public_workflow_run_url }}",
}
replay_path.write_text(json.dumps(context, indent=2) + "\n", encoding="utf-8")
