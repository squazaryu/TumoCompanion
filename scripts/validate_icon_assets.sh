#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
failed=0
for icon in AppIcon-Purple AppIcon-Mono; do
    path="$root/Resources/Assets.xcassets/$icon.appiconset/icon.png"
    alpha=$(sips -g hasAlpha "$path" 2>/dev/null | awk '/hasAlpha/ { print $2 }')
    if [ "$alpha" != "yes" ]; then
        echo "ERROR: $icon must contain an alpha channel (hasAlpha=$alpha)" >&2
        failed=1
    else
        echo "OK: $icon has alpha"
    fi
done
exit "$failed"
