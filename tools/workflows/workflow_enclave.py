#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from _enclave import ensure_enclave, load_default_scope, run_updater


def main(argv: list[str]) -> int:
    if argv == ['--ensure-only']:
        ensure_enclave()
        return 0
    use_default_scope = False
    if argv and argv[0] == '--default-scope':
        use_default_scope = True
        argv = argv[1:]
    if not argv or argv[0] not in ('--check', '--write'):
        print('Usage:')
        print('  workflow_enclave.py --ensure-only')
        print('  workflow_enclave.py --default-scope (--check|--write)')
        print('  workflow_enclave.py (--check|--write) <files...>')
        return 2
    if use_default_scope:
        argv = [argv[0], *load_default_scope()]
    return run_updater(argv)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
