#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="8.1.1"
cache="$PWD/.local/ffmpeg"
archive="$cache/ffmpeg-$version.tar.xz"
mkdir -p "$cache" "$PWD/build/helpers"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive"
fi
if [[ ! -d "$cache/ffmpeg-$version" ]]; then
  tar -xJf "$archive" -C "$cache"
fi
source="$cache/ffmpeg-$version"
architectures="${FFMPEG_ARCHITECTURES:-arm64 x86_64}"
for arch in $architectures; do
  work="$cache/build-$arch"
  mkdir -p "$work"
  if [[ ! -x "$work/ffmpeg" ]]; then
    (
      cd "$work"
      "$source/configure" --arch="$arch" --target-os=darwin --enable-cross-compile \
        --cc="clang -arch $arch" --extra-cflags="-mmacosx-version-min=14.0" \
        --extra-ldflags="-mmacosx-version-min=14.0" --disable-autodetect \
        --disable-everything --disable-network --disable-doc --disable-debug \
        --disable-shared --enable-static --disable-gpl --disable-nonfree \
        --disable-x86asm --disable-videotoolbox --disable-audiotoolbox \
        --enable-ffmpeg --enable-avcodec --enable-avformat --enable-swresample \
        --enable-protocol=file,pipe --enable-demuxer=matroska,ogg,mov,mp3,flac,wav,aac \
        --enable-decoder=opus,vorbis,aac,mp3,flac,pcm_s16le,pcm_s24le,pcm_f32le \
        --enable-parser=opus,vorbis,aac,mpegaudio,flac \
        --enable-encoder=aac --enable-muxer=ipod --enable-filter=abuffer,abuffersink,aresample,aformat,anull,asetpts,atrim
      make -j "$(sysctl -n hw.ncpu)" ffmpeg >build.log 2>&1
    )
  fi
done
if [[ "$architectures" == "arm64 x86_64" ]]; then
  lipo -create "$cache/build-arm64/ffmpeg" "$cache/build-x86_64/ffmpeg" -output build/helpers/ffmpeg
else
  cp "$cache/build-$architectures/ffmpeg" build/helpers/ffmpeg
fi
cp "$source/COPYING.LGPLv2.1" build/helpers/FFmpeg-LICENSE.txt
cp "$archive" build/helpers/ffmpeg-source.tar.xz
shasum -a 256 "$archive" >build/helpers/ffmpeg-source.sha256
printf 'Built minimal LGPL audio helper: %s\n' "$PWD/build/helpers/ffmpeg"
