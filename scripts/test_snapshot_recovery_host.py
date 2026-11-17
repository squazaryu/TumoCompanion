"""Execute actual manifest and recovery metadata code without a device/Simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]


def declaration(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


updater = (root / "Sources/Features/Updates/TumoflipUpdater.swift").read_text()
routing = (root / "Sources/Features/Updates/TumoflipFirmwareRouting.swift").read_text()
recovery = (root / "Sources/Features/Updates/BackgroundTransfer.swift").read_text()
recovery = recovery.split("/// The UIKit background assertion is finite.", 1)[0].replace("import UIKit", "")
program = "import Foundation\nimport CryptoKit\n"
program += declaration(updater, "enum TumoflipHash {") + "\n"
program += declaration(updater, "struct TumoflipState:") + "\n"
program += declaration(updater, "struct TumoflipJournal:") + "\n"
program += declaration(routing, "enum TumoflipFirmwareChannel:") + "\n"
program += (root / "Sources/Features/Updates/TumoflipManifest.swift").read_text() + "\n"
program += recovery + "\n"
program += (root / "scripts/fixtures/snapshot_recovery/main.swift").read_text()
with tempfile.TemporaryDirectory(prefix="tumo-snapshot-recovery-") as directory:
    temporary = Path(directory)
    source, binary = temporary / "fixture.swift", temporary / "fixture"
    source.write_text(program)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-Onone", "-parse-as-library",
                    str(source), "-o", str(binary)], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=30)
