#!/usr/bin/env python3
"""Run the production BLE readiness/health policy without a radio or Simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="tumocompanion-connection-") as directory:
    binary = Path(directory) / "connection-health"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-Onone",
        str(root / "Sources/FlipperKit/BLE/BLESessionReadiness.swift"),
        str(root / "Sources/FlipperKit/BLE/ConnectionEvidence.swift"),
        str(root / "scripts/fixtures/connection_health/main.swift"),
        "-o", str(binary),
    ], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=15)
