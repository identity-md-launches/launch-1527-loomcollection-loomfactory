#!/usr/bin/env python3
"""Verify that the ordinary vendored dependency files match their recorded release bytes."""

import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    dependencies = json.loads((root / "lib" / "dependencies.json").read_text())
    count = 0
    for dependency in dependencies:
        for relative, expected in dependency["files"].items():
            path = root / "lib" / dependency["name"] / relative
            if path.is_symlink() or not path.is_file():
                raise SystemExit(f"Missing ordinary file: {path.relative_to(root)}")
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != expected:
                raise SystemExit(f"Dependency content mismatch: {path.relative_to(root)}")
            count += 1
        print(f"Checked {dependency['name']} {dependency['version']}")
    print(f"Verified {count} vendored files.")


if __name__ == "__main__":
    main()
