#!/bin/bash
# Regenerate Swift protobuf types from the Unleashed firmware .proto files.
# Run this if you bump the firmware / RPC protocol.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH="/opt/homebrew/bin:$PATH"

FW="${1:-../unleashed-firmware}"
FW="$(cd "$FW" && pwd -P)"
PROTO="$FW/assets/protobuf"
NANOPB="$FW/lib/nanopb/generator/proto"
OUT="Sources/Proto"

PROTO_PATHS=(--proto_path="$PROTO" --proto_path="$NANOPB")
STORAGE_PROTO="$PROTO/storage.proto"
if [[ -f "$FW/assets/protobuf_overrides/storage.proto" ]]; then
  PROTO_PATHS=(--proto_path="$FW/assets/protobuf_overrides" "${PROTO_PATHS[@]}")
  STORAGE_PROTO="$FW/assets/protobuf_overrides/storage.proto"
fi
if [[ "${2:-}" == "--storage-only" ]]; then
  SOURCES=("$STORAGE_PROTO")
elif [[ -z "${2:-}" ]]; then
  SOURCES=("$PROTO/flipper.proto" "$STORAGE_PROTO" "$PROTO/system.proto"
           "$PROTO/application.proto" "$PROTO/gui.proto" "$PROTO/gpio.proto"
           "$PROTO/property.proto" "$PROTO/desktop.proto")
else
  echo "Usage: $0 [firmware-root] [--storage-only]" >&2
  exit 2
fi

protoc \
  "${PROTO_PATHS[@]}" \
  --swift_opt=Visibility=Public --swift_out="$OUT" \
  "${SOURCES[@]}"

echo "Regenerated Swift protobuf in $OUT"
