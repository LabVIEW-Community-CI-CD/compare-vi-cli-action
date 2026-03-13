#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parent
if str(SCRIPT_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPT_ROOT))

from _update_workflows_impl import main


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
