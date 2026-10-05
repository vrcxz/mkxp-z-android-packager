#!/usr/bin/env bash
#
# package_game.sh — Package an RPG Maker XP game (e.g. a Pokémon Essentials
# game) so it can run with the mkxp-z Android port in this repo.
#
# What it does:
#   1. Extracts the game from an archive (rar/zip/7z/tar*) or uses a directory.
#   2. Locates the real game root (the folder containing Game.ini).
#   3. Copies it into <out>/<name>/mkxp-z/ as a drop-in game folder
#      (/storage/emulated/0/mkxp-z on the device).
#   4. Removes Windows-only junk (*.exe, *.dll, desktop.ini, ...).
#   5. Ensures mkxp.json exists and injects every *.rb from patches/
#      (plus any --fix-script) via "preloadScript", so no game data
#      files need to be modified.
#   6. Optionally builds a main OBB expansion file (main.<ver>.<pkg>.obb).
#
# Usage:
#   package_game.sh --src <game.rar|game_dir> [options]
#
# Options:
#   --name NAME      Output name (default: sanitized game root folder name)
#   --out DIR        Output directory (default: ./build)
#   --version N      OBB version code (default: 1)
#   --package ID     Android application id for the OBB name
#                    (default: com.hatkid.mkxpz)
#   --fix-dir DIR    Directory of *.rb patch scripts to preload
#                    (default: <repo>/patches; each *.rb is injected)
#   --fix-script P   Extra patch script; repeatable
#   --no-fix         Do not inject any fix scripts
#   --obb            Also produce the main OBB expansion file
#   --zip            Also produce a zip of the mkxp-z folder
#   --build-apk      Build the APK (needs Android SDK/NDK; see README)
#   -h, --help       Show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC=""
NAME=""
OUT="$REPO_ROOT/build"
OBB_VERSION=1
PACKAGE_ID="com.hatkid.mkxpz"
FIX_DIR="$REPO_ROOT/patches"
EXTRA_FIX_SCRIPTS=()
USE_FIX=1
MAKE_OBB=0
MAKE_ZIP=0
BUILD_APK=0

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --version) OBB_VERSION="$2"; shift 2;;
    --package) PACKAGE_ID="$2"; shift 2;;
    --fix-script) EXTRA_FIX_SCRIPTS+=("$2"); shift 2;;
    --fix-dir) FIX_DIR="$2"; shift 2;;
    --no-fix) USE_FIX=0; shift;;
    --obb) MAKE_OBB=1; shift;;
    --zip) MAKE_ZIP=1; shift;;
    --build-apk) BUILD_APK=1; shift;;
    -h|--help) usage 0;;
    *) echo "Unknown option: $1" >&2; usage 1;;
  esac
done

[[ -z "$SRC" ]] && { echo "ERROR: --src is required" >&2; usage 1; }
[[ -e "$SRC" ]] || { echo "ERROR: '$SRC' does not exist" >&2; exit 1; }

log() { echo "==> $*"; }

# ----------------------------------------------------------------#
# 1. Extract / locate the game root
# ----------------------------------------------------------------#
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$SRC" in
  *.rar|*.zip|*.7z|*.tar|*.tar.*|*.tgz|*.tbz2|*.txz)
    log "Extracting $SRC"
    mkdir -p "$WORK/extract"
    if command -v bsdtar >/dev/null; then
      bsdtar -xf "$SRC" -C "$WORK/extract"
    elif command -v 7z >/dev/null; then
      7z x -o"$WORK/extract" "$SRC" >/dev/null
    elif command -v unzip >/dev/null; then
      unzip -q "$SRC" -d "$WORK/extract"
    else
      echo "ERROR: need bsdtar, 7z or unzip to extract archives" >&2; exit 1
    fi
    SEARCH_ROOT="$WORK/extract"
    ;;
  *)
    SEARCH_ROOT="$(cd "$SRC" && pwd)"
    ;;
esac

GAME_ROOT=""
while IFS= read -r ini; do
  dir="$(dirname "$ini")"
  if [[ -f "$dir/Data/Scripts.rxdata" ]]; then
    GAME_ROOT="$dir"; break
  fi
done < <(find "$SEARCH_ROOT" -iname "Game.ini" | sort)

if [[ -z "$GAME_ROOT" ]]; then
  echo "ERROR: no RPG Maker XP game root (Game.ini + Data/Scripts.rxdata) found" >&2
  exit 1
fi
log "Found game root: $GAME_ROOT"

# ----------------------------------------------------------------#
# 2. Stage the game folder
# ----------------------------------------------------------------#
if [[ -z "$NAME" ]]; then
  NAME="$(basename "$GAME_ROOT" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')"
fi
DEST="$OUT/$NAME/mkxp-z"
log "Staging -> $DEST"
mkdir -p "$DEST"
if command -v rsync >/dev/null; then
  rsync -a --exclude '*.exe' --exclude '*.dll' --exclude 'desktop.ini' \
        --exclude 'Thumbs.db' --exclude '*.URL' --exclude '*.url' \
        "$GAME_ROOT/" "$DEST/"
else
  (cd "$GAME_ROOT" && tar cf - --exclude='*.exe' --exclude='*.dll' \
     --exclude='desktop.ini' --exclude='Thumbs.db' --exclude='*.URL' .) | (cd "$DEST" && tar xf -)
fi

# ----------------------------------------------------------------#
# 3. mkxp.json + fix-script injection
# ----------------------------------------------------------------#
JSON="$DEST/mkxp.json"
if [[ ! -f "$JSON" ]]; then
  log "Creating default mkxp.json"
  cat > "$JSON" <<EOF
{
    "windowTitle": "$NAME",
    "defScreenW": 512,
    "defScreenH": 384,
    "subImageFix": true,
    "vsync": true,
    "syncToRefreshrate": true
}
EOF
fi

if [[ $USE_FIX -eq 1 ]]; then
  # Collect fix scripts: every *.rb in FIX_DIR (sorted) + any --fix-script files
  FIX_SCRIPTS=()
  if [[ -d "$FIX_DIR" ]]; then
    while IFS= read -r f; do FIX_SCRIPTS+=("$f"); done < <(find "$FIX_DIR" -maxdepth 1 -name '*.rb' | sort)
  fi
  for f in "${EXTRA_FIX_SCRIPTS[@]:-}"; do
    [[ -n "$f" ]] && FIX_SCRIPTS+=("$f")
  done

  if [[ ${#FIX_SCRIPTS[@]} -eq 0 ]]; then
    echo "WARN: no fix scripts in '$FIX_DIR' (*.rb); skipping injection" >&2
  fi

  JSON_ARRAY=""
  for f in "${FIX_SCRIPTS[@]}"; do
    [[ -f "$f" ]] || { echo "WARN: fix script '$f' not found, skipping" >&2; continue; }
    log "Injecting fix script: $f"
    cp "$f" "$DEST/$(basename "$f")"
    [[ -n "$JSON_ARRAY" ]] && JSON_ARRAY+=", "
    JSON_ARRAY+="\"$(basename "$f")\""
  done

  if [[ -n "$JSON_ARRAY" ]]; then
    if grep -qE '"preloadScript"' "$JSON"; then
      sed -i -E 's|^[[:space:]]*//?[[:space:]]*"preloadScript".*$|    "preloadScript": ['"$JSON_ARRAY"'],|' "$JSON"
    else
      python3 - "$JSON" "$JSON_ARRAY" <<'PY'
import sys
p, array = sys.argv[1], sys.argv[2]
text = open(p, encoding='utf-8-sig').read()
idx = text.rstrip().rfind('}')
head = text[:idx].rstrip()
last = [l for l in head.splitlines() if l.strip() and not l.strip().startswith('//')][-1]
if not last.rstrip().endswith(','):
    pos = head.rfind(last)
    head = head[:pos] + last.rstrip() + ',' + head[pos + len(last):]
entry = f'\n    "preloadScript": [{array}]\n'
text = head + entry + text[idx:]
open(p, 'w', encoding='utf-8').write(text)
PY
    fi
  fi

  # Ensure Android-friendly display settings in the config (scale the game
  # screen up to the device display instead of rendering tiny in a corner).
  python3 - "$JSON" <<'PY'
import sys
p = sys.argv[1]
text = open(p, encoding='utf-8-sig').read()
if '"fullscreen": true' in text:
    sys.exit(0)
block_lines = [
    '    "fullscreen": true,',
    '    "fixedAspectRatio": true,',
    '    "integerScalingActive": true,',
    '    "integerScalingLastMile": true,',
    '    "smoothScaling": true,',
]
marker = '"preloadScript"'
if marker in text:
    idx = text.index(marker)
    text = text[:idx] + "\n".join(block_lines) + "\n    " + text[idx:]
else:
    idx = text.rstrip().rfind('}')
    head = text[:idx].rstrip()
    block_lines[-1] = block_lines[-1].rstrip(',')  # last property has no trailing comma
    lines = head.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip() and not lines[i].strip().startswith('//'):
            if not lines[i].rstrip().endswith(','):
                lines[i] = lines[i].rstrip() + ','
            break
    text = "\n".join(lines) + "\n" + "\n".join(block_lines) + "\n" + text[idx:]
open(p, 'w', encoding='utf-8').write(text)
PY
fi

# ----------------------------------------------------------------#
# 4. Optional OBB expansion file
# ----------------------------------------------------------------#
if [[ $MAKE_OBB -eq 1 ]]; then
  OBB="$OUT/$NAME/main.${OBB_VERSION}.${PACKAGE_ID}.obb"
  command -v mkfs.vfat >/dev/null || { echo "ERROR: mkfs.vfat missing (apt install dosfstools)" >&2; exit 1; }
  command -v mcopy >/dev/null || { echo "ERROR: mcopy missing (apt install mtools)" >&2; exit 1; }

  SIZE_MB=$(du -sm "$DEST" | cut -f1)
  PADDED=$(( SIZE_MB + SIZE_MB / 8 + 64 ))
  log "Creating OBB $OBB (${PADDED} MiB, FAT32)"
  dd if=/dev/zero of="$OBB" bs=1M count="$PADDED" status=none
  mkfs.vfat -F 32 -n "${NAME:0:11}" "$OBB" >/dev/null
  MTOOLS_SKIP_CHECK=1 mcopy -s -i "$OBB" "$DEST"/* "::"
fi

# ----------------------------------------------------------------#
# 5. Optional zip
# ----------------------------------------------------------------#
if [[ $MAKE_ZIP -eq 1 ]]; then
  log "Zipping -> $OUT/$NAME/mkxp-z.zip"
  (cd "$OUT/$NAME" && zip -qr "mkxp-z.zip" mkxp-z)
fi

# ----------------------------------------------------------------#
# 6. Optional APK build
# ----------------------------------------------------------------#
if [[ $BUILD_APK -eq 1 ]]; then
  log "Building APK (this requires Android SDK/NDK + deps)"
  if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    echo "ERROR: set ANDROID_HOME/ANDROID_SDK_ROOT and ANDROID_NDK_HOME first" >&2; exit 1
  fi
  pushd "$REPO_ROOT/app/jni" >/dev/null
  [[ -d SDL2 ]] || ./get_deps.sh
  popd >/dev/null
  (cd "$REPO_ROOT" && ./gradlew assembleDebug)
fi

log "Done. Game staged at: $DEST"
if [[ $MAKE_OBB -eq 1 ]]; then log "OBB: $OBB  (place at /Android/obb/$PACKAGE_ID/)"; fi
if [[ $MAKE_ZIP -eq 1 ]]; then log "Zip: $OUT/$NAME/mkxp-z.zip"; fi
true
