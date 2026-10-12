#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
architecture="${ARCHITECTURE:-arm64}"
if [[ "$architecture" == "universal" ]]; then
  swift build -c "$configuration" --arch arm64 --arch x86_64
  bin="$(swift build -c "$configuration" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$configuration" --arch "$architecture"
  bin="$(swift build -c "$configuration" --arch "$architecture" --show-bin-path)"
fi
mkdir -p "$PWD/build"
stage="$(mktemp -d "$PWD/build/.stretto-package.XXXXXX")"
app="$stage/Stretto.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Stretto" "$app/Contents/MacOS/Stretto"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/Stretto"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp -R "$bin/StrettoNative_StrettoMac.bundle" "$app/Contents/Resources/"
frameworks=(Mpv Avcodec Avfilter Avformat Avutil Swresample Swscale Mbedcrypto Mbedtls Mbedx509)
for name in "${frameworks[@]}"; do
  framework="$PWD/.build/artifacts/stretto-native-macos/$name/$name.xcframework/macos-arm64_x86_64/$name.framework"
  [[ -d "$framework" ]] || { printf 'Missing audio framework: %s\n' "$name" >&2; exit 1; }
  cp -R "$framework" "$app/Contents/Frameworks/"
done
sources="$PWD/build/audio-sources"
mkdir -p "$sources"
fetch_source() {
  local name="$1" url="$2" checksum="$3"
  if [[ ! -f "$sources/$name" ]]; then
    curl --fail --silent --show-error --location "$url" -o "$sources/$name.partial"
    printf '%s  %s\n' "$checksum" "$sources/$name.partial" | shasum -a 256 --check --status
    mv "$sources/$name.partial" "$sources/$name"
  fi
  printf '%s  %s\n' "$checksum" "$sources/$name" | shasum -a 256 --check --status
}
fetch_source ffmpeg-6.0.tar.xz https://ffmpeg.org/releases/ffmpeg-6.0.tar.xz 57be87c22d9b49c112b6d24bc67d42508660e6b718b3db89c44e47e289137082
fetch_source mpv-0.36.0.tar.gz https://codeload.github.com/mpv-player/mpv/tar.gz/refs/tags/v0.36.0 29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6
fetch_source mbedtls-3.4.1.tar.gz https://codeload.github.com/Mbed-TLS/mbedtls/tar.gz/refs/tags/v3.4.1 a420fcf7103e54e775c383e3751729b8fb2dcd087f6165befd13f28315f754f5
fetch_source libmpv-darwin-build-v0.7.3.tar.gz https://codeload.github.com/media-kit/libmpv-darwin-build/tar.gz/refs/tags/v0.7.3 ae81d1a10de68ce90c35943bf2c98de804cc91e13e516e6365fb0360106db6b4
licenses="$app/Contents/Resources/ThirdParty"
mkdir -p "$licenses/Sources"
cp "$sources/ffmpeg-6.0.tar.xz" "$sources/mpv-0.36.0.tar.gz" "$sources/mbedtls-3.4.1.tar.gz" "$sources/libmpv-darwin-build-v0.7.3.tar.gz" "$licenses/Sources/"
cp packaging/ThirdPartyNotices.txt "$licenses/"
tar -xOf "$sources/mpv-0.36.0.tar.gz" mpv-0.36.0/LICENSE.LGPL > "$licenses/mpv-LGPL.txt"
tar -xOf "$sources/mpv-0.36.0.tar.gz" mpv-0.36.0/Copyright > "$licenses/mpv-Copyright.txt"
tar -xOf "$sources/ffmpeg-6.0.tar.xz" ffmpeg-6.0/COPYING.LGPLv2.1 > "$licenses/LGPL-2.1.txt"
tar -xOf "$sources/ffmpeg-6.0.tar.xz" ffmpeg-6.0/COPYING.LGPLv3 > "$licenses/LGPL-3.0.txt"
tar -xOf "$sources/ffmpeg-6.0.tar.xz" ffmpeg-6.0/COPYING.GPLv3 > "$licenses/GPL-3.0.txt"
tar -xOf "$sources/ffmpeg-6.0.tar.xz" ffmpeg-6.0/LICENSE.md > "$licenses/FFmpeg-LICENSE.txt"
tar -xOf "$sources/mbedtls-3.4.1.tar.gz" mbedtls-3.4.1/LICENSE > "$licenses/MbedTLS-LICENSE.txt"
tar -xOf "$sources/libmpv-darwin-build-v0.7.3.tar.gz" libmpv-darwin-build-0.7.3/LICENSE.txt > "$licenses/build-provider-LICENSE.txt"
iconset="$PWD/build/Stretto.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Sources/StrettoMac/Resources/icon512.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Sources/StrettoMac/Resources/icon512.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Stretto.icns"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  for name in "${frameworks[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app/Contents/Frameworks/$name.framework"
  done
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
else
  for name in "${frameworks[@]}"; do
    codesign --force --sign - "$app/Contents/Frameworks/$name.framework"
  done
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
destination="$PWD/build/Stretto.app"
if [[ -e "$destination" ]]; then
  previous="$PWD/build/Stretto-previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$previous"
  printf 'Preserved previous app at %s\n' "$previous"
fi
mv "$app" "$destination"
rmdir "$stage"
app="$destination"
printf 'Built %s\n' "$app"
