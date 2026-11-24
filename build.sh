#!/bin/sh
# Builds build/megabass.app (Apple Silicon, ad-hoc signed). Run: ./build.sh && open build/megabass.app
set -e
cd "$(dirname "$0")"
swift build -c release --product MegaBass
app=build/megabass.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -f .build/release/MegaBass "$app/Contents/MacOS/MegaBass"
cp -f Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp -f Resources/AppIcon.icns "$app/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
fi
codesign --force -s - "$app"
echo "built $app"
