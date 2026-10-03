import Foundation

/// Keep bounded read memory while draining the server's remaining response frames.
struct RPCReadBudget {
    let maximumBytes: Int
    private(set) var acceptedBytes = 0
    private(set) var exceeded = false
    private var frames = 0

    mutating func accept(_ bytes: Int) -> Bool {
        let maximumFrames = maximumBytes == Int.max ? Int.max :
            max(128, min(131_072, max(0, maximumBytes) / 256 + 129))
        guard !exceeded, maximumBytes >= 0, bytes >= 0,
              bytes <= maximumBytes - acceptedBytes, frames < maximumFrames else {
            exceeded = true
            return false
        }
        acceptedBytes += bytes; frames += 1
        return true
    }
}
