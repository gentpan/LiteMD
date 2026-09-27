#!/bin/bash
# 构建可分发的 LiteMD：Developer ID 签名 → 公证 → 装订 → DMG（可选：更新包与更新源 JSON）。
#
# 必需的环境变量：
#   TEAM_ID                 Apple Developer Team ID
# 公证（不设置时只签名，不公证）：
#   NOTARY_PROFILE          notarytool 钥匙串配置名（xcrun notarytool store-credentials 创建）
# 应用内更新（三者都设置时才生成更新包与 appcast.json，并把更新源写入应用）：
#   UPDATE_PRIVATE_KEY      更新签名私钥文件（scripts/generate-update-keys.swift 生成）
#   UPDATE_PUBLIC_KEY       对应的公钥（Base64）
#   DOWNLOAD_BASE_URL       安装包下载目录，例如 https://example.com/litemd
# 可选：
#   SIGNING_IDENTITY        默认 "Developer ID Application"
#   RELEASE_NOTES           更新说明 JSON 文件，例如 {"en": "...", "zh-Hans": "..."}
set -euo pipefail

cd "$(dirname "$0")/.."
: "${TEAM_ID:?TEAM_ID is required}"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"

UPDATES=0
if [[ -n "${UPDATE_PRIVATE_KEY:-}" && -n "${UPDATE_PUBLIC_KEY:-}" && -n "${DOWNLOAD_BASE_URL:-}" ]]; then
  UPDATES=1
fi

OUTPUT="build/release"
ARCHIVE="$OUTPUT/LiteMD.xcarchive"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

xcodegen generate

SETTINGS=$(xcodebuild -project LiteMD.xcodeproj -scheme LiteMD -configuration Release -showBuildSettings)
VERSION=$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<<"$SETTINGS")
BUILD=$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<<"$SETTINGS")
echo "==> LiteMD $VERSION ($BUILD)"

# 未配置更新源时传入空值，应用内不会检查更新。
UPDATE_FEED_SETTING="LITEMD_UPDATE_FEED_URL="
UPDATE_KEY_SETTING="LITEMD_UPDATE_PUBLIC_KEY="
if [[ $UPDATES == 1 ]]; then
  UPDATE_FEED_SETTING="LITEMD_UPDATE_FEED_URL=$DOWNLOAD_BASE_URL/appcast.json"
  UPDATE_KEY_SETTING="LITEMD_UPDATE_PUBLIC_KEY=$UPDATE_PUBLIC_KEY"
fi

xcodebuild archive \
  -project LiteMD.xcodeproj -scheme LiteMD -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  "$UPDATE_FEED_SETTING" "$UPDATE_KEY_SETTING"

APP="$OUTPUT/LiteMD.app"
ditto "$ARCHIVE/Products/Applications/LiteMD.app" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|Runtime Version|Timestamp="

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo
  echo "Signed (not notarized): $APP"
  echo "Set NOTARY_PROFILE to notarize, staple and build the DMG."
  exit 0
fi

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$OUTPUT/notarize.zip"
xcrun notarytool submit "$OUTPUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm "$OUTPUT/notarize.zip"

echo "==> Building DMG"
DMG="$OUTPUT/LiteMD-$VERSION.dmg"
STAGING="$OUTPUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/LiteMD.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiteMD $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

if [[ $UPDATES == 1 ]]; then
  echo "==> Update package and feed"
  ZIP="$OUTPUT/LiteMD-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  MINIMUM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
  swift scripts/sign-update.swift "$UPDATE_PRIVATE_KEY" "$ZIP" "$VERSION" "$BUILD" "$DOWNLOAD_BASE_URL/$(basename "$ZIP")" "$MINIMUM" ${RELEASE_NOTES:+"$RELEASE_NOTES"} > "$OUTPUT/appcast.json"
fi

# 中间产物 LiteMD.app 已经装进 DMG 和 ZIP 了。留着它，Spotlight 和“打开方式”里就会多出一个 LiteMD。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
rm -rf "$APP"

echo
echo "Done:"
echo "  $DMG"
if [[ $UPDATES == 1 ]]; then
  echo "  $ZIP"
  echo "  $OUTPUT/appcast.json"
fi
