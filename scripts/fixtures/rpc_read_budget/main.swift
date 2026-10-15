import Foundation

var ranged = RPCReadBudget(maximumBytes: 3, requireRangedRead: true)
assert(ranged.accept(2, rangeAcknowledged: true))
assert(ranged.accept(1, rangeAcknowledged: true))
assert(!ranged.exceeded && !ranged.rangeUnsupported && ranged.acceptedBytes == 3)
assert(!ranged.accept(1, rangeAcknowledged: true) && ranged.exceeded)

var legacy = RPCReadBudget(maximumBytes: 3, requireRangedRead: true)
assert(!legacy.accept(2, rangeAcknowledged: false))
assert(legacy.rangeUnsupported && !legacy.exceeded && legacy.acceptedBytes == 0)
assert(!legacy.accept(1, rangeAcknowledged: true))
assert(legacy.rangeUnsupported && legacy.acceptedBytes == 0)

var mixed = RPCReadBudget(maximumBytes: 3, requireRangedRead: true)
assert(mixed.accept(1, rangeAcknowledged: true))
assert(!mixed.accept(1, rangeAcknowledged: false))
assert(!mixed.accept(0, rangeAcknowledged: true) && mixed.rangeUnsupported)

var ordinary = RPCReadBudget(maximumBytes: 3)
assert(ordinary.accept(2) && !ordinary.rangeUnsupported)
assert(!ordinary.accept(2) && ordinary.exceeded)
var empty = RPCReadBudget(maximumBytes: 0, requireRangedRead: true)
assert(empty.accept(0, rangeAcknowledged: true))
assert(!empty.accept(0, rangeAcknowledged: false) && empty.rangeUnsupported)

var flood = RPCReadBudget(maximumBytes: 1, requireRangedRead: true)
for _ in 0..<129 { assert(flood.accept(0, rangeAcknowledged: true)) }
assert(!flood.accept(0, rangeAcknowledged: true) && flood.exceeded)
var huge = RPCReadBudget(maximumBytes: Int.max)
assert(huge.accept(Int.max) && !huge.accept(1))
print("RPC range acknowledgement, bounds and legacy read cases passed")
