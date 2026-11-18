import CryptoKit
import Foundation

struct PortableObjectCard: Codable, Equatable {
  struct Link: Codable, Equatable, Identifiable {
    var path: String
    var label: String
    var id: String { path }
  }
  var name: String
  var notes: String
  var tags: String
  var checkedAt: String
  var links: [Link]

  func validate() throws {
    guard FieldWire.objectName(name), links.count <= 8,
      notes.utf8.count < 128, tags.utf8.count < 64, checkedAt.utf8.count < 24,
      [notes, tags, checkedAt].allSatisfy(FieldWire.printable),
      Set(links.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count
        == links.count,
      links.allSatisfy({
        FieldWire.linkPath($0.path) && FieldWire.printable($0.label) && $0.label.utf8.count < 32
      })
    else {
      throw FieldWorkflowError.invalid("object name, text, duplicate or unsupported file action")
    }
  }
}

/// Explicit little-endian TOB1 wire codec; never writes a Swift/C memory image.
/// The native importer creates a new card and new payload copies, not in-place edits.
struct PortableObjectDocument: Equatable {
  static let headerSize = 2888
  static let maximumBytes = 32 * 1024 * 1024
  let card: PortableObjectCard
  let files: [String: Data]

  init(card: PortableObjectCard, files: [String: Data]) throws {
    try card.validate()
    guard Set(card.links.map(\.path)) == Set(files.keys),
      files.values.allSatisfy({ $0.count <= 16 * 1024 * 1024 }),
      files.values.reduce(Self.headerSize, { $0 + $1.count }) <= Self.maximumBytes
    else {
      throw FieldWorkflowError.invalid("object payload set or total size")
    }
    self.card = card
    self.files = files
  }

  func encoded() throws -> Data {
    try card.validate()
    var header = Data(repeating: 0, count: Self.headerSize)
    func set(_ bytes: Data, _ offset: Int) {
      header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
    set(FieldWire.littleEndian(0x3142_4F54), 0)
    set(FieldWire.littleEndian(1), 4)
    set(FieldWire.littleEndian(UInt32(Self.headerSize)), 8)
    set(try FieldWire.cString(card.name, capacity: 32), 12)
    set(try FieldWire.cString(card.notes, capacity: 128), 44)
    set(try FieldWire.cString(card.tags, capacity: 64), 172)
    set(try FieldWire.cString(card.checkedAt, capacity: 24), 236)
    set(FieldWire.littleEndian(UInt32(card.links.count)), 2308)
    for (index, link) in card.links.enumerated() {
      guard let payload = files[link.path], payload.count <= 16 * 1024 * 1024 else {
        throw FieldWorkflowError.invalid("missing object payload")
      }
      set(try FieldWire.cString(link.path, capacity: 256), 260 + index * 256)
      set(try FieldWire.cString(link.label, capacity: 32), 2312 + index * 32)
      set(FieldWire.littleEndian(UInt32(payload.count)), 2568 + index * 36)
      set(Data(SHA256.hash(data: payload)), 2572 + index * 36)
    }
    set(Data(SHA256.hash(data: header.prefix(2856))), 2856)
    var result = header
    for link in card.links { result.append(files[link.path]!) }
    guard result.count <= Self.maximumBytes else {
      throw FieldWorkflowError.invalid("object too large")
    }
    return result
  }

  static func decode(_ input: Data) throws -> Self {
    let data = Data(input)
    guard data.count >= headerSize, data.count <= maximumBytes,
      try FieldWire.u32(data, 0) == 0x3142_4F54, try FieldWire.u32(data, 4) == 1,
      try FieldWire.u32(data, 8) == UInt32(headerSize),
      Data(SHA256.hash(data: data.prefix(2856))) == data.subdata(in: 2856..<2888)
    else {
      throw FieldWorkflowError.invalid("object header or digest")
    }
    let count = Int(try FieldWire.u32(data, 2308))
    guard count <= 8 else { throw FieldWorkflowError.invalid("object action count") }
    var links: [PortableObjectCard.Link] = []
    var files: [String: Data] = [:]
    var offset = headerSize
    for index in 0..<count {
      let path = try FieldWire.text(data, 260 + index * 256, 256)
      let label = try FieldWire.text(data, 2312 + index * 32, 32)
      let size = Int(try FieldWire.u32(data, 2568 + index * 36))
      guard FieldWire.linkPath(path), size <= 16 * 1024 * 1024, size <= data.count - offset,
        files[path] == nil
      else {
        throw FieldWorkflowError.invalid("object action, size or duplicate")
      }
      let payload = data.subdata(in: offset..<offset + size)
      guard
        Data(SHA256.hash(data: payload)) == data.subdata(in: 2572 + index * 36..<2604 + index * 36)
      else {
        throw FieldWorkflowError.invalid("object payload digest")
      }
      files[path] = payload
      links.append(.init(path: path, label: label))
      offset += size
    }
    guard offset == data.count else { throw FieldWorkflowError.invalid("object trailing data") }
    let card = try PortableObjectCard(
      name: FieldWire.text(data, 12, 32), notes: FieldWire.text(data, 44, 128),
      tags: FieldWire.text(data, 172, 64), checkedAt: FieldWire.text(data, 236, 24), links: links)
    return try Self(card: card, files: files)
  }
}
