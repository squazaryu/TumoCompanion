#!/usr/bin/env python3
"""Run the production field-report parser without BLE, UIKit or user files."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / "Sources/Features/FieldReports/FieldReport.swift"]
with tempfile.TemporaryDirectory(prefix="tumo-field-reports-") as directory:
    binary = Path(directory) / "field-reports"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-Onone",
        *[str(path) for path in sources if path.exists()],
        str(root / "scripts/fixtures/field_reports/main.swift"), "-o", str(binary),
    ], check=True, timeout=120, env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"})
    subprocess.run([str(binary)], check=True, timeout=15)
    repository = root / "Sources/Features/FieldReports/FieldReportRepository.swift"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-Onone",
        *[str(path) for path in sources if path.exists()],
        *([str(repository)] if repository.exists() else []),
        *([str(root / "Sources/FlipperKit/Storage/FlipperFile.swift")] if (root / "Sources/FlipperKit/Storage/FlipperFile.swift").exists() else []),
        str(root / "scripts/fixtures/field_report_loading/main.swift"), "-o", str(binary),
    ], check=True, timeout=120, env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"})
    subprocess.run([str(binary)], check=True, timeout=15)
