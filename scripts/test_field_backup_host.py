"""Compile actual backup code and ZIPFoundation; temporary host-only storage stub."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / "Sources/Features/Backup/FlipperBackup.swift",
           root / "Sources/Features/FieldWorkflows/FieldWire.swift",
           root / "Sources/FlipperKit/Storage/FlipperFile.swift"]
with tempfile.TemporaryDirectory(prefix="tumo-field-backup-") as directory:
    project = Path(directory)
    for source in sources:
        (project / source.name).symlink_to(source)
    (project / "main.swift").symlink_to(root / "scripts/fixtures/field_backup/main.swift")
    (project / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FieldBackupHost", platforms: [.macOS(.v13)],
 dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git",
 revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")],
 targets: [.executableTarget(name: "FieldBackupHost", dependencies: ["ZIPFoundation"],
 path: ".", sources: ["main.swift", "FlipperBackup.swift", "FieldWire.swift", "FlipperFile.swift"])])
''')
    subprocess.run(["xcrun", "swift", "run", "--package-path", str(project),
                    "--scratch-path", str(project / "build"), "--jobs", "2",
                    "--build-system", "native", "FieldBackupHost"],
                   check=True, timeout=300)
