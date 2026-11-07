#!/usr/bin/env python3
"""Apply the reviewed iOS compatibility and Live changes to pinned upstream source."""
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise SystemExit(f"Unexpected upstream project layout: {old}")
    return source.replace(old, new, 1)


def main() -> None:
    project = ROOT / "Apps/iOS/BilibiliNEXT.xcodeproj/project.pbxproj"
    source = project.read_text()
    marker = "5E5EC4B101316FC8DF8BCA2D = { isa = PBXFileReference;"
    source = replace_once(
        source,
        marker,
        'A11111111111111111111111 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/MobileLive.swift"; sourceTree = SOURCE_ROOT; };\n'
        "\t\tA22222222222222222222222 = { isa = PBXBuildFile; fileRef = A11111111111111111111111; };\n\t\t"
        + marker,
    )
    for marker, addition in [
        ("B1741025F008A299C2F95BF4,", "B1741025F008A299C2F95BF4,A11111111111111111111111,"),
        ("D433264DC7EA0FEC313F8635,", "D433264DC7EA0FEC313F8635,A22222222222222222222222,"),
    ]:
        source = replace_once(source, marker, addition)

    # Validate every hunk before writing any generated Swift source. A changed
    # upstream version must fail visibly instead of silently patching another block.
    patch = str(ROOT / "Scripts/ios-live.patch")
    subprocess.run(["git", "apply", "--check", patch], cwd=ROOT, check=True)
    subprocess.run(["git", "apply", patch], cwd=ROOT, check=True)
    project.write_text(source)
    print("Applied iOS compatibility fixes, split tab builder, and registered Live source")


if __name__ == "__main__":
    main()
