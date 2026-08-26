import Foundation
import Combine

/// A screen stream can be visible in more than one navigation surface at once:
/// the Home preview remains alive while the full Remote screen is pushed. Each
/// surface owns a lease so one view disappearing cannot stop the stream for the
/// other one.
enum ScreenStreamOwner: Hashable {
    case home
    case remote
}

/// High-level Flipper actions: launch apps/.fap, send Sub-GHz files, remote
/// input, device info, and the screen stream decoder.
final class FlipperControl: ObservableObject {
    let rpc: FlipperRPC
    private let ble: FlipperBLE
    private var streamCancellable: AnyCancellable?
    private let streamLock = NSLock()
    private var streamOwners = Set<ScreenStreamOwner>()
    private var streamActive = false

    // Screen frames can arrive faster than SwiftUI can redraw the Canvas. Keep
    // only the newest decoded frame instead of enqueueing an unbounded backlog
    // on the main queue (which made the mirror appear frozen after input).
    private let frameDeliveryLock = NSLock()
    private var pendingPixels: [Bool]?
    private var frameDeliveryScheduled = false

    /// Latest decoded screen frame as a 128x64 1-bpp bitmap, expanded to bytes.
    @Published var screenPixels: [Bool] = Array(repeating: false, count: 128 * 64)
    @Published var streaming = false

    static let screenW = 128
    static let screenH = 64

    init(rpc: FlipperRPC = .shared, ble: FlipperBLE = .shared) {
        self.rpc = rpc
        self.ble = ble
        streamCancellable = rpc.unsolicited.sink { [weak self] main in
            if case .guiScreenFrame(let frame) = main.content {
                self?.receiveScreenFrame(frame)
            }
        }
    }

    // MARK: - Apps / .fap

    /// Launch an installed app or .fap by name or full path (e.g. "Sub-GHz" or
    /// "/ext/apps/Tools/marauder.fap"), optionally passing a file argument.
    func startApp(_ nameOrPath: String, args: String = "") async throws {
        _ = try await rpc.command { main in
            main.content = .appStartRequest({
                var r = PBApp_StartRequest()
                r.name = nameOrPath
                r.args = args
                return r
            }())
        }
    }

    /// Open a saved Sub-GHz file on the Flipper (launches the stock Sub-GHz app
    /// with the file loaded, ready to transmit on-device).
    func openSubGhzFile(_ path: String) async throws {
        try await startApp("Sub-GHz", args: path)
    }

    // Sub-GHz transmit / NFC+RFID emulate now go through CompanionBridge (it
    // waits for the companion's `ready` beacon instead of a fixed delay).

    func openNFCFile(_ path: String) async throws { try await startApp("NFC", args: path) }
    func openRFIDFile(_ path: String) async throws { try await startApp("125 kHz RFID", args: path) }

    // MARK: - Remote input (screen mirroring control)

    /// Acquire the stream for a view. The default keeps the old API source
    /// compatible for callers that only have one surface.
    func startScreenStream(for owner: ScreenStreamOwner = .home) {
        streamLock.lock()
        streamOwners.insert(owner)
        let shouldStart = ble.state == .ready && !streamActive
        if shouldStart { streamActive = true }
        streamLock.unlock()

        guard shouldStart else { return }
        rpc.send { main in
            main.content = .guiStartScreenStreamRequest(PBGui_StartScreenStreamRequest())
        }
        publishStreaming(true)
    }

    /// Release the stream for a view. The firmware stream is stopped only when
    /// the last visible surface releases its lease.
    func stopScreenStream(for owner: ScreenStreamOwner = .home) {
        streamLock.lock()
        streamOwners.remove(owner)
        let shouldStop = streamActive && streamOwners.isEmpty
        if shouldStop { streamActive = false }
        streamLock.unlock()

        guard shouldStop else { return }
        rpc.send { main in
            main.content = .guiStopScreenStreamRequest(PBGui_StopScreenStreamRequest())
        }
        publishStreaming(false)
    }

    /// Reconcile the desired owners with the current BLE link. Owners are kept
    /// across a short reconnect, while the wire-level stream state is reset so
    /// a later ready event can start a fresh stream instead of being blocked by
    /// a stale local `streamActive` flag.
    func reconcileScreenStream() {
        streamLock.lock()
        let shouldStart: Bool
        let shouldStop: Bool
        if ble.state == .ready {
            shouldStart = !streamOwners.isEmpty && !streamActive
            if shouldStart { streamActive = true }
            shouldStop = false
        } else {
            shouldStart = false
            shouldStop = streamActive
            if shouldStop { streamActive = false }
        }
        streamLock.unlock()

        if shouldStart {
            rpc.send { main in
                main.content = .guiStartScreenStreamRequest(PBGui_StartScreenStreamRequest())
            }
            publishStreaming(true)
        } else if shouldStop {
            // The link is no longer ready, so sending a stop frame would be
            // discarded by the transport. The next ready event starts cleanly.
            publishStreaming(false)
        }
    }

    func press(_ key: PBGui_InputKey, type: PBGui_InputType = .short) {
        // A short button press is press + short + release in the firmware model.
        // The firmware models a tap as press → (short|long) → release.
        sendInput(key, .press)
        sendInput(key, type == .long ? .long : .short)
        sendInput(key, .release)
    }

    private func sendInput(_ key: PBGui_InputKey, _ type: PBGui_InputType) {
        rpc.send { main in
            main.content = .guiSendInputEventRequest({
                var r = PBGui_SendInputEventRequest()
                r.key = key
                r.type = type
                return r
            }())
        }
    }

    // MARK: - Screen decode (128x64, 1bpp, column-major pages like SSD1306)

    private func receiveScreenFrame(_ frame: PBGui_ScreenFrame) {
        guard let pixels = Self.decodeScreenFrame(frame.data) else { return }
        publishScreenFrame(pixels)
    }

    /// Decode the Flipper's 128×64 page-oriented framebuffer. Exposed internally
    /// for protocol tests so malformed/short frames cannot regress into a blank
    /// or partially rendered screen.
    static func decodeScreenFrame(_ data: Data) -> [Bool]? {
        let w = Self.screenW, h = Self.screenH
        let expectedBytes = w * h / 8
        var pixels = Array(repeating: false, count: w * h)
        guard data.count >= expectedBytes else { return nil }
        let bytes = [UInt8](data)
        // Flipper sends 1024 bytes: 8 pages of 128 columns, LSB = top pixel of page.
        for page in 0..<(h / 8) {
            for x in 0..<w {
                let idx = page * w + x
                let b = bytes[idx]
                for bit in 0..<8 {
                    let y = page * 8 + bit
                    if (b >> bit) & 1 == 1 { pixels[y * w + x] = true }
                }
            }
        }
        return pixels
    }

    private func publishStreaming(_ value: Bool) {
        if Thread.isMainThread {
            streaming = value
        } else {
            DispatchQueue.main.async { [weak self] in self?.streaming = value }
        }
    }

    private func publishScreenFrame(_ pixels: [Bool]) {
        var shouldSchedule = false
        frameDeliveryLock.lock()
        pendingPixels = pixels
        if !frameDeliveryScheduled {
            frameDeliveryScheduled = true
            shouldSchedule = true
        }
        frameDeliveryLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.deliverPendingScreenFrame() }
    }

    private func deliverPendingScreenFrame() {
        frameDeliveryLock.lock()
        let pixels = pendingPixels
        pendingPixels = nil
        if pixels == nil { frameDeliveryScheduled = false }
        frameDeliveryLock.unlock()

        guard let pixels else { return }
        screenPixels = pixels

        frameDeliveryLock.lock()
        let needsAnotherDelivery = pendingPixels != nil
        if !needsAnotherDelivery { frameDeliveryScheduled = false }
        frameDeliveryLock.unlock()

        if needsAnotherDelivery {
            DispatchQueue.main.async { [weak self] in self?.deliverPendingScreenFrame() }
        }
    }
}
