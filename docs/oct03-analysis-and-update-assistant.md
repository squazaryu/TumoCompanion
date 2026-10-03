# October 3 development candidate

Current main was merged with published 1.11.25 RC1 source da40ea7 before new
development. RC1 backup/crash/ESP32 verification is retained. No public release
or automatic Feather change is made by this preparation.

## Features

- TumoSpectrum → Interactive RAW timeline: existing Sub-GHz RAW files, A/B
  start-aligned overlays, zoom/position, interval statistics and SHA-bound local
  annotations. No radio use, key recovery or original-file writes. 4 MiB and
  500,000-pulse bounds; sampled drawing is disclosed, statistics use original data.
- Firmware → Before/after update checks: fresh device/source/API identity, verified
  catalog evidence, SD capacity, full MD5 observations in five capture folders,
  explicit per-device checkpoint and differences. Refresh never advances baseline.
  Missing means not found; the viewer cannot identify a deletion process.
- Acceptance report must match the current version/commit/F7/schema. Automatic
  results, failed checks and skipped/manual work stay separate. It is not proof
  of receiver/card hardware acceptance.
- Verified incremental backup reuses locally SHA-verified, device-MD5-matching
  unchanged bytes while producing a standalone full ZIP. Corrupt old archives
  are not trusted. Incomplete/changing enumeration cannot publish success.
  Incrementality saves BLE traffic, not duplicate archive storage on the phone.
- ESP32 → Remote ID diagnostics reads stopped Marauder UART logs. Requires a
  Remote ID-capable board build, not 1.17.0. Operator identity/location is not kept
  in the view model. Zero/zero position and unset altitude flags are unknown.
- New diagnostic reads bound accumulated RPC data and drain rejected responses
  before returning an error, preserving the command gate/server stream.

## Validation gates

Model tests use explicit fake sources for device switches/checkpoint behavior.
Simulator builds and automated tests are separate from hardware acceptance.
DEBUG preview routes use fixtures and production views, not real-device evidence:
`-signal-timeline-qa`, `-update-assistant-qa`, `-remote-id-qa`.
Visual/interaction validation and owner approval precede publication.

After installing a future candidate: verify backup/recovery and interrupted reads,
check inventories before/after firmware on the same device, export the current
Acceptance report and try RAW A/B selection/cancellation with owned captures.
No deletion/restore is automated by the assistant.
