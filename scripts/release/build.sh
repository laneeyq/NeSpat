#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:?Supply an absolute output directory}
[[ "$out" == /* && ! -e "$out/NeSpat.dmg" && "$(uname -m)" == arm64 ]]
mkdir -p "$out"
stage=$(mktemp -d /private/tmp/nespat-release.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/scripts" "$stage/image" "$stage/pkg" "$stage/resources"
flags=(--cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
map=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=NeSpat" -Xswiftc -debug-prefix-map -Xswiftc "$PWD=NeSpat")
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$PWD=NeSpat --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=cargo --remap-path-prefix=$HOME=home"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --lib --bins --manifest-path rust/Cargo.toml
for target in NeSpat NeSpatPrivilegeHelper; do
    swift build -c release --product "$target" "${flags[@]}" "${map[@]}"
done
bin=$(swift build -c release "${flags[@]}" --show-bin-path)
app="$stage/NeSpat.app"
mkdir -p "$app/Contents/"{MacOS,Library/Helpers,Resources}
cp "$bin/NeSpat" "$app/Contents/MacOS/"
cp "$bin/NeSpatPrivilegeHelper" "$app/Contents/Library/Helpers/"
cp rust/target/release/check-update "$app/Contents/Library/Helpers/check-update"
codesign -fs - --options runtime "$app/Contents/Library/Helpers/check-update"
cp Resources/AppIcon.icns LICENSE "$app/Contents/Resources/"
cp .build/checkouts/MenuBarExtraAccess/LICENSE "$app/Contents/Resources/MenuBarExtraAccess-LICENSE"
cp Resources/Info.plist "$app/Contents/"
plutil -insert NeSpatExclusive -bool YES "$app/Contents/Info.plist"
helper="$app/Contents/Library/Helpers/NeSpatPrivilegeHelper"
strip -S -x "$helper" "$app/Contents/MacOS/NeSpat"
codesign -fs - --options runtime --identifier local.nespat.privilege-helper "$helper"
codesign -fs - --options runtime --identifier local.nespat.app "$app"
pin() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }
printf '{"guiHash":"%s","helperHash":"%s"}\n' "$(pin "$app")" "$(pin "$helper")" > "$stage/scripts/pins.json"
cp rust/target/release/setup "$stage/scripts/setup"
strip -S -x "$stage/scripts/setup"
codesign -fs - --options runtime "$stage/scripts/setup"
"$stage/scripts/setup" --verify "$app"
(cd "$stage" && /usr/bin/zip -qrX scripts/app.zip NeSpat.app)
cp scripts/release/postinstall "$stage/scripts/"
COPYFILE_DISABLE=1 pkgbuild --nopayload --scripts "$stage/scripts" --identifier local.nespat.public.install --version 1.1.0 "$stage/pkg/component.pkg"
cp scripts/release/welcome.html "$stage/resources/"
launcher="$stage/image/NeSpat.app/Contents"
mkdir -p "$launcher/MacOS" "$launcher/Resources"
cp Resources/Info.plist "$launcher/"
plutil -replace CFBundleIdentifier -string local.nespat.launcher "$launcher/Info.plist"
plutil -replace CFBundleDisplayName -string NeSpat "$launcher/Info.plist"
plutil -replace CFBundleShortVersionString -string 1.1.0 "$launcher/Info.plist"
cp Resources/AppIcon.icns "$launcher/Resources/"
cp rust/target/release/launcher "$launcher/MacOS/NeSpat"
productbuild --distribution scripts/release/distribution.xml --resources "$stage/resources" --package-path "$stage/pkg" "$launcher/Resources/Services.pkg"
cp "$launcher/Resources/Services.pkg" "$out/NeSpat-Update.pkg"
codesign -fs - --options runtime "$stage/image/NeSpat.app"
codesign --verify --deep --strict "$stage/image/NeSpat.app"
bash scripts/release/image.sh "$stage/image/NeSpat.app" "$out/NeSpat.dmg"
hdiutil verify "$out/NeSpat.dmg"
(cd "$out" && shasum -a 256 NeSpat.dmg NeSpat-Update.pkg > SHA256.txt)
