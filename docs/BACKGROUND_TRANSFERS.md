# Background BLE transfers

TumoCompanion treats a long transfer as a recoverable transaction. The app opts in to
Core Bluetooth's `bluetooth-central` background mode and central-manager state
preservation, then keeps a finite UIKit background assertion while an install is active.
The assertion is a grace period, not an unlimited execution entitlement.

## What happens when the app is backgrounded

1. `FlipperBLE` keeps the last peripheral and restoration identifier. Core Bluetooth can
   wake the app for connection and characteristic events, and the app reattaches on the
   next foreground or restoration callback.
2. Firmware, FW Packages, Community Apps, and ESP32 staging arm a named
   `BackgroundTransferGuard` before network or BLE work starts. The idle timer is held
   while the transaction is active.
3. If iOS calls the expiration handler, the transfer's `StopToken` is set. BLE writes
   check that token between acknowledged RPC blocks, discard their temporary file, and
   leave the previous installed copy untouched. A small recovery checkpoint is kept so
   a subsequent process can explain that the operation needs a retry.
4. On a normal completion or a handled failure the checkpoint is cleared. FW Packages'
   device-side journal remains authoritative and is reconciled when its screen opens.

## Platform boundary

iOS does not promise indefinite background execution. A user force-quitting the app from
the app switcher also prevents Core Bluetooth state restoration. We therefore never claim
that a multi-megabyte BLE upload can run forever while the app is hidden. The supported
behavior is: keep the link and transfer alive for the system-granted window, stop at a
safe file boundary when that window expires, restore the connection when possible, and
make retry/recovery deterministic instead of leaving a partial live file.

`BGAppRefreshTask` remains reserved for opportunistic release checks. It is not used to
drive an active BLE upload because the scheduler provides no delivery deadline and does
not maintain a live connection.

## Device test checklist

- Start a FW Packages, Community Apps, firmware, and ESP32 transfer over BLE.
- Lock the phone and leave the app in the background for the first transfer window.
- Confirm the old live file remains valid if the assertion expires; no `.ucnew`, `.part`,
  or `.partial-*` file is promoted.
- Return to TumoCompanion and confirm Core Bluetooth reattaches without toggling BLE on
  the Flipper, then retry the transfer.
- Force-quit the app once to document the expected limitation: the next launch must
  reconnect and run the normal recovery/retry path.
- Repeat with USB SD mode; the same stop token applies to local chunked writes, while
  the security-scoped bookmark must be reachable again before retrying.
