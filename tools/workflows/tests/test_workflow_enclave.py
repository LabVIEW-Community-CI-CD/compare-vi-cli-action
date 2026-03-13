#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPT_ROOT.parents[1]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from _enclave import REQUIREMENTS_PATH, load_default_scope
from _update_workflows_impl import dump_yaml, ensure_interactivity_probe_job, ensure_lint_resiliency, load_yaml


class WorkflowUpdaterRoundTripTests(unittest.TestCase):
    def test_round_trip_preserves_comments_and_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            sample_path = Path(temp_dir) / 'sample.yml'
            sample_path.write_text(
                "# header comment\n"
                "name: 'Quoted Name'\n"
                "on:\n"
                "  workflow_dispatch:\n"
                "    inputs:\n"
                "      force_run:\n"
                "        description: \"Force run\"\n"
                "        default: 'false'\n",
                encoding='utf-8',
                newline='\n'
            )

            doc = load_yaml(sample_path)
            rendered = dump_yaml(doc, sample_path)

            self.assertIn('# header comment', rendered)
            self.assertIn("name: 'Quoted Name'", rendered)
            self.assertIn('description: "Force run"', rendered)
            self.assertIn("default: 'false'", rendered)

    def test_enclave_wrapper_check_is_noop_for_normalized_workflows(self) -> None:
        source_paths = [
            REPO_ROOT / '.github' / 'workflows' / 'validate.yml',
            REPO_ROOT / '.github' / 'workflows' / 'ci-orchestrated.yml',
            REPO_ROOT / '.github' / 'workflows' / 'fixture-drift.yml',
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_paths = []
            originals = {}
            for source_path in source_paths:
                temp_path = Path(temp_dir) / source_path.name
                original = source_path.read_text(encoding='utf-8')
                temp_path.write_text(original, encoding='utf-8', newline='\n')
                temp_paths.append(temp_path)
                originals[temp_path.name] = original

            completed = subprocess.run(
                [sys.executable, str(SCRIPT_ROOT / 'workflow_enclave.py'), '--check', *[str(temp_path) for temp_path in temp_paths]],
                capture_output=True,
                text=True,
                check=False
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            for temp_path in temp_paths:
                self.assertEqual(temp_path.read_text(encoding='utf-8'), originals[temp_path.name])

    def test_requirements_are_pinned(self) -> None:
        lines = [line.strip() for line in REQUIREMENTS_PATH.read_text(encoding='utf-8').splitlines() if line.strip()]
        self.assertIn('ruamel.yaml==0.18.10', lines)
        self.assertIn('ruamel.yaml.clib==0.2.12', lines)

    def test_default_scope_manifest_includes_validate(self) -> None:
        scope = load_default_scope()
        self.assertIn('.github/workflows/validate.yml', scope)
        self.assertIn('.github/workflows/ci-orchestrated.yml', scope)

    def test_interactivity_probe_emits_lowercase_output(self) -> None:
        doc = {
            'jobs': {
                'normalize': {},
                'preflight': {},
            }
        }

        changed = ensure_interactivity_probe_job(doc)

        self.assertTrue(changed)
        probe_job = doc['jobs']['probe']
        run_script = probe_job['steps'][1]['run']
        self.assertIn('$okString = if ($ok) { "true" } else { "false" }', run_script)
        self.assertIn('"ok=$okString" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8', run_script)

    def test_lint_resiliency_preserves_scoped_markdown_step_name(self) -> None:
        doc = {
            'jobs': {
                'lint': {
                    'steps': [
                        {'uses': 'actions/checkout@v5'},
                        {
                            'name': 'Run markdownlint (scoped changed files)',
                            'run': 'node tools/npm/run-script.mjs lint:md:changed\n',
                        },
                    ]
                }
            }
        }

        changed = ensure_lint_resiliency(doc, 'lint', include_node=True)

        self.assertTrue(changed)
        lint_steps = doc['jobs']['lint']['steps']
        matching = [step for step in lint_steps if step.get('name') == 'Run markdownlint (scoped changed files)']
        self.assertEqual(len(matching), 1)
        self.assertFalse(any(step.get('name') == 'Run markdownlint' for step in lint_steps if isinstance(step, dict)))

    def test_enclave_home_env_override_is_honored(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            override_dir = Path(temp_dir) / 'custom-venv'
            completed = subprocess.run(
                [
                    sys.executable,
                    '-c',
                    'import os; '
                    'os.environ["COMPAREVI_WORKFLOW_ENCLAVE_HOME"]=r"%s"; '
                    'import _enclave; '
                    'print(_enclave.VENV_DIR)'
                    % str(override_dir).replace('\\', '\\\\')
                ],
                capture_output=True,
                text=True,
                cwd=str(SCRIPT_ROOT),
                check=False
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(Path(completed.stdout.strip()), override_dir)


if __name__ == '__main__':
    unittest.main()
