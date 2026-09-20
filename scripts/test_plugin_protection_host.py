"""Compile production protection policy on macOS without an iOS simulator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/Features/Updates/PluginUpdater.swift").read_text()
policy = source[source.index("enum PluginProtectionPolicy {"):source.index("\nstruct PluginUpdate:")]
start = source.index("    static func pathIdentity(")
identity = source[start:source.index("\n    }", start) + 6]
start = source.index("    static let builtInExcluded: Set<String> = [")
builtins = source[start:source.index("\n    ]", start) + 6]
program = "import Foundation\n" + policy + "\nenum PluginRouteReconciliation {\n" + identity + "\n}\nenum PluginUpdater {\n" + builtins + "\n}\n" + r'''
var failures = 0
for (name, path) in [("specter", "/ext/apps/NFC/specter.fap"), ("SPECTER", "/EXT/APPS/NFC/SPECTER.FAP"), ("renamed_entry", "/ext/apps/NFC/Specter.fap")] {
    if !PluginProtectionPolicy.isProtected(name: name, remotePath: path, excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
}
if PluginProtectionPolicy.isProtected(name: "specter", remotePath: "/ext/apps/NFC/specter.fap", excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: ["specter"]) { failures += 1 }
if PluginProtectionPolicy.isProtected(name: "unrelated", remotePath: "/ext/apps/NFC/unrelated.fap", excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
print("Specter protection failures: \(failures)")
for (name, path) in [("hid_ble", "/ext/apps/Bluetooth/hid_ble.fap"), ("renamed_remote", "/EXT/APPS/BLUETOOTH/HID_BLE.FAP")] {
    if !PluginProtectionPolicy.isProtected(name: name, remotePath: path, excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
}
for name in ["hid_usb", "bad_usb", "btremote_kodi"] {
    if PluginProtectionPolicy.isProtected(name: name, remotePath: "/ext/apps/Bluetooth/\(name).fap", excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
}
print("Total managed-app protection failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="specter-policy-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
