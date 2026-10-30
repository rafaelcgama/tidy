#!/bin/bash
# Builds build/Tidy.app (the app, the tidy CLI, the helper, the icon, and a code signature) and
# build/Tidy.dmg, the disk image you install from: open it and drag Tidy onto Applications.
#
#   scripts/make-app.sh
#       Apple silicon + Intel build, signed ad hoc so it runs on this Mac.
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/make-app.sh
#       Signed for distribution, with the hardened runtime. The disk image is signed too.
#   DEVELOPER_ID=… NOTARY_PROFILE=tidy scripts/make-app.sh
#       Also notarized and stapled, the app and the disk image (create the profile with
#       `xcrun notarytool store-credentials`).
#
# The disk image opens by itself when the build is done; set NO_OPEN=1 to skip that.
# BUNDLE_ID (default com.example.tidy) and VERSION (default: the VERSION file) can be set as well. Choose your
# own reverse-DNS bundle id before sharing builds: settings and macOS permissions are tied to it.
set -euo pipefail
cd "$(dirname "$0")/.."
# What this prints is saved in build/make-app-log.txt too, so it can be read back.
mkdir -p build
exec > >(tee build/make-app-log.txt) 2>&1

BUNDLE_ID="${BUNDLE_ID:-com.example.tidy}"
VERSION="${VERSION:-$(cat VERSION)}"
# The build number is the date and time in UTC, so builds made on any Mac or on GitHub sort in order.
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
APP="build/Tidy.app"

echo "Building for Apple silicon and Intel…"
if swift build -c release --arch arm64 --arch x86_64; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    echo "The universal build needs Xcode (not only the Command Line Tools). Building for this Mac only." >&2
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/TidyApp" "$APP/Contents/MacOS/Tidy"
cp "$BIN/TidyHelper" "$APP/Contents/MacOS/TidyHelper"
cp "$BIN/tidy" "$APP/Contents/Helpers/tidy"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" Resources/Helper.plist \
    > "$APP/Contents/Library/LaunchDaemons/$BUNDLE_ID.helper.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# libyara's licenses travel with the app.
cp Sources/CYara/NOTICE.md "$APP/Contents/Resources/libyara-NOTICE.md"
cp Sources/CYara/LICENSE-APACHE-2.0 "$APP/Contents/Resources/libyara-LICENSE-APACHE-2.0.txt"

if [ -n "${DEVELOPER_ID:-}" ]; then
    SIGN=(codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID")
else
    SIGN=(codesign --force --sign -)
fi
# Inside out: the nested programs first, then the app around them. The app only talks to a helper
# signed as $BUNDLE_ID.helper by the same team, and the helper only to the app.
"${SIGN[@]}" --identifier "$BUNDLE_ID.helper" "$APP/Contents/MacOS/TidyHelper"
"${SIGN[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/tidy"
# The hardened runtime lets the app ask Finder to open the Trash only with this entitlement.
"${SIGN[@]}" --entitlements Resources/Tidy.entitlements "$APP"
codesign --verify --strict "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${DEVELOPER_ID:-}" ]; then
        echo "Notarizing needs DEVELOPER_ID as well." >&2
        exit 1
    fi
    ditto -c -k --keepParent "$APP" build/Tidy.zip
    xcrun notarytool submit build/Tidy.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/Tidy.zip
fi

# The disk image: Tidy.app next to a shortcut to /Applications, the usual drag-to-install window.
DMG="build/Tidy.dmg"
STAGE="build/dmg"
echo "Making ${DMG}…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tidy.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tidy" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Built $APP and $DMG (version $VERSION, $BUNDLE_ID)."
echo "To install: open $DMG and drag Tidy onto Applications."
if [ -z "${NO_OPEN:-}" ]; then
    open "$DMG"
fi
