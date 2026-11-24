#!/bin/sh
# Screenshot the --preview window: scripts/shot.sh out.png [app args...]   (SHOT_WAIT=seconds)
cd "$(dirname "$0")/.."
swiftc -O scripts/winid.swift -o build/winid
out="$1"; shift
build/megabass.app/Contents/MacOS/MegaBass --preview "$@" &
pid=$!
sleep "${SHOT_WAIT:-3}"
wid=$(build/winid megabass $pid | head -1 | cut -d' ' -f1)
screencapture -x -o -l "$wid" "$out"
kill $pid
echo "$out (window $wid)"
