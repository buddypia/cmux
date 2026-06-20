#!/usr/bin/env python3
"""Drop Xcode SourcePackages state that stores checkout-absolute paths."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def remove_workspace_state(source_packages_dir: Path) -> list[Path]:
    if not source_packages_dir.exists():
        return []

    state_file = source_packages_dir / "workspace-state.json"
    if not state_file.is_file():
        return []

    state_file.unlink()
    return [state_file]


def incomplete_binary_artifact_dirs(source_packages_dir: Path) -> list[Path]:
    artifacts_dir = source_packages_dir / "artifacts"
    if not artifacts_dir.is_dir():
        return []

    incomplete: list[Path] = []
    for package_dir in artifacts_dir.iterdir():
        if package_dir.name == "extract" or not package_dir.is_dir():
            continue
        for artifact_dir in package_dir.iterdir():
            if artifact_dir.is_dir() and not any(artifact_dir.iterdir()):
                incomplete.append(artifact_dir)
    return incomplete


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Remove Xcode SourcePackages workspace-state.json files after a "
            "cache restore. These state files can contain absolute paths from "
            "a previous checkout; Xcode recreates them during package resolve."
        )
    )
    parser.add_argument(
        "source_packages_dir",
        type=Path,
        help="Path passed to xcodebuild -clonedSourcePackagesDirPath",
    )
    args = parser.parse_args()

    source_packages_dir = args.source_packages_dir.resolve()
    incomplete_artifacts = incomplete_binary_artifact_dirs(source_packages_dir)
    if incomplete_artifacts:
        print(
            "removed stale Xcode SourcePackages cache with incomplete binary "
            f"artifacts: {display_path(source_packages_dir)}"
        )
        for path in incomplete_artifacts:
            print(f"  incomplete artifact directory: {display_path(path)}")
        shutil.rmtree(source_packages_dir)
        return 0

    removed = remove_workspace_state(source_packages_dir)
    if removed:
        for path in removed:
            print(f"removed stale Xcode SourcePackages state: {display_path(path)}")
    else:
        print(
            "no Xcode SourcePackages workspace-state.json files found under "
            f"{display_path(source_packages_dir)}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
