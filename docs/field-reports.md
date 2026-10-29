# Field Reports — implementation, not an app release

Open Home → Tools → Field Reports. Export CSV on Flipper first from Sensor Watch,
Power Journal, Tumo UHF Inventory or Varta Inspector. Listing and on-demand reads
reuse the existing BLE storage/RPC service. No new firmware background collector,
GPS stream, BLE connection reset, remote deletion or source-file write is added.

The repository exposes only list/read/checksum capabilities. It confines paths to
`/ext/apps_data/device_library/{reports,power}`, accepts exact timestamped filenames,
limits a file to64KiB, checks indexed size and matching device MD5 before/after
the bounded read, validates one of four current producer schemas, and records a
local SHA256. MD5 here is transfer/stability evidence, not authenticity or a
signature. A missing checksum or malformed/changing CSV fails closed.

The list shows at most the latest256 exports, sorted by numeric timestamp and
per-second revision. It never downloads the entire library automatically.
Only Sensor Watch currently records an object identifier; other reports are
labeled device sessions rather than assigned an invented object. Sensor graphs
select objects/sensors; power graphs show battery, volts, current or temperature.
X is sample order, not elapsed time or proof of continuous/background monitoring.
Missing sensor measurements remain absent, not zero. UHF signal/frequency values
remain raw, not dBm/Hz. Varta matches are not proof of authenticity/access rights.

Export CSV to Files uses the verified original bytes. Source SD exports remain
untouched; there is no editor or delete control on this screen. Offline durable
phone caching and cross-device/object association are not claimed implemented.

The managed USB CD-ROM FAP and native favorites-writer namespace are protected
from Community Pack overwrite. Their delivery/catalog activation remains a
separate release step. Existing explicit user override controls are retained.

Validation: host parser/repository/protection tests, native Xcode build,688 iOS
unit tests and UI navigation for all four kinds (including large type) on an
isolated iOS27 simulator. The pure parser and repository exceed93% host line
coverage; this is not whole-app UI/physical BLE coverage. Previews use synthetic
local fixtures; no connected Flipper was queried. No IPA or Feather version is
published by this implementation change.
