from __future__ import annotations

from pathlib import Path


PACKAGE_ROOT = Path(__file__).resolve().parent
SCRIPTS_ROOT = PACKAGE_ROOT.parent.parent
REPO_ROOT = SCRIPTS_ROOT.parent
PROTO_DIR = REPO_ROOT / "proto"
