#!/usr/bin/env python3
"""Validate bounded explicit preview height without UIKit or a device."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="tumo-console-metrics-") as directory:
    binary = Path(directory) / "console-metrics"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-Onone",
        str(root / "Sources/Features/Devices/ConsolePreviewMetrics.swift"),
        str(root / "scripts/fixtures/console_metrics/main.swift"), "-o", str(binary),
    ], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=15)
