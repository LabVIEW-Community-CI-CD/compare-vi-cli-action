from __future__ import annotations

import re
import sys


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


slug = "{{ cookiecutter.target_slug }}"
if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
    fail("target_slug must be lowercase kebab-case.")

repo_slug = "{{ cookiecutter.repo_slug }}"
if "/" not in repo_slug:
    fail("repo_slug must look like owner/repo.")
