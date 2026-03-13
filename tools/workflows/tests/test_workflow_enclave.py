#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import os
from pathlib import Path
from unittest.mock import patch

SCRIPT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPT_ROOT.parents[1]
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

import _enclave
from _enclave import REQUIREMENTS_PATH, load_default_scope
from _update_workflows_impl import (
    dump_yaml,
    ensure_force_run_input,
    ensure_interactivity_probe_job,
    ensure_lint_resiliency,
    ensure_preinit_force_run_outputs,
    load_yaml,
    main as updater_main,
)


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
            rendered = dump_yaml(doc)

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
            enclave_home = Path(temp_dir) / 'workflow-enclave-home'
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
                env={**os.environ, 'COMPAREVI_WORKFLOW_ENCLAVE_HOME': str(enclave_home)},
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

    def test_default_scope_rejects_non_workflow_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / 'workflow-manifest.json'
            manifest_path.write_text(
                '{"managedWorkflowFiles":[".github/workflows/validate.yml", null]}',
                encoding='utf-8'
            )

            with patch.object(_enclave, 'MANIFEST_PATH', manifest_path):
                with self.assertRaisesRegex(RuntimeError, 'invalid managed workflow entry'):
                    load_default_scope()

    def test_default_scope_rejects_non_repo_relative_workflow_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / 'workflow-manifest.json'
            manifest_path.write_text(
                '{"managedWorkflowFiles":["../../outside.yml"]}',
                encoding='utf-8'
            )

            with patch.object(_enclave, 'MANIFEST_PATH', manifest_path):
                with self.assertRaisesRegex(RuntimeError, 'repo-relative workflow path'):
                    load_default_scope()

    def test_wrapper_usage_mentions_default_scope_without_explicit_files(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT_ROOT / 'workflow_enclave.py')],
            capture_output=True,
            text=True,
            env={**os.environ, 'COMPAREVI_WORKFLOW_ENCLAVE_HOME': str(Path(tempfile.gettempdir()) / 'comparevi-workflow-enclave-usage')},
            check=False
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn('workflow_enclave.py --ensure-only', completed.stdout)
        self.assertIn('workflow_enclave.py --default-scope (--check|--write)', completed.stdout)
        self.assertIn('workflow_enclave.py (--check|--write) <files...>', completed.stdout)

    def test_force_run_input_supports_booleanized_on_key(self) -> None:
        doc = {
            True: {
                'workflow_dispatch': {
                    'inputs': {},
                },
            },
        }

        changed = ensure_force_run_input(doc)

        self.assertTrue(changed)
        self.assertIn('force_run', doc[True]['workflow_dispatch']['inputs'])

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

    def test_existing_interactivity_probe_is_normalized_to_lowercase_output(self) -> None:
        doc = {
            'jobs': {
                'normalize': {},
                'preflight': {},
                'probe': {
                    'steps': [
                        {'uses': 'actions/checkout@v5'},
                        {
                            'name': 'Run interactivity probe',
                            'id': 'out',
                            'shell': 'pwsh',
                            'run': (
                                "$ok = $true\n"
                                '"ok=$ok" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8\n'
                            ),
                        },
                    ],
                },
            }
        }

        changed = ensure_interactivity_probe_job(doc)

        self.assertTrue(changed)
        run_script = doc['jobs']['probe']['steps'][1]['run']
        self.assertIn('$okString = if ($ok) { "true" } else { "false" }', run_script)
        self.assertNotIn('"ok=$ok"', run_script)

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
        setup_node_steps = [step for step in lint_steps if step.get('name') == 'Setup Node with cache']
        self.assertEqual(len(setup_node_steps), 1)
        self.assertEqual(setup_node_steps[0].get('uses'), 'actions/setup-node@v5')

    def test_lint_resiliency_normalizes_existing_setup_node_major(self) -> None:
        doc = {
            'jobs': {
                'lint': {
                    'steps': [
                        {'uses': 'actions/checkout@v5'},
                        {
                            'name': 'Setup Node with cache',
                            'uses': 'actions/setup-node@v4',
                            'with': {
                                'node-version': '20',
                                'cache': 'npm',
                            },
                        },
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
        setup_node_step = next(step for step in doc['jobs']['lint']['steps'] if step.get('name') == 'Setup Node with cache')
        self.assertEqual(setup_node_step.get('uses'), 'actions/setup-node@v5')

    def test_force_run_output_uses_standard_false_literal(self) -> None:
        doc = {
            'jobs': {
                'pre-init': {
                    'steps': [
                        {
                            'name': 'Gate docs-only',
                            'id': 'g',
                            'uses': './.github/actions/pre-init-gate',
                        },
                    ],
                },
            }
        }

        changed = ensure_preinit_force_run_outputs(doc)

        self.assertTrue(changed)
        out_step = next(step for step in doc['jobs']['pre-init']['steps'] if step.get('id') == 'out')
        self.assertIn("steps.g.outputs.docs_only || 'false'", out_step['run'])
        self.assertNotIn("''false''", out_step['run'])

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

    def test_updater_check_fails_closed_when_a_requested_file_cannot_be_transformed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            workflow_path = Path(temp_dir) / 'validate.yml'
            workflow_path.write_text('name: Validate\n', encoding='utf-8')

            with patch('_update_workflows_impl.apply_transforms', side_effect=RuntimeError('boom')):
                exit_code = updater_main(['--check', str(workflow_path)])

        self.assertEqual(exit_code, 4)


if __name__ == '__main__':
    unittest.main()
