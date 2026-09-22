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
requirements_path = ROOT / "Sources/Features/Updates/ManagedPackageRequirements.swift"
requirements = requirements_path.read_text() if requirements_path.exists() else ""
program = "import Foundation\n" + policy + "\nenum PluginRouteReconciliation {\n" + identity + "\n}\nenum PluginUpdater {\n" + builtins + "\n}\n" + requirements + r'''
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
let bleTarget = "/ext/apps/Bluetooth/hid_ble.fap"
let cases: [(String?, String?, Int?, Bool)] = [
    ("88.10", "tumoflip", 7, true), ("88.11", "tumoflip", 7, false),
    ("88.12", "Tumoflip", 7, false), ("88.11", "unleashed", 7, true),
    (nil, "tumoflip", 7, true), ("88.11", nil, 7, true),
    ("88.11", "tumoflip", 18, true), ("88.bad", "tumoflip", 7, true),
    ("89.0", "tumoflip", 7, true), ("88.11.0", "tumoflip", 7, true),
]
for (api, origin, target, shouldBlock) in cases {
    let blocked = ManagedPackageRequirements.blocked(targets: [bleTarget], originFork: origin, firmwareAPI: api, hardwareTarget: target)
    if (blocked[bleTarget] != nil) != shouldBlock { failures += 1 }
}
if ManagedPackageRequirements.blocked(targets: ["/ext/apps/USB/hid_usb.fap"], originFork: nil, firmwareAPI: nil, hardwareTarget: nil).count != 0 { failures += 1 }
print("Total managed-app protection/compatibility failures: \(failures)")
let libraryTarget = "/ext/apps/Tools/device_library.fap"
let libraryPaths = [libraryTarget, libraryTarget.uppercased(),
    "/ext/apps_data/device_library/cards/example.card",
    "/EXT/APPS_DATA/DEVICE_LIBRARY/PLUGINS/FILE_HISTORY.FAL",
    "/ext/apps_data/device_library/history/checkpoint.bin"]
for path in libraryPaths {
    if !PluginProtectionPolicy.isProtected(name: "renamed_entry", remotePath: path,
        excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
    if PluginProtectionPolicy.isProtected(name: "renamed_entry", remotePath: path,
        excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: ["device_library"]) { failures += 1 }
}
for path in ["/ext/apps/Tools/file_history.fap", "/ext/apps_data/device_library_extra/data", "/ext/apps_data/another_app/file_history.fal"] {
    if PluginProtectionPolicy.isProtected(name: "unrelated", remotePath: path,
        excluded: PluginUpdater.builtInExcluded, unprotectedBuiltIns: []) { failures += 1 }
}
let libraryCases: [(String?, String?, Int?, Bool)] = [
    ("88.4", "tumoflip", 7, true), ("88.5", "tumoflip", 7, false),
    ("88.13", "Tumoflip", 7, false), ("88.5", "unleashed", 7, true),
    (nil, "tumoflip", 7, true), ("88.5", nil, 7, true),
    ("88.5", "tumoflip", 18, true), ("88.bad", "tumoflip", 7, true),
    ("89.0", "tumoflip", 7, true), ("88.5.0", "tumoflip", 7, true),
    ("88.-1", "tumoflip", 7, true), ("88.99999999999999999999999", "tumoflip", 7, true),
]
for (api, origin, target, shouldBlock) in libraryCases {
    let blocked = ManagedPackageRequirements.blocked(targets: [libraryTarget, libraryTarget.uppercased()], originFork: origin, firmwareAPI: api, hardwareTarget: target)
    if (blocked[libraryTarget] != nil) != shouldBlock { failures += 1 }
    if (blocked[libraryTarget.uppercased()] != nil) != shouldBlock { failures += 1 }
}
let mixed = ManagedPackageRequirements.blocked(targets: [libraryTarget, bleTarget], originFork: "tumoflip", firmwareAPI: "88.5", hardwareTarget: 7)
if mixed[libraryTarget] != nil || mixed[bleTarget] == nil { failures += 1 }
print("Including Device Library protection/compatibility failures: \(failures)")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="specter-policy-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
