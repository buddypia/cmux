#!/usr/bin/env python3
"""Regression tests for scripts/check-pbxproj-package-products.py."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check-pbxproj-package-products.py"


def write_pbxproj(path: Path, product_body: str) -> None:
    path.write_text(
        "\n".join(
            [
                "// Minimal synthetic project for package product validation.",
                "/* Begin XCLocalSwiftPackageReference section */",
                '\t\tAAAA00000000000000000001 /* XCLocalSwiftPackageReference "CmuxCanvasUI" */ = {',
                "\t\t\tisa = XCLocalSwiftPackageReference;",
                "\t\t\trelativePath = Packages/macOS/CmuxCanvasUI;",
                "\t\t};",
                "/* End XCLocalSwiftPackageReference section */",
                "",
                "/* Begin XCSwiftPackageProductDependency section */",
                "\t\tBBBB00000000000000000001 /* CmuxCanvasUI */ = {",
                "\t\t\tisa = XCSwiftPackageProductDependency;",
                product_body.rstrip("\n"),
                "\t\t\tproductName = CmuxCanvasUI;",
                "\t\t};",
                "/* End XCSwiftPackageProductDependency section */",
                "",
            ]
        ),
        encoding="utf-8",
    )


def run_check(path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECK), str(path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)

        valid = tmp_path / "valid.pbxproj"
        write_pbxproj(
            valid,
            "\t\t\tpackage = AAAA00000000000000000001 /* XCLocalSwiftPackageReference \"CmuxCanvasUI\" */;\n",
        )
        valid_result = run_check(valid)
        if valid_result.returncode != 0:
            print(valid_result.stdout, end="")
            print(valid_result.stderr, end="", file=sys.stderr)
            print(f"FAIL: valid fixture returned {valid_result.returncode}")
            return 1

        missing = tmp_path / "missing.pbxproj"
        write_pbxproj(missing, "")
        missing_result = run_check(missing)
        if missing_result.returncode != 1:
            print(missing_result.stdout, end="")
            print(missing_result.stderr, end="", file=sys.stderr)
            print(f"FAIL: missing-package fixture returned {missing_result.returncode}")
            return 1
        if "is missing its package reference" not in missing_result.stderr:
            print(missing_result.stderr, end="", file=sys.stderr)
            print("FAIL: missing-package diagnostic did not explain the failure")
            return 1

        unknown = tmp_path / "unknown.pbxproj"
        write_pbxproj(
            unknown,
            "\t\t\tpackage = CCCC00000000000000000001 /* XCLocalSwiftPackageReference \"Missing\" */;\n",
        )
        unknown_result = run_check(unknown)
        if unknown_result.returncode != 1:
            print(unknown_result.stdout, end="")
            print(unknown_result.stderr, end="", file=sys.stderr)
            print(f"FAIL: unknown-package fixture returned {unknown_result.returncode}")
            return 1
        if "references unknown package" not in unknown_result.stderr:
            print(unknown_result.stderr, end="", file=sys.stderr)
            print("FAIL: unknown-package diagnostic did not explain the failure")
            return 1

    print("PASS: pbxproj Swift package product dependency guard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
