# Connection health and iOS 27 review

## Scope

The owner's report is a working-looking iPhone Home screen while the Flipper
showed the idle BLE icon. The preview reportedly moved, but a simultaneous trace
was not captured. A stale iPhone state and a stale firmware icon are separate
possibilities. This patch does not claim a proven cause of that physical event.
It does not flash the Flipper, change pairing, access SD contents, or change
firmware/FW Packages/ESP32 releases.

## Responsibilities

- `FlipperBLE` owns CoreBluetooth and GATT discovery/subscription evidence.
  `BLESessionReadiness` makes transitions idempotent. Serial RX, TX and flow
  characteristics plus acknowledged TX/flow notifications are all required.
  App Bridge discovery and notification order are independent of serial; a late
  service cannot reset serial credit or clear an already negotiated bridge.
- `FlipperRPCTransport` is the injected byte-channel boundary. Real RPC tests
  use an in-process transport, not an emulated Bluetooth peer or a device.
- `FlipperRPC` owns command correlation and the existing FIFO command gate.
  The health probe uses nonblocking gate admission, a fresh command ID/nonce,
  a matching pong and a bounded deadline. It yields to active/queued work and
  never requests a disconnect. Once sent, cancellation keeps the gate reserved
  until reply/deadline, preventing another command overtaking the ping.
- `ConnectionMonitor` is main-actor isolated. It owns app-facing evidence, a
  generation-protected/coalesced check, foreground lifecycle, and passive valid
  RPC traffic. Current-session screen frames are legitimate evidence. Old
  packets, old probe results and old screen pixels are not new-session proof.
- SwiftUI observes this model without implementing connection logic in `body`.
  Home, Remote and Connectivity distinguish checking/verified/busy/no-response
  and explicitly mark old screen images. Large text stacks the console panels;
  native symbols, semantic colors and 44pt action targets are retained.

## Lifecycle and scheduling

The initial active phase and every return to foreground request a check. While
foregrounded, a 15-second task checks only when there has been no recent valid
RPC traffic (10 seconds). Foreground checks are coalesced. Going inactive stops
the loop; no continuous background polling or artificial background task is
introduced. Bluetooth-central restoration and the user's keep-alive setting
remain in place. iOS suspension, termination and user force-quit are not defeated.

Notification subscription success is confirmed through
[didUpdateNotificationStateFor](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral(_:didupdatenotificationstatefor:error:)),
not inferred from `setNotifyValue`. App activity follows
[ScenePhase](https://developer.apple.com/documentation/swiftui/scenephase).
Apple documents the limits of
[Core Bluetooth background execution and restoration](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

## Platform review and remaining limits

Local validation uses installed Xcode 27.1 / iOS SDK 27.1 and iOS Simulator 27.0;
minimum deployment remains iOS 17. No unsupported assumption about an iOS 27
always-running background process is introduced. Existing ObservableObject/
environment ownership is preserved; this is not a full Swift 6 migration.
Unrelated pre-existing Swift 6 isolation/deprecation warnings remain follow-ups.
The [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
do not establish the cause of this owner's connection/icon observation.

The current firmware statusbar update changes an already enabled viewport's
width without explicitly invalidating it. That is a separate redraw candidate,
not proven as the cause and not modified here. Check it with a separate native
regression and physical device trace rather than silently bundling a firmware
release with this iOS patch.

## Acceptance

Host readiness/evidence checks, real RPC mock-wire tests, monitor/lifecycle tests,
existing package/backup tests and visual screenshots are separate gates. UI
fixtures are DEBUG-only; release builds cannot fake a connected preview.
Hardware acceptance remains pending: reconnect with the app, compare the Flipper
icon with a changing Home preview, background/foreground, then repeat during a
large Community App transfer. A quiet/static desktop alone is not a failure.
No independent agent review was performed because delegation was not authorized.
