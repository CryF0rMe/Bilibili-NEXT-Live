#!/usr/bin/env python3
"""Apply the experimental Live tab to the upstream iOS project in CI."""
from pathlib import Path
p=Path("Apps/iOS/Sources/MobileBrowse.swift")
s=p.read_text()
changes=[
('    case 3: "资料库"','    case 3: "资料库"\n    case 5: "直播"'),
('    case 3: "square.stack"','    case 3: "square.stack"\n    case 5: "dot.radiowaves.left.and.right"'),
('ForEach(navigation.preferences.phoneTabs, id: \\.self)', 'ForEach(Array(navigation.preferences.phoneTabs.prefix(4)) + [5] + Array(navigation.preferences.phoneTabs.dropFirst(4)), id: \\.self)'),
('            case 2: MobileInbox(store: store)', '            case 2: MobileInbox(store: store)\n            case 5: MobileLiveHome()'),
('if !navigation.preferences.phoneTabs.contains(selectedTab)', 'if !(navigation.preferences.phoneTabs.contains(selectedTab) || selectedTab == 5)')
]
for old,new in changes:
    if old not in s:
        raise SystemExit(f"Upstream navigation changed, cannot apply patch: {old}")
    s=s.replace(old,new,1)
p.write_text(s)
project=Path("Apps/iOS/BilibiliNEXT.xcodeproj/project.pbxproj")
s=project.read_text()
marker='5E5EC4B101316FC8DF8BCA2D = { isa = PBXFileReference;'
if marker not in s:
    raise SystemExit("Unexpected project layout")
s=s.replace(marker, 'A11111111111111111111111 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/MobileLive.swift"; sourceTree = SOURCE_ROOT; };\n\t\tA22222222222222222222222 = { isa = PBXBuildFile; fileRef = A11111111111111111111111; };\n\t\t'+marker,1)
for marker,addition in [
 ('B1741025F008A299C2F95BF4,','B1741025F008A299C2F95BF4,A11111111111111111111111,'),
 ('D433264DC7EA0FEC313F8635,','D433264DC7EA0FEC313F8635,A22222222222222222222222,')
]:
    if marker not in s: raise SystemExit(f"Missing project entry {marker}")
    s=s.replace(marker,addition,1)
project.write_text(s)
print("Live tab and project file patched")
