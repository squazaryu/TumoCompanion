"""Run actual Foundation XCTest files on macOS without booting a Simulator.

The only substituted type is the unused live FlipperStorage convenience adapter;
all field logic and backup ZIP code are symlinked production sources.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
names = ["FieldWire.swift", "FieldEvidence.swift", "PortableObject.swift",
         "SubGhzProfile.swift", "VerifiedUserFiles.swift", "FieldEvidenceRepository.swift"]
sources = [root / "Sources/Features/FieldWorkflows" / name for name in names]
sources += [root / "Sources/Features/Backup/FlipperBackup.swift",
            root / "Sources/FlipperKit/Storage/FlipperFile.swift",
            root / "Sources/FlipperKit/Storage/DeviceFileMutationGate.swift"]
with tempfile.TemporaryDirectory(prefix="tumo-field-xctest-") as directory:
    work = Path(directory)
    logic, tests = work / "Sources/FieldWorkflowLogic", work / "Tests/FieldWorkflowLogicTests"
    logic.mkdir(parents=True); tests.mkdir(parents=True)
    for source in sources:
        (logic / source.name).symlink_to(source)
    (logic / "HostAdapter.swift").write_text('''import Foundation
@MainActor final class FlipperStorage {
 func list(_ path: String) async throws -> [FlipperFile] { throw FieldWorkflowError.deviceChanged }
 func read(_ path: String) async throws -> Data { throw FieldWorkflowError.deviceChanged }
 func checkedMD5(_ path: String, timeout: TimeInterval) async throws -> String? { throw FieldWorkflowError.deviceChanged }
 func makeDirectory(_ path: String) async throws { throw FieldWorkflowError.deviceChanged }
 func write(_ path: String, data: Data, progress: (@Sendable (Int) -> Void)?) async throws { throw FieldWorkflowError.deviceChanged }
}
''')
    for name in ["FieldWorkflowTests.swift", "FlipperBackupTests.swift"]:
        (tests / name).write_text((root / "Tests" / name).read_text().replace(
            "@testable import UnleashedCompanion", "@testable import FieldWorkflowLogic"))
    (work / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FieldWorkflowLogic", platforms: [.macOS(.v13)],
 dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git",
 revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")],
 targets: [.target(name: "FieldWorkflowLogic", dependencies: ["ZIPFoundation"]),
 .testTarget(name: "FieldWorkflowLogicTests", dependencies: ["FieldWorkflowLogic"])])
''')
    subprocess.run(["xcrun", "swift", "test", "--package-path", str(work),
                    "--scratch-path", str(work / "build"), "--jobs", "2", "--build-system", "native"],
                   check=True, timeout=300)
