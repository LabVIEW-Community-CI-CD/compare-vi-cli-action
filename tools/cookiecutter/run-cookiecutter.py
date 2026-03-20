#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from cookiecutter.main import cookiecutter


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a comparevi cookiecutter template with JSON context.")
    parser.add_argument("--template-root", required=True)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--context-file")
    parser.add_argument("--no-input", action="store_true")
    parser.add_argument("--overwrite-if-exists", action="store_true")
    parser.add_argument("--accept-hooks", default="yes", choices=["yes", "no", "ask"])
    args = parser.parse_args()

    extra_context = {}
    if args.context_file:
        with open(args.context_file, "r", encoding="utf-8") as handle:
            extra_context = json.load(handle)

    Path(args.output_dir).mkdir(parents=True, exist_ok=True)
    project_dir = cookiecutter(
        args.template_root,
        directory=args.directory,
        output_dir=args.output_dir,
        no_input=args.no_input,
        overwrite_if_exists=args.overwrite_if_exists,
        extra_context=extra_context,
        accept_hooks=args.accept_hooks,
    )
    print(
        json.dumps(
            {
                "schema": "comparevi-cookiecutter-run@v1",
                "project_dir": project_dir,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
