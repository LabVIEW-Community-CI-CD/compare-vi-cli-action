from __future__ import annotations

import re
import sys


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


slug = "{{ cookiecutter.pack_slug }}"
if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
    fail("pack_slug must be lowercase kebab-case.")

results_root = "{{ cookiecutter.results_root }}"
if not results_root.startswith("tests/results/_agent/"):
    fail("results_root must stay under tests/results/_agent/.")
