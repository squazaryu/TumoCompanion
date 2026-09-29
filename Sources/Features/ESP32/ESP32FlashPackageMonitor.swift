import CryptoKit
import Foundation
import UserNotifications

/// Watches published Marauder release inventories for a verified Flash Package
/// transition on boards previously discovered in the foreground.
enum ESP32FlashPackageMonitor {
    static let knownBoardsKey = "esp32KnownBoardKeys"
    private static let observationsKey = "esp32FlashPlanObservationsV1"
    private static let repo = "justcallmekoko/ESP32Marauder"

    struct Asset {
        let id: Int64
        let name: String
        let size: Int
        let digest: String?
        let url: URL?
    }

    struct Release {
        let id: Int64
        let tag: String
        let assets: [String: Asset]

        var carrier: Asset? {
            assets["firmware-manifest.json"] ?? assets["marauder-installer-assets.zip"]
        }

        var inventory: String {
            guard let carrier else { return "none" }
            return "\(id):\(tag):\(carrier.id):\(carrier.size):\(carrier.digest ?? "missing")"
        }
    }

    static func rememberBoards(_ boardKeys: Set<String>, defaults: UserDefaults = .standard) {
        let supported = boardKeys.filter(ESP32Updater.automaticPackageSupported(for:)).sorted()
        defaults.set(supported, forKey: knownBoardsKey)
    }

    static func observation(
        releaseID: Int64,
        boardKey: String,
        defaults: UserDefaults = .standard
    ) -> ESP32FlashObservation? {
        loadObservations(defaults)["\(releaseID):\(boardKey)"]
    }

    /// A changed accepted recipe cannot be staged silently, even if the
    /// background refresh has not run since the asset inventory changed.
    static func requiresReview(
        releaseID: Int64,
        boardKey: String,
        inventory: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let previous = observation(releaseID: releaseID, boardKey: boardKey, defaults: defaults) else {
            return false
        }
        if previous.disposition == .reviewRequired { return true }
        return previous.inventory != inventory &&
            (previous.disposition == .eligible || previous.disposition == .unverified)
    }

    static func check(defaults: UserDefaults = .standard) async -> Bool {
        let known = Set(defaults.stringArray(forKey: knownBoardsKey) ?? [])
            .filter(ESP32Updater.automaticPackageSupported(for:))
        guard !known.isEmpty else { return true }
        do {
            let releases = try await publishedReleases()
            return await reconcile(
                defaults: defaults, releases: releases, knownBoards: known,
                resolve: resolvedPlanFingerprint, deliver: deliver)
        } catch {
            return false
        }
    }

    /// Injectable transition core. A new release/board pair is a silent
    /// baseline, and unchanged asset inventory never downloads the ZIP again.
    static func reconcile(
        defaults: UserDefaults,
        releases: [Release],
        knownBoards: Set<String>,
        resolve: (Release, String) async throws -> String?,
        deliver: (Release, String) async throws -> Void
    ) async -> Bool {
        var states = loadObservations(defaults)
        var allSucceeded = true
        for release in releases {
            for board in knownBoards.sorted() where ESP32Updater.automaticPackageSupported(for: board) {
                let key = "\(release.id):\(board)"
                let previous = states[key]
                if previous?.inventory == release.inventory { continue }
                if previous == nil || release.carrier == nil ||
                   previous?.disposition == .eligible ||
                   previous?.disposition == .unverified ||
                   previous?.disposition == .reviewRequired {
                    states[key] = ESP32FlashTransition.evaluate(
                        previous: previous, inventory: release.inventory,
                        verifiedPlan: nil).state
                    continue
                }
                do {
                    let fingerprint = try await resolve(release, board)
                    let decision = ESP32FlashTransition.evaluate(
                        previous: previous, inventory: release.inventory,
                        verifiedPlan: fingerprint)
                    if decision.notify { try await deliver(release, board) }
                    states[key] = decision.state
                } catch is CancellationError {
                    allSucceeded = false
                } catch is URLError {
                    allSucceeded = false
                } catch is GitHubAPIError {
                    allSucceeded = false
                } catch is UpdateNotificationError {
                    allSucceeded = false
                } catch {
                    states[key] = ESP32FlashTransition.evaluate(
                        previous: previous, inventory: release.inventory,
                        verifiedPlan: nil).state
                }
            }
        }
        if let encoded = try? JSONEncoder().encode(states) {
            defaults.set(encoded, forKey: observationsKey)
        } else {
            allSucceeded = false
        }
        return allSucceeded
    }

    private static func loadObservations(_ defaults: UserDefaults) -> [String: ESP32FlashObservation] {
        guard let data = defaults.data(forKey: observationsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ESP32FlashObservation].self, from: data)) ?? [:]
    }

    private static func publishedReleases() async throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        let response = try await GitHubAPIClient.shared.data(
            from: url, maxAge: 20 * 60, allowStaleOnError: false)
        guard let raw = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
            throw GitHubAPIError.invalidJSON
        }
        return raw.compactMap(decodeRelease).prefix(20).map { $0 }
    }

    static func decodeRelease(_ object: [String: Any]) -> Release? {
        guard object["draft"] as? Bool == false,
              object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String, tag.hasPrefix("v"),
              let releaseID = (object["id"] as? NSNumber)?.int64Value else {
            return nil
        }
        var assets: [String: Asset] = [:]
        for item in (object["assets"] as? [[String: Any]]) ?? [] {
            guard let name = item["name"] as? String,
                  let id = (item["id"] as? NSNumber)?.int64Value,
                  let size = (item["size"] as? NSNumber)?.intValue,
                  assets[name] == nil else { continue }
            let digest = (item["digest"] as? String).flatMap { value -> String? in
                value.lowercased().hasPrefix("sha256:")
                    ? String(value.dropFirst("sha256:".count)) : nil
            }
            let url = (item["browser_download_url"] as? String).flatMap(URL.init(string:))
            assets[name] = Asset(id: id, name: name, size: size, digest: digest, url: url)
        }
        return Release(id: releaseID, tag: tag, assets: assets)
    }

    private static func resolvedPlanFingerprint(
        release: Release,
        boardKey: String
    ) async throws -> String? {
        // C5's ZIP-based boot recipe still needs its separate hardware gate.
        guard boardKey == "v6_1", let carrier = release.carrier else { return nil }
        let carrierData = try await verifiedDownload(carrier, maximumSize: 64 * 1024 * 1024)
        let manifest: ESP32InstallerManifest
        let zip: ESP32InstallerZIP?
        if carrier.name == "marauder-installer-assets.zip" {
            guard let digest = carrier.digest else { return nil }
            let opened = try ESP32InstallerZIP(
                data: carrierData, expectedSize: carrier.size, expectedSHA256: digest)
            manifest = try ESP32Updater.decodeManifest(
                opened.manifestData, expectedVersion: release.tag)
            let all = manifest.targets.flatMap { $0.flash.factory.segments }
            let names = Set(all.map(\.fileName))
            guard names.count == all.count else { return nil }
            try opened.verifyEntries(expectedSegmentNames: names)
            zip = opened
        } else {
            manifest = try ESP32Updater.decodeManifest(
                carrierData, expectedVersion: release.tag)
            zip = nil
        }
        _ = try ESP32Updater.packageBoard(for: boardKey, manifest: manifest)
        let allSegments = manifest.targets.flatMap { $0.flash.factory.segments }
        var sizes = Dictionary(uniqueKeysWithValues: release.assets.map { ($0.key, $0.value.size) })
        var digests = Dictionary(uniqueKeysWithValues: release.assets.compactMap { key, value in
            value.digest.map { (key, $0) }
        })
        if zip != nil {
            for segment in allSegments {
                sizes[segment.fileName] = segment.size
                digests[segment.fileName] = segment.sha256
            }
        }
        let selected = try ESP32Updater.factorySegments(
            for: boardKey, manifest: manifest,
            assetSizes: sizes, assetSHA256: digests)
        for segment in selected {
            if let zip {
                _ = try zip.verifiedData(
                    name: segment.fileName, size: segment.size, sha256: segment.sha256)
            } else {
                guard let asset = release.assets[segment.fileName] else { return nil }
                _ = try await verifiedDownload(asset, maximumSize: 16 * 1024 * 1024)
            }
        }
        let manifestHash = sha256(zip?.manifestData ?? carrierData)
        let componentList = selected.map {
            "\($0.offset):\($0.size):\($0.fileName):\($0.sha256.lowercased())"
        }.joined(separator: "|")
        return sha256(Data(
            "\(release.id)|\(release.tag)|\(carrier.id)|\(carrier.size)|\(carrier.digest ?? "")|\(manifestHash)|\(boardKey)|\(componentList)".utf8))
    }

    private static func verifiedDownload(_ asset: Asset, maximumSize: Int) async throws -> Data {
        guard asset.size > 0, asset.size <= maximumSize,
              let digest = asset.digest, digest.utf8.count == 64,
              let url = asset.url, url.scheme == "https", url.host == "github.com" else {
            throw ESP32InstallerZIPError.carrierMismatch
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let size = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == asset.size else {
            throw ESP32InstallerZIPError.carrierMismatch
        }
        let data = try Data(contentsOf: temporaryURL)
        guard sha256(data).caseInsensitiveCompare(digest) == .orderedSame else {
            throw ESP32InstallerZIPError.carrierMismatch
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func deliver(_ release: Release, _ boardKey: String) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: throw UpdateNotificationError.notificationsDisabled
        }
        let content = UNMutableNotificationContent()
        content.title = "Verified ESP32 Flash Package available"
        content.body = "\(release.tag) has a verified package for \(boardKey). Open ESP32 Firmware to review it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "esp32-flash-\(release.id)-\(boardKey)",
            content: content, trigger: nil)
        try await center.add(request)
    }
}
