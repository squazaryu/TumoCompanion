# Ranged storage reads

Client counterpart of the Tumoflip Unleashed-094 adaptation (F7 API 88.20).
This change prepares the client API; it does not publish a new iOS version or
change the installer/backup/full-file read behavior.

`FlipperStorage.readRange(path, offset: UInt32, count: UInt32)` requests an
explicit slice, at most 1 MiB per call. Zero count returns empty data without an
RPC request. Offset beyond EOF returns the firmware's empty acknowledged reply.

The wire schema appends request fields 2/3 (`offset`/`size`) and response field 2
(`ranged`). Legacy requests still use zero defaults. Every ranged response must
contain a file and acknowledge the range. Otherwise RPC discards accumulated
data, drains remaining frames while holding its command gate, and reports
`rangedReadUnsupported`. Old firmware cannot silently return a full file as a
slice. Byte/frame limits remain enforced; ordinary reads are unchanged.

Use updated firmware before requesting ranges. Draining an old firmware's full
response can take time; this is not a background BLE keepalive or resume API.
Reads across several requests are not a snapshot if another app changes the file.

Regenerate only the changed binding from the exact firmware checkout:

```sh
scripts/regen_proto.sh /path/to/tumoflip --storage-only
python3 scripts/test_rpc_read_budget_host.py
```

The generator uses the firmware's storage-only overlay when present, not the
unrelated GPS/Network protobuf fork. CI also runs `RPCReadBudgetTests`, including
protobuf round trips, legacy defaults, range acknowledgements and memory bounds.
Real-device compatibility remains a separate acceptance check.
