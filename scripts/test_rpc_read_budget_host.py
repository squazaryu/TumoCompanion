#!/usr/bin/env python3
"""Compile the real Swift budget with host cases; no Bluetooth or Simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="tumocompanion-rpc-budget-") as directory:
    binary = Path(directory) / "rpc-budget"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-Onone",
        str(root / "Sources/FlipperKit/RPC/RPCReadBudget.swift"),
        str(root / "scripts/fixtures/rpc_read_budget/main.swift"),
        "-o", str(binary),
    ], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=15)
