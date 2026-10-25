#!/usr/bin/env python3
"""Compile the actual discovery assignments against Apple's GATT property bits.

This creates no CBCentralManager/CBPeripheral and never opens a Bluetooth link.
Unlike the boolean policy test, it checks the real FlipperBLE property predicates.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/FlipperKit/BLE/FlipperBLE.swift").read_text()
fixture = (root / "scripts/fixtures/ble_gatt_contract/main.swift").read_text()
for field, marker in [("hasSerialTX", "TX_DISCOVERY"), ("hasSerialFlow", "FLOW_DISCOVERY")]:
    bindings = re.findall(r"^\s*(readiness\." + field + r"\s*=\s*[^\n]+)$", source, re.MULTILINE)
    if len(bindings) != 1:
        raise SystemExit(f"Expected one production {field} discovery binding, found {len(bindings)}")
    fixture = fixture.replace("// " + marker, bindings[0].strip())

with tempfile.TemporaryDirectory(prefix="tumo-gatt-contract-") as directory:
    main = Path(directory) / "main.swift"
    main.write_text(fixture)
    binary = Path(directory) / "gatt-contract"
    sources = [root / "Sources/FlipperKit/BLE/BLESessionReadiness.swift"]
    classifier = root / "Sources/FlipperKit/BLE/BLECharacteristicSupport.swift"
    if classifier.exists():
        sources.append(classifier)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-Onone",
                    *map(str, sources), str(main), "-o", str(binary)], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=15)
