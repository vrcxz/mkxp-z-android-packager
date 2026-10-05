#!/usr/bin/env bash
#
# setup.sh — one-time environment setup for building mkxp-z APKs.
#
# Installs: build tools, JDK 17, Android cmdline-tools + SDK platform 33,
# Android NDK 23.2.8568313, CMake, autotools, OBB helpers, xxd, and the
# native dependency sources in app/jni. After this, ./tools/build.sh works.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="23.2.8568313"

log() { echo; echo "==> $*"; }

# ---------------- system packages ----------------
log "Installing apt dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  openjdk-17-jdk-headless \
  build-essential cmake wget curl unzip git \
  autoconf automake libtool gawk \
  dosfstools mtools xxd rsync

# ---------------- Android SDK/NDK/CMake ----------------
mkdir -p "$SDK_DIR/cmdline-tools"
SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
if [[ ! -x "$SDKMANAGER" ]]; then
  log "Downloading Android command line tools..."
  wget -q \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    -O /tmp/android-cmdline-tools.zip
  unzip -q /tmp/android-cmdline-tools.zip -d "$SDK_DIR/cmdline-tools"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm -f /tmp/android-cmdline-tools.zip
fi

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_NDK_HOME="$SDK_DIR/ndk/$NDK_VERSION"

log "Installing Android SDK packages (platform 33, build-tools, NDK, CMake)..."
# sdkmanager closes stdin when done, so yes can exit with SIGPIPE (141).
# Check sdkmanager's status separately while keeping real failures fatal.
set +e
yes | "$SDKMANAGER" --licenses >/dev/null
license_status=("${PIPESTATUS[@]}")
set -e
if (( license_status[1] != 0 )); then
  echo "Android SDK license acceptance failed (exit ${license_status[1]})." >&2
  exit "${license_status[1]}"
fi
if (( license_status[0] != 0 && license_status[0] != 141 )); then
  echo "Failed to supply Android SDK license responses." >&2
  exit "${license_status[0]}"
fi
"$SDKMANAGER" \
  "platform-tools" \
  "platforms;android-33" \
  "build-tools;33.0.2" \
  "cmake;3.22.1" \
  "ndk;$NDK_VERSION"

# ---------------- native deps sources ----------------
log "Fetching native dependency sources (SDL2, Ruby, openal, ...)..."
cd "$REPO_ROOT/app/jni"
./get_deps.sh

log "Embedding engine assets/shaders..."
cd "$REPO_ROOT/app/jni/mkxp-z"
[[ -d xxd ]] || ./make_xxd.sh

# ---------------- env helper ----------------
log "Writing tools/env.sh..."
cat > "$REPO_ROOT/tools/env.sh" <<EOF
export ANDROID_HOME=$SDK_DIR
export ANDROID_SDK_ROOT=\$ANDROID_HOME
export ANDROID_NDK_HOME=\$ANDROID_HOME/ndk/$NDK_VERSION
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=\$JAVA_HOME/bin:\$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:\$ANDROID_HOME/platform-tools:\$PATH
export ARCH=linux-x86_64
EOF

echo
echo "Setup complete. Build a game APK with:"
echo "  ./tools/build.sh /path/to/your/game_folder_or_archive"
