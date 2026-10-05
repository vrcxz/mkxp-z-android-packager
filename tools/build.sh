#!/usr/bin/env bash
#
# build.sh — turn your game into an APK.
#
# Usage:
#   ./tools/build.sh <game_dir|game.rar|game.zip|...> [--strip-audio]
#
# --strip-audio also strips the game's Audio folder (≈200 MB smaller APK).
# Output APKs appear in app/build/outputs/apk/debug/*-debug.apk.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STRIP_AUDIO=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --strip-audio) STRIP_AUDIO=1;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0;;
    *) [[ -z "$SRC" ]] && SRC="$arg" || { echo "Unknown argument: $arg" >&2; exit 1; };;
  esac
done

[[ -z "$SRC" ]] || [[ ! -e "$SRC" ]] && { echo "Usage: $0 <game_dir|archive> [--strip-audio]" >&2; exit 1; }
[[ -f "$REPO_ROOT/tools/env.sh" ]] || { echo "Run ./tools/setup.sh first" >&2; exit 1; }
source "$REPO_ROOT/tools/env.sh"

if [[ ! -x "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ARCH/bin/aarch64-linux-android23-clang" ]]; then
  echo "Android NDK is missing or incomplete. Run ./tools/setup.sh and wait for 'Setup complete'." >&2
  exit 1
fi
for dep in libogg libvorbis libtheora libiconv uchardet pixman physfs openal SDL2 SDL2_image SDL2_ttf SDL2_sound openssl ruby; do
  if [[ ! -d "$REPO_ROOT/app/jni/$dep" ]]; then
    echo "Native dependency '$dep' is missing. Run ./tools/setup.sh and wait for 'Setup complete'." >&2
    exit 1
  fi
done

# Native dependency prebuilts (needed once per checkout):
if [[ ! -f "$REPO_ROOT/app/jni/build-arm64-v8a/lib/libopenal.so" ]]; then
  echo "==> Building native dependencies for arm64-v8a (first run only)..."
  (cd "$REPO_ROOT/app/jni" && HOST=aarch64-linux-android TARGET=aarch64-linux-android ABI=arm64-v8a make -j"$(nproc)")
fi
if [[ ! -f "$REPO_ROOT/app/jni/build-armeabi-v7a/lib/libopenal.so" ]]; then
  echo "==> Building native dependencies for armeabi-v7a (first run only)..."
  (cd "$REPO_ROOT/app/jni" && HOST=armv7a-linux-androideabi TARGET=arm-linux-androideabi ABI=armeabi-v7a make -j"$(nproc)")
fi

NAME="$(basename "${SRC%.*}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"

echo "==> Packaging game files..."
"$REPO_ROOT/tools/package_game.sh" --src "$SRC" --name "$NAME"

echo "==> Installing bundled assets..."
rm -rf "$REPO_ROOT/app/src/main/assets/game"
cp -r "$REPO_ROOT/build/$NAME/mkxp-z" "$REPO_ROOT/app/src/main/assets/game"

echo "==> Building APK..."
if [[ $STRIP_AUDIO -eq 1 ]]; then
  (cd "$REPO_ROOT" && ./gradlew assembleDebug -PstripAudio --console=plain)
else
  (cd "$REPO_ROOT" && ./gradlew assembleDebug --console=plain)
fi

echo
echo "Done! APKs in app/build/outputs/apk/debug/:"
ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/*-debug.apk 2>/dev/null || \
  ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/
