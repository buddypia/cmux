#!/usr/bin/env python3
"""Validate Swift package product dependency wiring in project.pbxproj."""

from __future__ import annotations

from pathlib import Path
import re
import sys


DEFAULT_PBXPROJ = Path("cmux.xcodeproj/project.pbxproj")
PACKAGE_REFERENCE_RE = re.compile(
    r"\n\t\t([A-Z0-9]+) /\* X(?:CRemote|CLocal)SwiftPackageReference [^*]+ \*/ = \{"
)
PRODUCT_DEPENDENCY_RE = re.compile(
    r"\n\t\t([A-Z0-9]+) /\* ([^*]+) \*/ = \{\n"
    r"(?P<body>.*?)"
    r"\n\t\t\};",
    re.DOTALL,
)
PACKAGE_LINE_RE = re.compile(r"^\t\t\tpackage = ([A-Z0-9]+) /\* ([^*]+) \*/;", re.MULTILINE)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def check_pbxproj(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    package_references = set(PACKAGE_REFERENCE_RE.findall(text))
    diagnostics: list[str] = []

    for match in PRODUCT_DEPENDENCY_RE.finditer(text):
        dependency_id = match.group(1)
        product_name = match.group(2)
        body = match.group("body")
        if "isa = XCSwiftPackageProductDependency;" not in body:
            continue

        package_match = PACKAGE_LINE_RE.search(body)
        location = f"{path}:{line_number(text, match.start())}"
        if package_match is None:
            diagnostics.append(
                f"{location}: Swift package product dependency {dependency_id} "
                f"({product_name}) is missing its package reference"
            )
            continue

        package_id = package_match.group(1)
        if package_id not in package_references:
            diagnostics.append(
                f"{location}: Swift package product dependency {dependency_id} "
                f"({product_name}) references unknown package {package_id}"
            )

    return diagnostics


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT_PBXPROJ
    if not path.exists():
        print(f"check-pbxproj-package-products: not found: {path}", file=sys.stderr)
        return 2

    diagnostics = check_pbxproj(path)
    if diagnostics:
        for diagnostic in diagnostics:
            file_path, line, message = diagnostic.split(":", 2)
            print(f"::error file={file_path},line={line}::{message.strip()}", file=sys.stderr)
        return 1

    print("check-pbxproj-package-products: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
