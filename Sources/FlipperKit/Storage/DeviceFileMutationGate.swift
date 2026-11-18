import Foundation

/// App-side BLE filesystem exclusion, not a global lock against on-device/USB writers.
/// Ordinary mutations remain concurrent as before unless a checked user edit owns
/// the lease. The lease cannot begin in the middle of an existing streaming write.
enum DeviceFileMutationGate {
  enum Failure: LocalizedError {
    case busy
    var errorDescription: String? {
      "Another device file operation is active. Wait for it to finish."
    }
  }
  @TaskLocal private static var token: UUID?
  private actor State {
    var owner: UUID?
    var active = 0
    var closing = false
    func acquire(_ id: UUID) throws {
      guard owner == nil, active == 0 else { throw Failure.busy }
      owner = id
    }
    func release(_ id: UUID) {
      guard owner == id else { return }
      if active == 0 { owner = nil } else { closing = true }
    }
    func begin(_ id: UUID?) throws {
      guard !closing, owner == nil || owner == id else { throw Failure.busy }
      active += 1
    }
    func end() {
      active -= 1
      if active == 0 && closing {
        owner = nil
        closing = false
      }
    }
  }
  private static let state = State()

  static func withLease<T>(_ body: () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let id = UUID()
    try await state.acquire(id)
    do {
      let result = try await $token.withValue(id) { try await body() }
      await state.release(id)
      return result
    } catch {
      await state.release(id)
      throw error
    }
  }
  static func withMutation<T>(_ body: () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    try await state.begin(token)
    do {
      let result = try await body()
      await state.end()
      return result
    } catch {
      await state.end()
      throw error
    }
  }
}
