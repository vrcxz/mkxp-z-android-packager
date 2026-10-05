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

# Check every library produced by the dependency Makefile before reusing a build.
build_native() {
  local abi="$1" host="$2" target="$3" library complete=1
  local libdir="$REPO_ROOT/app/jni/build-$abi/lib"
  for library in libcpufeatures.a libpixman-1.a libiconv.a libopenal.so libssl.a libcrypto.a libruby.so.3.1.0; do
    [[ -f "$libdir/$library" ]] || complete=0
  done
  if (( complete )); then
    echo "==> Reusing native dependencies for $abi"
    return
  fi
  echo "==> Building native dependencies for $abi. The first build can take a long time."
  (
    cd "$REPO_ROOT/app/jni"
    # Keep a visible elapsed-time update even while a compiler is quiet.
    start=$SECONDS
    (
      sleep_pid=""
      trap '[[ -z "$sleep_pid" ]] || kill "$sleep_pid" 2>/dev/null; exit 0' TERM INT
      while true; do
        sleep 30 &
        sleep_pid=$!
        wait "$sleep_pid"
        echo "==> Native build for $abi still running ($((SECONDS - start)) seconds elapsed)..."
      done
    ) &
    progress_pid=$!
    trap 'kill "$progress_pid" 2>/dev/null || true; wait "$progress_pid" 2>/dev/null || true' EXIT
    HOST="$host" TARGET="$target" ABI="$abi" make -j"$(nproc)"
  )
}
echo "==> [1/5] Preparing native dependencies for arm64-v8a..."
build_native arm64-v8a aarch64-linux-android aarch64-linux-android
echo "==> [2/5] Preparing native dependencies for armeabi-v7a..."
build_native armeabi-v7a armv7a-linux-androideabi arm-linux-androideabi

NAME="$(basename "${SRC%.*}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"

echo "==> [3/5] Packaging game files..."
"$REPO_ROOT/tools/package_game.sh" --src "$SRC" --name "$NAME"

echo "==> [4/5] Installing bundled assets..."
mkdir -p "$REPO_ROOT/app/src/main/assets"
rm -rf "$REPO_ROOT/app/src/main/assets/game"
cp -r "$REPO_ROOT/build/$NAME/mkxp-z" "$REPO_ROOT/app/src/main/assets/game"

echo "==> [5/5] Building APK..."
if [[ $STRIP_AUDIO -eq 1 ]]; then
  (cd "$REPO_ROOT" && ./gradlew assembleDebug -PstripAudio --console=plain)
else
  (cd "$REPO_ROOT" && ./gradlew assembleDebug --console=plain)
fi

echo
echo "Done! APKs in app/build/outputs/apk/debug/:"
ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/*-debug.apk 2>/dev/null || \
  ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/
