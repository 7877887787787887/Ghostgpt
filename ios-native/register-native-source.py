"""Register additional native files in Capacitor's generated explicit Xcode group."""
import hashlib
from pathlib import Path
import shutil

project = Path("ios/App/App.xcodeproj/project.pbxproj")
text = project.read_text()
name = "NativeAutomation.swift"
shutil.copyfile(Path("ios-native") / name, Path("ios/App/App") / name)
if f"/* {name} in Sources */" not in text:
    file_id = hashlib.sha256((name + "file").encode()).hexdigest()[:24].upper()
    build_id = hashlib.sha256((name + "build").encode()).hexdigest()[:24].upper()
    file_line = f'\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
    build_line = f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n'
    for marker, line in [("/* Begin PBXFileReference section */\n", file_line), ("/* Begin PBXBuildFile section */\n", build_line)]:
        assert text.count(marker) == 1, f"Unexpected project format: {marker}"
        text = text.replace(marker, marker + line, 1)
    lines = text.splitlines(keepends=True)
    for suffix, addition in [("/* SceneDelegate.swift */,", f"\t\t\t\t{file_id} /* {name} */,\n"),
                             ("/* SceneDelegate.swift in Sources */,", f"\t\t\t\t{build_id} /* {name} in Sources */,\n")]:
        matches = [i for i, line in enumerate(lines) if line.strip().endswith(suffix)]
        assert len(matches) == 1, f"Expected one source anchor: {suffix}"
        lines.insert(matches[0] + 1, addition)
    project.write_text("".join(lines))
print("Registered NativeAutomation.swift in the App target")
