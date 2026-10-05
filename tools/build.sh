#!/usr/bin/env bash
#
# build.sh — turn your game into an APK.
#
# Usage:
#   ./tools/build.sh <game_dir|game.rar|game.zip|...> [--strip-audio] [--all-abis]
#
# --strip-audio also strips the game's Audio folder (≈200 MB smaller APK).
# Builds arm64-v8a by default; --all-abis also builds armeabi-v7a.
# Output APKs appear in app/build/outputs/apk/debug/*-debug.apk.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STRIP_AUDIO=0
ALL_ABIS=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --strip-audio) STRIP_AUDIO=1;;
    --all-abis) ALL_ABIS=1;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0;;
    *) [[ -z "$SRC" ]] && SRC="$arg" || { echo "Unknown argument: $arg" >&2; exit 1; };;
  esac
done

[[ -z "$SRC" ]] || [[ ! -e "$SRC" ]] && { echo "Usage: $0 <game_dir|archive> [--strip-audio] [--all-abis]" >&2; exit 1; }
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
    # These dependencies configure in their source directories. Give each ABI
    # its own copy so Makefiles, CMake caches and objects cannot cross ABIs.
    native_root="$REPO_ROOT/app/jni"
    workspace="$native_root/.native-work/$abi"
    mkdir -p "$workspace"
    cp "$native_root/Makefile" "$workspace/Makefile"
    for dependency in pixman libiconv openal openssl ruby; do
      mkdir -p "$workspace/$dependency"
      rsync -a --delete --exclude=.git --exclude=cmakebuild \
        "$native_root/$dependency/" "$workspace/$dependency/"
    done
    cd "$workspace"
    # Existing checkouts may already contain configuration for the other ABI.
    # Clean only the isolated copy, preserving installed libraries and sources.
    make clean
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
    make HOST="$host" TARGET="$target" ABI="$abi" \
      BUILD_PREFIX="$native_root/build-$abi" -j"$(nproc)"
    for library in libcpufeatures.a libpixman-1.a libiconv.a libopenal.so libssl.a libcrypto.a libruby.so.3.1.0; do
      if [[ ! -f "$libdir/$library" ]]; then
        echo "Native build for $abi did not produce $libdir/$library. Stopping before APK packaging." >&2
        exit 1
      fi
    done
  )
}
echo "==> [1/4] Preparing native dependencies..."
build_native arm64-v8a aarch64-linux-android aarch64-linux-android
TARGET_ABIS=arm64-v8a
if (( ALL_ABIS )); then
  build_native armeabi-v7a armv7a-linux-androideabi arm-linux-androideabi
  TARGET_ABIS=arm64-v8a,armeabi-v7a
fi

NAME="$(basename "${SRC%.*}" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"

echo "==> [2/4] Packaging game files..."
"$REPO_ROOT/tools/package_game.sh" --src "$SRC" --name "$NAME"

echo "==> [3/4] Installing bundled assets..."
mkdir -p "$REPO_ROOT/app/src/main/assets"
rm -rf "$REPO_ROOT/app/src/main/assets/game"
cp -r "$REPO_ROOT/build/$NAME/mkxp-z" "$REPO_ROOT/app/src/main/assets/game"

echo "==> [4/4] Building APK for $TARGET_ABIS..."
GRADLE_ARGS=(assembleDebug "-PtargetAbis=$TARGET_ABIS" --console=plain)
(( STRIP_AUDIO == 0 )) || GRADLE_ARGS+=(-PstripAudio)
(cd "$REPO_ROOT" && ./gradlew "${GRADLE_ARGS[@]}")

echo
echo "Done! APKs in app/build/outputs/apk/debug/:"
ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/*-debug.apk 2>/dev/null || \
  ls -la "$REPO_ROOT"/app/build/outputs/apk/debug/
