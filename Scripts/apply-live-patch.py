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
    files = [
        ("MobileLive.swift", "A11111111111111111111111", "A22222222222222222222222"),
        ("MobileLiveAPI.swift", "A33333333333333333333333", "A44444444444444444444444"),
        ("MobileLiveModel.swift", "A55555555555555555555555", "A66666666666666666666666"),
        ("MobileLivePlayback.swift", "A77777777777777777777777", "A88888888888888888888888"),
    ]
    entries = []
    for name, file_id, build_id in files:
        if not (ROOT / "Apps/iOS/Sources" / name).is_file():
            raise SystemExit(f"Missing live source: {name}")
        if file_id in source or build_id in source:
            raise SystemExit(f"Live source is already registered: {name}")
        entries.append(
            f'{file_id} = {{ isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/{name}"; sourceTree = SOURCE_ROOT; }};\n\t\t'
            f'{build_id} = {{ isa = PBXBuildFile; fileRef = {file_id}; }};\n\t\t'
        )
    source = replace_once(source, marker, "".join(entries) + marker)
    for marker, addition in [
        ("B1741025F008A299C2F95BF4,", "B1741025F008A299C2F95BF4," + "".join(file_id + "," for _, file_id, _ in files)),
        ("D433264DC7EA0FEC313F8635,", "D433264DC7EA0FEC313F8635," + "".join(build_id + "," for _, _, build_id in files)),
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
