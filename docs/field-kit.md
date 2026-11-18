# Field Kit on iPhone

Open **Home → Tools → Field Kit** (also available as a configurable Home tile).
This uses the existing BLE file RPC and native Field Tools formats. No firmware
API or FW Packages rebuild is needed. Existing Sensor/Power/UHF/Varta CSV reports
remain available under Field Reports.

## Rounds and inventories

Export a round or inventory in **Field Tools** on Flipper, then refresh **Object
rounds & inventories** on iPhone. The app checks size and device MD5 before/after
the read and validates the native format. Local exports include a SHA256 digest.
These are integrity checks, not proof of authenticity or a successful field test.

The viewer accepts native manual-result TXT and TIV1 `.tinv` snapshots. Choose two
inventories to compare saved states; this does not scan the current SD or identify
the cause of a missing file. FAT case-only spelling changes are not deletions.
Native difference TXT files have no completion footer: even an empty log must not
be called a completed clean scan.

## Sub-GHz profile editor

Read the existing `/ext/subghz/assets/setting_user`, edit additional/hopping
frequencies in MHz and ordinary presets, then **Review changes → Confirm & apply**.
Close Sub-GHz on the device before applying; reopen it afterward to reload.
This first version intentionally does not silently create a missing settings file.

Custom register blocks, unknown keys and comments are retained. TumoHonda and
other explicit RX-only/unknown presets cannot enter ordinary hopping. Supported
hardware ranges are validated; this is not permission to transmit in a region.

The preview is bound to live hardware UID plus firmware commit/version and the
original bytes. Immediately before writing, the device and original checksum are
checked again. A synchronized local backup/intention under **Files →
TumoCompanion → ProfileBackups** precedes any SD mutation. Readback is mandatory.
An uncertain write leaves an explicit recovery record and blocks further profile
apply on that device until reviewed. **Local backups & recovery** checks the
current checksum and requires another explicit confirmation before restoring.
Export old completed records before managing them in Files; never discard an
unresolved intent. Backups are local, not a substitute for a whole SD backup.

## Object cards

Open an exported `.tobj` from Files or Flipper's `device_library/exports`, or create
a new portable object. Add up to eight SUB/IR/NFC/RFID/iButton recording copies.
Names/text use the native firmware limits (24-character ASCII names and bounded
UTF-8 text). Last-checked text is manual, not an automatically passed test.

Review and export a new package, or explicitly copy it to a new
`device_library/exports/phone-UUID.tobj` on Flipper. Then use **Field Tools → Import
object**, choosing a new card name. The native importer creates a new card and
new payload copies under `device_library/imports`. This is a portable-card editor,
not in-place editing of the installed native C-struct card database. FAPs/scripts
are not supported payloads. No recording is run or transmitted by the editor.

## Recover one recording

Open **Backup → Recover one recording as a new copy** below a saved ZIP. Select a
recording, review its original path and SHA256, and confirm. Complete ZIP/manifest
integrity and archive identity are checked; legacy manifestless ZIPs are not
selectively restored. The old explicit whole-archive restore remains separate.

The new file goes to `/ext/<signal-category>/Restored/<UUID>.<extension>`, never
over the original. It is checksum-verified after transfer. A failed transfer may
leave a partial new UUID copy; it cannot delete the source recording. Files larger
than 16 MiB or outside the five capture roots are not offered for selective restore.

## Boundaries and checks

- No automatic on-open writes, delete operation, app execution or transmission.
- BLE mutation leases exclude competing app-side writes and refuse to begin in
  the middle of a streaming write. This is not a global lock against the device,
  USB or other clients, nor a power-loss-atomic remote filesystem transaction.
- Background time is finite. Cancellation/expiry stops streaming and preserves
  the recovery intent when a profile write cannot be verified.
- Existing user signals, cards, pins, FAP paths and `apps_data` are not relocated.
- Host checks: `python3 scripts/test_field_workflows_host.py --coverage-dir <dir>`,
  `test_field_backup_host.py`, `test_field_unit_host.py` (Xcode/macOS needed).
- Native compatibility: `python3 scripts/test_field_native_interop.py <firmware>`
  compiles real firmware C inspect/import code with ASan/UBSan against a package
  produced by the actual Swift encoder, and checks standard-frequency parity.
- XCTest and UI suites are included in CI. Synthetic QA fixtures never create a
  live field BLE adapter. Hardware acceptance and iOS 27 visual acceptance are
  separate from compilation/host tests.

Upstream audit on 2026-11-18 found no new changes since the last review in official
firmware (release 1.5.1), Unleashed (095/dev `53818b18`), ARF (`7e3d1081`), Momentum
(`d3f89dfe`), Community 16nov2026, ProtoPirate (`dc3446b9`) or Marauder 1.20.0.
Existing protected Community provenance findings are not reclassified by this work.
