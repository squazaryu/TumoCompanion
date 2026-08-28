import SwiftUI

/// A destination that can live as a tile on the Home screen (and double as a deep-link route).
enum HomeTileID: String, Codable, CaseIterable, Identifiable, Hashable {
    case info, apps, files, airadar, wifi, fieldServices, spectrum, relay, tumonet, esp32, updates, backup, remotes, media, screen
    // Source-specific routes live in the Home navigation stack but are not
    // configurable dashboard tiles.
    case firmware, packages, communityApps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .info:    return "Info"
        case .apps:    return "Apps"
        case .files:   return "Files"
        case .airadar: return "AI Radar"
        case .wifi:    return "TumoSurvey"
        case .fieldServices: return "Field Services"
        case .spectrum: return "TumoSpectrum"
        case .relay:   return "Relay"
        case .tumonet: return "TumoNet"
        case .esp32:   return "ESP32"
        case .updates: return "Updates"
        case .backup:  return "Backup"
        case .remotes: return "Remotes"
        case .media:   return "Media"
        case .screen:  return "Remote"
        case .firmware: return "Firmware"
        case .packages: return "Firmware packages"
        case .communityApps: return "Community apps"
        }
    }

    var systemImage: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .apps:    return "square.grid.2x2.fill"
        case .files:   return "folder.fill"
        case .airadar: return "chart.bar.xaxis"
        case .wifi:    return "wifi"
        case .fieldServices: return "location.viewfinder"
        case .spectrum: return "waveform.path.ecg"
        case .relay:   return "antenna.radiowaves.left.and.right"
        case .tumonet: return "point.3.connected.trianglepath.dotted"
        case .esp32:   return "cpu"
        case .updates: return "arrow.triangle.2.circlepath"
        case .backup:  return "externaldrive.badge.timemachine"
        case .remotes: return "dot.radiowaves.right"
        case .media:   return "music.note"
        case .screen:  return "rectangle.on.rectangle"
        case .firmware: return "cpu"
        case .packages: return "shippingbox"
        case .communityApps: return "square.grid.2x2"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return Theme.info
        case .apps:    return Theme.indigo
        case .files:   return Theme.cyan
        case .airadar: return Theme.success
        case .wifi:    return Theme.mint
        case .fieldServices: return Theme.info
        case .spectrum: return Theme.accent
        case .relay:   return Theme.danger
        case .tumonet: return Theme.accent
        case .esp32:   return Theme.pink
        case .updates: return Theme.teal
        case .backup:  return Theme.purple
        case .remotes: return Theme.accent
        case .media:   return Theme.pink
        case .screen:  return Theme.teal
        case .firmware: return Theme.accent
        case .packages: return Theme.info
        case .communityApps: return Theme.indigo
        }
    }

    /// Source routes must never appear in Home layout or Quick Access settings.
    var isDashboardTile: Bool {
        switch self {
        case .firmware, .packages, .communityApps, .esp32: return false
        default: return true
        }
    }

    var spec: DashTileSpec { DashTileSpec(title: title, systemImage: systemImage, tint: tint) }
}

struct HomeToolSpec: Identifiable {
    let id: HomeTileID
    let title: String
    let systemImage: String
    let tint: Color
}

enum HomeToolCatalog {
    static let all: [HomeToolSpec] = [
        .init(id: .fieldServices, title: "Field Services", systemImage: "iphone.and.arrow.forward", tint: Theme.info),
        .init(id: .wifi, title: "WiFi Survey", systemImage: "wifi", tint: Theme.teal),
        .init(id: .airadar, title: "AI Radar", systemImage: "dot.radiowaves.left.and.right", tint: Theme.purple),
        .init(id: .spectrum, title: "Spectrum", systemImage: "waveform.path.ecg", tint: Theme.accent),
        .init(id: .relay, title: "Relay", systemImage: "switch.2", tint: Theme.success),
        .init(id: .tumonet, title: "TumoNet", systemImage: "network", tint: Theme.indigo),
        .init(id: .remotes, title: "Remotes", systemImage: "switch.2", tint: Theme.cyan),
        .init(id: .media, title: "Media Remote", systemImage: "play.rectangle", tint: Theme.mint)
    ]

    static let ids = all.map(\.id)
}

/// The three collapsible sections on Home.
enum HomeGroupID: String, Codable, CaseIterable, Identifiable {
    case info, tools, revision
    var id: String { rawValue }

    var name: String {
        switch self {
        case .info:     return "Info"
        case .tools:    return "Tools"
        case .revision: return "Revision"
        }
    }

    var systemImage: String {
        switch self {
        case .info:     return "info.circle"
        case .tools:    return "wrench.and.screwdriver"
        case .revision: return "clock.arrow.circlepath"
        }
    }
}

private struct HomeLayoutData: Codable {
    var info: [String]
    var tools: [String]
    var revision: [String]
    var hidden: [String]
    var collapsed: [String]

    static var `default`: HomeLayoutData {
        .init(info: ["info", "apps", "files"],
              tools: ["airadar", "wifi", "fieldServices", "spectrum", "relay", "tumonet"],
        revision: ["updates", "backup", "remotes", "screen"],
              hidden: [],
              collapsed: [])
    }
}

/// Persisted, user-editable Home layout: which tiles sit in which group, their order,
/// what's hidden, and which groups are collapsed. Edited from `CustomizeHomeView`,
/// rendered by `DevicesView`.
final class HomeLayoutStore: ObservableObject {
    static let shared = HomeLayoutStore()
    private let key = "home.layout.v1"
    private let quickAccessKey = "home.quickAccess.v1"
    private let toolsQuickAccessKey = "home.toolsQuickAccess.v1"
    let quickAccessLimit = 4
    let toolsQuickAccessLimit = 6

    @Published private(set) var order: [HomeGroupID: [HomeTileID]] = [:]
    @Published private(set) var hidden: [HomeTileID] = []
    @Published private(set) var collapsed: Set<HomeGroupID> = []
    @Published private(set) var quickAccess: [HomeTileID] = []
    @Published private(set) var toolsQuickAccess: [HomeTileID] = []

    private init() {
        load()
        loadQuickAccess()
        loadToolsQuickAccess()
    }

    // MARK: - Reads

    func tiles(_ group: HomeGroupID) -> [HomeTileID] { order[group] ?? [] }
    func isExpanded(_ group: HomeGroupID) -> Bool { !collapsed.contains(group) }
    var quickAccessTiles: [HomeTileID] { quickAccess }
    var toolsQuickAccessTiles: [HomeToolSpec] {
        toolsQuickAccess.compactMap { tile in HomeToolCatalog.all.first { $0.id == tile } }
    }
    var toolsQuickAccessIDs: [HomeTileID] { toolsQuickAccess }
    var toolCandidates: [HomeToolSpec] { HomeToolCatalog.all }

    var quickAccessCandidates: [HomeTileID] {
        var candidates = tiles(.tools) + [.files, .apps, .backup] + quickAccess
        var seen = Set<HomeTileID>()
        candidates.removeAll { tile in
            tile == .info || tile == .screen || tile == .remotes || !seen.insert(tile).inserted
        }
        return candidates
    }

    func isQuickAccess(_ tile: HomeTileID) -> Bool { quickAccess.contains(tile) }
    func canAddQuickAccess(_ tile: HomeTileID) -> Bool {
        !isQuickAccess(tile) && quickAccess.count < quickAccessLimit
    }

    // MARK: - Mutations (each persists)

    func toggle(_ group: HomeGroupID) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        save()
    }

    func reorder(_ group: HomeGroupID, from source: IndexSet, to dest: Int) {
        var arr = order[group] ?? []
        arr.move(fromOffsets: source, toOffset: dest)
        order[group] = arr
        save()
    }

    func move(_ tile: HomeTileID, to group: HomeGroupID) {
        removeEverywhere(tile)
        order[group, default: []].append(tile)
        save()
    }

    func hide(_ tile: HomeTileID) {
        removeEverywhere(tile)
        hidden.append(tile)
        save()
    }

    func unhide(_ tile: HomeTileID, to group: HomeGroupID) {
        removeEverywhere(tile)
        order[group, default: []].append(tile)
        save()
    }

    func reset() { apply(.default); save() }

    func toggleQuickAccess(_ tile: HomeTileID) {
        if isQuickAccess(tile) {
            quickAccess.removeAll { $0 == tile }
        } else if quickAccess.count < quickAccessLimit {
            quickAccess.append(tile)
        }
        saveQuickAccess()
    }

    func reorderQuickAccess(from source: IndexSet, to destination: Int) {
        quickAccess.move(fromOffsets: source, toOffset: destination)
        saveQuickAccess()
    }

    func resetQuickAccess() {
        quickAccess = Self.defaultQuickAccess
        saveQuickAccess()
    }

    func isToolQuickAccess(_ tile: HomeTileID) -> Bool {
        toolsQuickAccess.contains(tile)
    }

    func canAddToolQuickAccess(_ tile: HomeTileID) -> Bool {
        HomeToolCatalog.ids.contains(tile)
            && !isToolQuickAccess(tile)
            && toolsQuickAccess.count < toolsQuickAccessLimit
    }

    func toggleToolQuickAccess(_ tile: HomeTileID) {
        if isToolQuickAccess(tile) {
            toolsQuickAccess.removeAll { $0 == tile }
        } else if canAddToolQuickAccess(tile) {
            toolsQuickAccess.append(tile)
        }
        saveToolsQuickAccess()
    }

    func reorderToolQuickAccess(from source: IndexSet, to destination: Int) {
        toolsQuickAccess.move(fromOffsets: source, toOffset: destination)
        saveToolsQuickAccess()
    }

    func resetToolsQuickAccess() {
        toolsQuickAccess = Array(HomeToolCatalog.ids.prefix(toolsQuickAccessLimit))
        saveToolsQuickAccess()
    }

    private func removeEverywhere(_ tile: HomeTileID) {
        for g in HomeGroupID.allCases { order[g]?.removeAll { $0 == tile } }
        hidden.removeAll { $0 == tile }
    }

    // MARK: - Persistence

    private func load() {
        let raw = UserDefaults.standard.data(forKey: key) ?? Data()
        let data = (try? JSONDecoder().decode(HomeLayoutData.self, from: raw)) ?? .default
        apply(data)
    }

    private func apply(_ data: HomeLayoutData) {
        func ids(_ a: [String]) -> [HomeTileID] {
            a.compactMap { HomeTileID(rawValue: $0) }.filter(\.isDashboardTile)
        }
        var o: [HomeGroupID: [HomeTileID]] = [
            .info: ids(data.info), .tools: ids(data.tools), .revision: ids(data.revision)
        ]
        var hid = ids(data.hidden)
        // De-dupe across groups + hidden; ensure every known tile appears exactly once so
        // a tile added in a future version still shows up (defaults into Tools).
        var seen = Set<HomeTileID>()
        for g in HomeGroupID.allCases { o[g] = (o[g] ?? []).filter { seen.insert($0).inserted } }
        hid = hid.filter { seen.insert($0).inserted }
        for t in HomeTileID.allCases where t.isDashboardTile && !seen.contains(t) {
            // Remote belongs with revision/device state rather than the long tools list.
            let group: HomeGroupID = t == .screen ? .revision : .tools
            o[group, default: []].append(t); seen.insert(t)
        }
        order = o
        hidden = hid
        collapsed = Set(data.collapsed.compactMap { HomeGroupID(rawValue: $0) })
    }

    private static let defaultQuickAccess: [HomeTileID] = [.files, .apps, .backup]

    private func loadQuickAccess() {
        guard let raw = UserDefaults.standard.data(forKey: quickAccessKey),
              let decoded = try? JSONDecoder().decode([String].self, from: raw) else {
            quickAccess = Self.defaultQuickAccess
            return
        }
        quickAccess = normalizeQuickAccess(decoded.compactMap { HomeTileID(rawValue: $0) })
    }

    private func normalizeQuickAccess(_ tiles: [HomeTileID]) -> [HomeTileID] {
        var seen = Set<HomeTileID>()
        return tiles.filter { tile in
            guard tile.isDashboardTile,
                  tile != .info,
                  tile != .screen,
                  tile != .remotes,
                  seen.insert(tile).inserted else { return false }
            return true
        }.prefix(quickAccessLimit).map { $0 }
    }

    private func saveQuickAccess() {
        let raw = quickAccess.map(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: quickAccessKey)
        }
    }

    private func loadToolsQuickAccess() {
        guard let raw = UserDefaults.standard.data(forKey: toolsQuickAccessKey),
              let decoded = try? JSONDecoder().decode([String].self, from: raw) else {
            toolsQuickAccess = Array(HomeToolCatalog.ids.prefix(toolsQuickAccessLimit))
            return
        }
        toolsQuickAccess = normalizeToolsQuickAccess(decoded.compactMap { HomeTileID(rawValue: $0) })
    }

    private func normalizeToolsQuickAccess(_ tiles: [HomeTileID]) -> [HomeTileID] {
        var seen = Set<HomeTileID>()
        return tiles.filter { tile in
            guard HomeToolCatalog.ids.contains(tile),
                  tile != .backup,
                  seen.insert(tile).inserted else { return false }
            return true
        }.prefix(toolsQuickAccessLimit).map { $0 }
    }

    private func saveToolsQuickAccess() {
        let raw = toolsQuickAccess.map(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: toolsQuickAccessKey)
        }
    }

    private func save() {
        func raw(_ a: [HomeTileID]) -> [String] { a.map(\.rawValue) }
        let data = HomeLayoutData(
            info: raw(order[.info] ?? []),
            tools: raw(order[.tools] ?? []),
            revision: raw(order[.revision] ?? []),
            hidden: raw(hidden),
            collapsed: collapsed.map(\.rawValue))
        if let d = try? JSONEncoder().encode(data) { UserDefaults.standard.set(d, forKey: key) }
    }
}
