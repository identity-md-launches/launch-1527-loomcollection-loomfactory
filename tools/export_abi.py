#!/usr/bin/env python3
"""Export or check the ABI arrays from a completed local forge build; uses no network."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a delivered ABI differs from the build")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    contracts = ("LaunchToken", "LoomCollection", "LoomFactory")
    for name in contracts:
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.is_file():
            raise SystemExit(f"Missing {artifact.relative_to(root)}; run forge build first.")
        abi = json.loads(artifact.read_text())["abi"]
        content = json.dumps(abi, indent=2) + "\n"
        target = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not target.is_file() or target.read_text() != content:
                raise SystemExit(f"ABI mismatch: {target.relative_to(root)}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        print(f"{'Checked' if args.check else 'Exported'} {target.relative_to(root)}")


if __name__ == "__main__":
    main()
