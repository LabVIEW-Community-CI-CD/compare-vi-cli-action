#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path, PurePosixPath

WORKFLOWS_ROOT = Path(__file__).resolve().parent
VENV_DIR = Path(os.environ.get('COMPAREVI_WORKFLOW_ENCLAVE_HOME', str(WORKFLOWS_ROOT / '.venv'))).resolve()
STAMP_PATH = VENV_DIR / '.requirements.sha256'
REQUIREMENTS_PATH = WORKFLOWS_ROOT / 'requirements.txt'
UPDATE_WORKFLOWS_PATH = WORKFLOWS_ROOT / 'update_workflows.py'
MANIFEST_PATH = WORKFLOWS_ROOT / 'workflow-manifest.json'


def _venv_python_path() -> Path:
    if os.name == 'nt':
        return VENV_DIR / 'Scripts' / 'python.exe'
    return VENV_DIR / 'bin' / 'python'


def _requirements_digest() -> str:
    return hashlib.sha256(REQUIREMENTS_PATH.read_bytes()).hexdigest()


def _run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def _ensure_pip(venv_python: Path) -> None:
    probe = subprocess.run(
        [str(venv_python), '-m', 'pip', '--version'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False
    )
    if probe.returncode == 0:
        return
    _run([str(venv_python), '-m', 'ensurepip', '--upgrade'])


def ensure_enclave() -> Path:
    venv_python = _venv_python_path()
    if not venv_python.exists():
        _run([sys.executable, '-m', 'venv', str(VENV_DIR)])

    _ensure_pip(venv_python)
    expected_digest = _requirements_digest()
    actual_digest = STAMP_PATH.read_text(encoding='utf-8').strip() if STAMP_PATH.exists() else ''
    if actual_digest != expected_digest:
        _run([str(venv_python), '-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip'])
        _run([str(venv_python), '-m', 'pip', 'install', '--disable-pip-version-check', '--requirement', str(REQUIREMENTS_PATH)])
        STAMP_PATH.write_text(expected_digest, encoding='utf-8')

    return venv_python


def _normalize_managed_workflow_file(entry: object) -> str:
    if not isinstance(entry, str) or not entry.strip():
        raise RuntimeError(f'invalid managed workflow entry: {entry!r}')

    normalized = entry.replace('\\', '/').strip()
    workflow_path = PurePosixPath(normalized)
    if workflow_path.is_absolute() or '..' in workflow_path.parts:
        raise RuntimeError(f'managed workflow entry must be a repo-relative workflow path: {entry!r}')
    if len(workflow_path.parts) < 3 or workflow_path.parts[0] != '.github' or workflow_path.parts[1] != 'workflows':
        raise RuntimeError(f'managed workflow entry must live under .github/workflows: {entry!r}')

    return workflow_path.as_posix()


def load_default_scope() -> list[str]:
    payload = json.loads(MANIFEST_PATH.read_text(encoding='utf-8'))
    workflows = payload.get('managedWorkflowFiles')
    if not isinstance(workflows, list) or not workflows:
        raise RuntimeError(f'workflow manifest has no managedWorkflowFiles: {MANIFEST_PATH}')
    return [_normalize_managed_workflow_file(item) for item in workflows]


def run_updater(argv: list[str]) -> int:
    venv_python = ensure_enclave()
    env = os.environ.copy()
    env['COMPAREVI_WORKFLOW_ENCLAVE_ACTIVE'] = '1'
    completed = subprocess.run([str(venv_python), str(UPDATE_WORKFLOWS_PATH), *argv], env=env)
    return completed.returncode
