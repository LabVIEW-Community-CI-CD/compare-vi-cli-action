#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parents[1]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from _enclave import REQUIREMENTS_PATH, load_default_scope
from _update_workflows_impl import dump_yaml, load_yaml


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
            Path.cwd() / '.github' / 'workflows' / 'validate.yml',
            Path.cwd() / '.github' / 'workflows' / 'ci-orchestrated.yml',
            Path.cwd() / '.github' / 'workflows' / 'fixture-drift.yml',
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


if __name__ == '__main__':
    unittest.main()
