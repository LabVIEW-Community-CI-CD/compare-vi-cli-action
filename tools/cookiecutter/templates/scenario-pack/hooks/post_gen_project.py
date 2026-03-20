from __future__ import annotations

import json
from pathlib import Path


project_dir = Path.cwd()
replay_path = project_dir / "cookiecutter-replay.json"
context = {
    "pack_slug": "{{ cookiecutter.pack_slug }}",
    "pack_id": "{{ cookiecutter.pack_id }}",
    "pack_description": "{{ cookiecutter.pack_description }}",
    "image": "{{ cookiecutter.image }}",
    "plane_applicability_csv": "{{ cookiecutter.plane_applicability_csv }}",
    "results_root": "{{ cookiecutter.results_root }}",
    "report_path": "{{ cookiecutter.report_path }}",
    "incident_input_path": "{{ cookiecutter.incident_input_path }}",
    "incident_event_path": "{{ cookiecutter.incident_event_path }}",
    "base_vi": "{{ cookiecutter.base_vi }}",
    "head_vi": "{{ cookiecutter.head_vi }}",
}
replay_path.write_text(json.dumps(context, indent=2) + "\n", encoding="utf-8")
