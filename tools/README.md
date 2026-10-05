# Packaging games for mkxp-z-android-reworked

`package_game.sh` turns an RPG Maker XP game (e.g. a Pokémon Essentials
hack) into everything needed to run it on Android with this app.

## Quick start

```bash
./tools/package_game.sh --src "Essentials FRLG V1.0.rar" --name essentials-frlg --obb --zip
```

Outputs (in `./build/<name>/`):

| Output | Purpose |
|---|---|
| `mkxp-z/` | Game folder — copy its *contents* to `/storage/emulated/0/mkxp-z` on the phone |
| `main.<v>.<pkg>.obb` | Expansion file (with `--obb`) — place at `/Android/obb/<pkg>/`; auto-mounted by the app |
| `mkxp-z.zip` | Zip of `mkxp-z/` (with `--zip`) |

## What it does

1. Extracts archives (`rar`, `zip`, `7z`, `tar*`) via `bsdtar`/`7z`/`unzip`.
2. Finds the real game root (`Game.ini` + `Data/Scripts.rxdata`), no matter how
   deeply the archive nests it.
3. Stages it as a standard mkxp-z game folder, stripping Windows-only files
   (`*.exe`, `*.dll`, `desktop.ini`, ...).
4. Ensures `mkxp.json` exists and injects every `*.rb` in `patches/` through
   `"preloadScript": [...]` — no need to edit `Data/Scripts.rxdata`.
   Skip with `--no-fix`, change the directory with `--fix-dir`, or add a
   one-off script with `--fix-script` (repeatable).
5. Optionally builds the OBB (needs `dosfstools` + `mtools`) and/or zips.

## Script fixes (patches/)

Native engine patches are kept as plain Ruby files in `patches/` at the repo
root. **Every `*.rb` there is copied into the game root and listed in
`mkxp.json`'s `preloadScript`**, so they run before the game scripts on every
launch. To add a new fix, just drop `my_fix.rb` into `patches/`.

Current patches:

- `patches/fix-essentials-clock.rb` — patches `System.uptime`, which this
  Android port returns as integer microseconds, while Pokémon Essentials v21
  expects floating-point seconds. Because it preloads before the game
  scripts, it works for any Essentials game; on engines that return proper
  seconds it disables itself.

## Building the APK itself

The script doesn't install toolchains. To produce the APK (per the repo
README: Android SDK, NDK 23.2.8568313, CMake, Ruby):

```bash
export ANDROID_HOME=... ANDROID_NDK_HOME=...
./tools/package_game.sh --src game.rar --name mygame --build-apk
```
