#!/bin/zsh
# Builds a release of linger: a notarized DMG for first installs (AirDrop, a link) and a signed zip
# plus appcast entry for Sparkle updates. Publishing stays manual; the script prints the commands.
#
#   scripts/release.sh 1.1 --notes "Work hours and long breaks."
#   scripts/release.sh 1.1 --unnotarized      # Apple Development signed, for a friend's Mac only
#
# One-time setup:
#   - A "Developer ID Application" certificate in your keychain (Xcode → Settings → Accounts).
#   - xcrun notarytool store-credentials linger-notary --apple-id <you> --team-id <team>
#   - The Sparkle EdDSA private key in your keychain (generate_keys has already been run once).

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=""
NOTES=""
NOTARIZE=1
while (( $# )); do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --unnotarized) NOTARIZE=0; shift ;;
    -*) echo "Unknown option $1" >&2; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done
[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <version> [--notes text] [--unnotarized]" >&2; exit 1; }

# Sparkle compares build numbers; the commit count only ever goes up.
BUILD=$(git rev-list --count HEAD)
REPO="cranberryrum/linger"
NOTARY_PROFILE="linger-notary"
OUT="build/release/$VERSION"
DD="build/DerivedData"
ARCHIVE="build/linger-$VERSION.xcarchive"
ZIP="$OUT/linger-$VERSION.zip"
DMG="$OUT/linger-$VERSION.dmg"
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: the working tree has uncommitted changes; they will be in this build." >&2
fi

if (( NOTARIZE )); then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [[ -n "$IDENTITY" ]] || {
    echo "No Developer ID Application certificate found. Create one in Xcode → Settings → Accounts" >&2
    echo "(needs a paid Apple Developer membership), or pass --unnotarized for a test build." >&2
    exit 1
  }
  METHOD="developer-id"
else
  METHOD="debugging"
fi

TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' linger.xcodeproj/project.pbxproj | head -1)
rm -rf "$OUT" "$ARCHIVE"
mkdir -p "$OUT"

echo "==> Archiving linger $VERSION ($BUILD)"
xcodebuild -project linger.xcodeproj -scheme linger -configuration Release \
  -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive -quiet

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

echo "==> Exporting ($METHOD)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$OUT/export" -quiet
APP="$OUT/export/linger.app"

if (( NOTARIZE )); then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$OUT/notarize.zip"
fi

echo "==> Zipping the update"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Building the DMG"
# The Applications shortcut matters: an app run from Downloads or the DMG itself is translocated
# by Gatekeeper, and Sparkle can't replace a translocated app.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "linger" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if (( ! NOTARIZE )); then
  echo
  echo "Test build ready: $DMG"
  echo "It isn't notarized: on another Mac, open it, then allow it in System Settings → Privacy & Security."
  echo "It is not added to the appcast."
  exit 0
fi

codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Signing the update for Sparkle"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/linger-$VERSION.zip"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

ITEM="    <item>
      <title>linger $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIGNATURE />
    </item>"

if [[ ! -f appcast.xml ]]; then
  cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>linger</title>
    <language>en</language>
  </channel>
</rss>
EOF
fi
# Newest first, right after the channel header.
ITEM="$ITEM" perl -0pi -e 's|(<language>en</language>\n)|$1$ENV{ITEM}\n|' appcast.xml

echo
echo "Release $VERSION ($BUILD) is ready in $OUT."
echo "Publish in this order, so the feed never points at a missing file:"
echo
echo "  gh release create v$VERSION '$ZIP' '$DMG' --repo $REPO --title 'linger $VERSION' --notes '$NOTES'"
echo "  git add appcast.xml && git commit -m 'Release $VERSION' && git push"
