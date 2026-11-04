#!/bin/zsh
# Builds a Release of Glint, zips it, signs the zip for Sparkle and adds it to appcast.xml.
# Before running: raise MARKETING_VERSION (e.g. 0.2) and CURRENT_PROJECT_VERSION (+1) in Xcode,
# and add release notes to CHANGELOG.md. See docs/RELEASING.md.
# Optional: NOTARY_PROFILE=<notarytool keychain profile> notarizes the app (needs a Developer ID certificate).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=TheOnlyKuhni/Glint
DERIVED=build/DerivedData

# The generic destination builds for Apple silicon and Intel; without it, only for this Mac's architecture.
xcodebuild -project Glint.xcodeproj -scheme Glint -configuration Release -derivedDataPath $DERIVED \
  -destination 'generic/platform=macOS' -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP=$DERIVED/Build/Products/Release/Glint.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ -n $KEY ]] || { echo "SUPublicEDKey is empty in Config/Info.plist. See docs/RELEASING.md."; exit 1; }
if grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml; then
  echo "Build $BUILD is already in appcast.xml. Raise CURRENT_PROJECT_VERSION first."; exit 1
fi

mkdir -p releases
ZIP=releases/Glint-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

SPARKLE_BIN=$(find $DERIVED/SourcePackages/artifacts -type d -path "*Sparkle/bin" | head -1)
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/Glint-$VERSION.zip"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

python3 - "$VERSION" "$BUILD" "$URL" "$SIGNATURE" "$DATE" <<'PY'
import sys
version, build, url, signature, date = sys.argv[1:]
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/TheOnlyKuhni/Glint/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {signature}/>
    </item>
"""
path = "appcast.xml"
text = open(path).read()
marker = "    <language>en</language>\n"
assert marker in text
open(path, "w").write(text.replace(marker, marker + item, 1))
PY

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
cat <<NEXT

Built $ZIP (version $VERSION, build $BUILD)
sha256: $SHA

Next:
  1. gh release create v$VERSION "$ZIP" --repo $REPO --title "Glint $VERSION" --notes "See CHANGELOG.md"
  2. git add appcast.xml && git commit -m "Release $VERSION" && git push
     (push after the release exists, so the feed never points at a missing file)
  3. Homebrew tap: set version "$VERSION" and sha256 "$SHA" in Casks/glint.rb
NEXT
