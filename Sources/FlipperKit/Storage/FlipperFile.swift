import Foundation

struct FlipperFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt32
}
