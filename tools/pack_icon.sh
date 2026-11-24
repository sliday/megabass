#!/bin/sh
# Packs a 1024x1024 transparent PNG into Resources/AppIcon.icns (all macOS sizes).
# The PNG came from: REPLICATE_API_TOKEN=... uv run tools/replicate_icon.py openai/gpt-image-2.6-sunburst 3 out/ < tools/icon_prompt.txt
# (newest OpenAI image model on Replicate, Nov 2026; check /v1/collections/text-to-image for newer)
# then trimmed to the body and scaled onto Apple's 824/1024 grid.
set -e
cd "$(dirname "$0")/.."
src="${1:-Resources/AppIcon-1024.png}"
set_dir=build/AppIcon.iconset
mkdir -p "$set_dir"
for pt in 16 32 128 256 512; do
    sips -z $pt $pt "$src" --out "$set_dir/icon_${pt}x${pt}.png" >/dev/null
    d=$((pt * 2)); sips -z $d $d "$src" --out "$set_dir/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns from $src"
