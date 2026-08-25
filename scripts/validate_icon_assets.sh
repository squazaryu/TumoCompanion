#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
failed=0
for icon in AppIcon-Purple AppIcon-Mono; do
    path="$root/Resources/Assets.xcassets/$icon.appiconset/icon.png"
    alpha=$(sips -g hasAlpha "$path" 2>/dev/null | awk '/hasAlpha/ { print $2 }')
    width=$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
    height=$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ { print $2 }')
    if [ "$alpha" != "yes" ] || [ "$width" != "1024" ] || [ "$height" != "1024" ]; then
        echo "ERROR: $icon must be a 1024x1024 alpha-safe PNG (size=${width}x${height}, hasAlpha=$alpha)" >&2
        failed=1
    else
        echo "OK: $icon is 1024x1024 with alpha"
    fi
done
exit "$failed"
