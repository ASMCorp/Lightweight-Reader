#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/build/ReleaseDerivedData"
products="$build_root/Build/Products/Release"
stage="$project_root/build/dmg-stage"
mount_point="$project_root/build/dmg-verify"
output_dir="$project_root/dist"
product_app="LightweightReader.app"
app_name="Lightweight Reader.app"
packaging_venv="$project_root/build/packaging-venv"
identity="${SIGN_IDENTITY:-}"

if [[ -n "${NOTARY_PROFILE:-}" && -z "$identity" ]]; then
  print -u2 'NOTARY_PROFILE requires SIGN_IDENTITY.'
  exit 1
fi

cd "$project_root"
xcodegen generate >/dev/null

mkdir -p "$output_dir" "$project_root/build"
if [[ ! -x "$packaging_venv/bin/dmgbuild" ]]; then
  python3 -m venv "$packaging_venv"
  "$packaging_venv/bin/python" -m pip install --disable-pip-version-check -r "$project_root/packaging/requirements.txt"
fi

for scheme in LightweightReader reader-agent; do
  xcodebuild \
    -project "$project_root/LightweightReader.xcodeproj" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_root" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build -quiet
done

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$products/$product_app/Contents/Info.plist")
dmg="$output_dir/LightweightReader-$version-macos-universal.dmg"

rm -rf "$stage"
mkdir -p "$stage"
ditto "$products/$product_app" "$stage/$app_name"
mkdir -p "$stage/$app_name/Contents/Helpers"
ditto "$products/reader-agent" "$stage/$app_name/Contents/Helpers/reader-agent"

cat > "$stage/$app_name/Contents/Resources/Agent Setup.md" <<'EOF'
# Agent setup

Drag Lightweight Reader.app to Applications to install it.

The optional agent tool is included at:
/Applications/Lightweight Reader.app/Contents/Helpers/reader-agent

For a local MCP client, use that full path as the command and pass `mcp` as its argument.
The tool can also run `reader-agent call OPERATION JSON_ARGUMENTS`.
EOF

if [[ -n "$identity" ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$stage/$app_name/Contents/Helpers/reader-agent"
  codesign --force --options runtime --timestamp --sign "$identity" "$stage/$app_name"
else
  codesign --force --sign - "$stage/$app_name/Contents/Helpers/reader-agent"
  codesign --force --sign - "$stage/$app_name"
fi

codesign --verify --deep --strict "$stage/$app_name"
for binary in "$stage/$app_name/Contents/MacOS/LightweightReader" "$stage/$app_name/Contents/Helpers/reader-agent"; do
  lipo "$binary" -verify_arch arm64
  lipo "$binary" -verify_arch x86_64
done

"$packaging_venv/bin/dmgbuild" \
  -s "$project_root/packaging/dmg_settings.py" \
  -D "app=$stage/$app_name" \
  -D "background=$project_root/packaging/InstallerBackground.png" \
  -D "icon=$project_root/Sources/LightweightReader/Resources/AppIcon.icns" \
  'Lightweight Reader' "$dmg"
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
fi
hdiutil verify "$dmg" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  hdiutil verify "$dmg" >/dev/null
fi

mkdir -p "$mount_point"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_point" >/dev/null
trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true' EXIT
test -x "$mount_point/$app_name/Contents/MacOS/LightweightReader"
test -x "$mount_point/$app_name/Contents/Helpers/reader-agent"
test -L "$mount_point/Applications"
test -f "$mount_point/.DS_Store"
"$mount_point/$app_name/Contents/Helpers/reader-agent" call document_info \
  "{\"path\":\"$mount_point/$app_name/Contents/Resources/Agent Setup.md\"}" >/dev/null
hdiutil detach "$mount_point" >/dev/null
trap - EXIT

print "Created $dmg"
