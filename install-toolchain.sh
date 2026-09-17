#!/usr/bin/env bash
# Install the iOS-on-Linux toolchain on Omarchy (Arch, aarch64 or x86_64).
# Verified 2026-09-09 on aarch64 (swift 6.3.3, xtool 1.19.0, lldb 21.0.0);
# reported working on x86_64 the same week. Safe to re-run: pieces already
# in place are skipped. Installs into user paths plus normal pacman/AUR
# packages. No system reinstalls.
set -euo pipefail

SWIFT_BIN_DIR=/usr/lib/swift/bin
VENV="$HOME/pymobile3-venv"
SDK_SRC="${SDK_SRC:-$HOME/xcode-apple-sdk-src}"
SDK_CACHE="${SDK_CACHE:-$HOME/.cache/xtool}"

# Register the SDK bundle at $1 into whatever toolchain is first on PATH.
# swift sdk install refuses to overwrite an existing bundle, so clear it first.
sdk_install_from() {
  swift sdk remove darwin >/dev/null 2>&1 || true
  "$HOME/.local/bin/xtool" sdk install "$1"
}

# Build the portable darwin.xtoolsdk from an Xcode.xip or Xcode.app ($1),
# keep it in the cache, and register it. Building instead of installing
# directly costs the same extraction plus one local copy, but the result is
# toolchain-independent: it survives toolchain swaps (mise/asdf/manual) and
# re-registers with no .xip and no network (see README, Toolchain swaps).
sdk_build_and_install() {
  mkdir -p "$SDK_CACHE"
  tmpd=$(mktemp -d "$SDK_CACHE/.build.XXXXXX")
  "$HOME/.local/bin/xtool" sdk build "$1" "$tmpd"
  ver=$(basename "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)
  cached="$SDK_CACHE/darwin-${ver:-unknown}.xtoolsdk"
  rm -rf "$cached"
  mv "$tmpd/darwin.xtoolsdk" "$cached"
  rmdir "$tmpd"
  echo "SDK cache kept at: $cached"
  sdk_install_from "$cached"
}

# Survive-status summary: what a toolchain swap leaves behind.
survive_status() {
  echo "-- Survive status --"
  echo "SDK: re-registered from $1"
  if ls "$HOME/.pymobiledevice3"/*.plist >/dev/null 2>&1; then
    echo "pairing: intact at $HOME/.pymobiledevice3"
  else
    echo "pairing: no records yet (plug the iPhone once; nothing is lost here by a swap)"
  fi
  if [ -n "$(ls -A "$HOME/.local/share/xtool" 2>/dev/null)" ]; then
    echo "auth: present at $HOME/.local/share/xtool"
  else
    echo "auth: missing — run: $HOME/.local/bin/xtool auth"
  fi
}

# Vendor Swift tarballs (the swift.org ubi9/ubuntu builds, which is what mise
# installs) link the narrow curses sonames RHEL and Debian ship. Arch builds
# ncurses wide-only, so libncurses.so.6, libform.so.6 and libpanel.so.6 do not
# exist here and the toolchain dies at load with "error while loading shared
# libraries"; mise reports a bare exit 127 and rolls the install back
# (FINDINGS.md item 21). The wide libraries serve these callers: the Swift
# toolchain imports no wide-char curses symbols and records no symbol-version
# requirement, so ldd -r resolves clean against them.
#
# The aliases go in a private directory, never /usr/lib: pacman owns that, an
# unowned alias there survives ncurses updates silently, and it would shadow
# the narrow ABI for every other binary on the system.
CURSES_COMPAT_DIR="${CURSES_COMPAT_DIR:-$HOME/.local/lib/curses-narrow-compat}"

curses_compat() {
  mkdir -p "$CURSES_COMPAT_DIR"
  echo "== curses compat aliases in $CURSES_COMPAT_DIR =="
  linked=0
  for stem in ncurses form panel menu tinfo; do
    narrow="lib${stem}.so.6"
    wide="/usr/lib/lib${stem}w.so.6"
    [ -e "/usr/lib/$narrow" ] && continue   # host ships the narrow name already
    [ -e "$wide" ] || continue              # no wide twin to alias
    ln -sfn "$wide" "$CURSES_COMPAT_DIR/$narrow"
    echo "  $narrow -> $wide"
    linked=$((linked + 1))
  done
  if [ "$linked" -eq 0 ]; then echo "  nothing to alias (host already complete)"; fi

  # Optional: verify against an extracted toolchain root ($1).
  if [ -n "${1:-}" ]; then
    if [ ! -d "$1" ]; then
      echo "Not a directory: $1" >&2
      return 1
    fi
    echo "-- verifying $1 --"
    unresolved=$(
      export LD_LIBRARY_PATH="$CURSES_COMPAT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      { find "$1" -path '*/bin/*' -type f -perm -u+x
        find "$1" -name '*.so*' -type f; } 2>/dev/null |
        while read -r f; do ldd -r "$f" 2>/dev/null | grep -E 'not found' || true; done |
        awk '{print $1}' | sort -u
    )
    if [ -n "$unresolved" ]; then
      echo "still unresolved (no wide twin on this host):"
      echo "$unresolved" | sed 's/^/  /'
      return 1
    fi
    echo "  all sonames resolve"
  fi

  cat <<EOF

Put the directory on the loader path in your SHELL before installing:

  export LD_LIBRARY_PATH="$CURSES_COMPAT_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
  mise install swift@6.3.3

It must be the shell environment. mise does not apply mise.toml [env] to the
post-extract "swift --version" check, so the install still fails exit 127
after re-downloading the whole toolchain.

This repo's own install path (AUR swift-bin) does not need any of this; the
package links the wide libraries directly. FINDINGS.md item 15 still applies:
a mise-installed 6.4.x toolchain cannot build against the darwin SDK.
EOF
}

if [ "${1:-}" = "--curses-compat" ]; then
  curses_compat "${2:-}"
  exit 0
fi

if [ "${1:-}" = "--repair" ]; then
  # Toolchain swapped out from under a working setup (mise, asdf, manual
  # reinstall): repair runs against whatever toolchain the current shell
  # resolves, so the SDK is re-registered into THAT toolchain. Pairing and
  # Apple ID auth live in user-global paths and were never affected.
  if ! command -v swift >/dev/null 2>&1; then
    echo "No swift on PATH. Activate your toolchain first — for mise:"
    echo '  eval "$(mise activate bash)"   # or reopen your shell'
    exit 1
  fi
  swift --version | head -n1
  cached=$(ls -dt "$SDK_CACHE"/darwin-*.xtoolsdk 2>/dev/null | head -n1 || true)
  if [ -n "$cached" ]; then
    sdk_install_from "$cached"
  elif [ -n "${XCODE_XIP:-}" ] && [ -f "$XCODE_XIP" ]; then
    cached="XCODE_XIP=$XCODE_XIP"
    sdk_build_and_install "$XCODE_XIP"
  else
    echo "No cached SDK in $SDK_CACHE and no XCODE_XIP given."
    echo "Nothing to repair from. Either point XCODE_XIP at an Xcode 26.x .xip,"
    echo "or run once with XCODE_XIP to build the cache for next time."
    exit 1
  fi
  swift sdk list   # must print: darwin
  survive_status "$cached"
  exit 0
fi

echo "== 1. usbmuxd (device multiplexer; udev starts it on plug) =="
sudo pacman -S --needed --noconfirm usbmuxd
# usbmuxd.service is static on Arch: it is triggered by udev, do not enable it.

echo "== 2. Swift toolchain (AUR binary package: swift, clang, lldb) =="
yay -S --needed --noconfirm swift-bin
# lldb links a specific libpython3.x, and swift-bin's own optional-dep note
# names the right one (python39 through 6.3.x, python312 from 6.4). Install
# whatever the installed package asks for; without it lldb fails to start
# with "libpython3.9.so.1.0: cannot open shared object file".
pydep=$(pacman -Qi swift-bin | grep -oE 'python3[0-9]+' | head -n1)
if [ -n "$pydep" ]; then yay -S --needed --noconfirm --asdeps "$pydep"; fi
# Known-bad combination (2026-09-16): Swift 6.4.0's SwiftPM cannot consume
# the xtool darwin SDK bundle and every app build dies at planning with
# "unable to find platform for 'iphoneos'". Swift 6.3.3 works. AUR swift-bin
# tracks current releases, so warn when a 6.4+ toolchain landed.
if swift --version 2>/dev/null | grep -q "Swift version 6.3"; then
  : # proven-good toolchain line
else
  echo "WARNING: Swift 6.4+ cannot build against the xtool darwin SDK yet"
  echo "  (see FINDINGS.md item 15). If your build later fails with"
  echo "  'unable to find platform for iphoneos', build AUR swift-bin 6.3.3"
  echo "  from the package's git history (git checkout the 6.3.3 commit in"
  echo "  https://aur.archlinux.org/swift-bin.git, then makepkg) and reinstall."
  echo "  If makepkg dies extracting or builds hit I/O error 122, /tmp tmpfs"
  echo "  is full — rerun with TMPDIR=\$HOME/tmp (FINDINGS.md item 18)."
fi

echo "== 3. Toolchain tree ownership (sudo; contents are not modified) =="
# xtool's SDK install copies headers out of /usr/lib/clang and /usr/lib/swift
# with swift-corelibs FileManager.copyItem, which preserves file ownership.
# Copying a file as anyone but its owner dies partway with
# NSCocoaErrorDomain Code=513, so both trees must belong to the user running
notself=$(find /usr/lib/clang /usr/lib/swift ! \( -user "$USER" -a -group "$(id -gn)" \) -print -quit 2>/dev/null || true)
if [ -n "$notself" ]; then
  echo "Files in /usr/lib/clang or /usr/lib/swift are not owned by $USER."
  echo "Taking ownership (sudo). No file contents change."
  sudo chown -R "$USER:" /usr/lib/clang /usr/lib/swift
fi

echo "== 4. xtool AppImage (aarch64 and x86_64 releases) =="
mkdir -p "$HOME/.local/bin"
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
  -o "$HOME/.local/bin/xtool"
chmod +x "$HOME/.local/bin/xtool"
"$HOME/.local/bin/xtool" --version

echo "== 5. pymobiledevice3 in a venv =="
python3 -m venv "$VENV"
"$VENV/bin/pip" install pymobiledevice3
"$VENV/bin/pip" show pymobiledevice3 | sed -n 's/^Version: /pymobiledevice3 /p'

echo "== 6. iOS SDK source =="
# The SDK artifacts exist only inside Apple's Xcode distribution; there is no
# standalone iOS SDK download. The public route needs no Mac and no macOS
# anywhere: download Xcode.xip from Apple on any OS, hand the file to this
# script. (An already-extracted Xcode.app tree also works via SDK_SRC.)
echo "-- Route A (default): Xcode.xip downloaded from Apple --"
# 1. Sign in at https://developer.apple.com/download/all/?q=Xcode (free Apple ID)
# 2. Download an Xcode 26.x .xip — its Swift must match swift-bin (26.x for
#    6.3.3; Xcode 27's SDK is rejected — FINDINGS.md items 15-16)
# 3. Re-run:  XCODE_XIP=/path/to/Xcode.xip $0

echo "-- Route B (optional): an extracted Xcode.app tree --"
# If you already have a Mac with a matching Xcode, only these pieces are
# needed (about 3 GB) in $SDK_SRC/Xcode.app/Contents/Developer:
#   Toolchains/XcodeDefault.xctoolchain/usr/lib/{swift,swift_static,clang}
#   Platforms/{iPhoneOS,MacOSX,iPhoneSimulator}.platform/Developer/{SDKs,Library,usr/lib}
#   ssh MAC_HOST 'cd /Applications/Xcode.app/Contents/Developer && tar -cf - \
#     Toolchains/XcodeDefault.xctoolchain/usr/lib/swift \
#     Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static \
#     Toolchains/XcodeDefault.xctoolchain/usr/lib/clang \
#     Platforms/iPhoneOS.platform/Developer/SDKs \
#     Platforms/iPhoneOS.platform/Developer/Library \
#     Platforms/iPhoneOS.platform/Developer/usr/lib \
#     Platforms/MacOSX.platform/Developer/SDKs \
#     Platforms/MacOSX.platform/Developer/Library \
#     Platforms/MacOSX.platform/Developer/usr/lib \
#     Platforms/iPhoneSimulator.platform/Developer/SDKs \
#     Platforms/iPhoneSimulator.platform/Developer/Library \
#     Platforms/iPhoneSimulator.platform/Developer/usr/lib' \
#   | tar -xf - -C "$SDK_SRC/Xcode.app/Contents/Developer"

echo "== 7. Darwin SDK registration =="
# IMPORTANT: The Swift toolchain's own clang must come first in PATH.
# A system clang of a different version causes __builtin_bit_cast size errors
# when compiling SwiftUI against the SDK.
export PATH="$SWIFT_BIN_DIR:$PATH"
if swift sdk list 2>/dev/null | grep -q darwin; then
  echo "Darwin SDK already registered; skipping install."
elif [ -n "${XCODE_XIP:-}" ] && [ -f "$XCODE_XIP" ]; then
  sdk_build_and_install "$XCODE_XIP"
elif [ -d "$SDK_SRC/Xcode.app" ]; then
  sdk_build_and_install "$SDK_SRC/Xcode.app"
else
  echo
  echo "==================================================================="
  echo " One download left: the iOS SDK comes from Apple, inside Xcode.xip."
  echo " No Mac needed — the download works from any OS with a browser."
  echo
  echo " 1. Sign in (free Apple ID):"
  echo "      https://developer.apple.com/download/all/?q=Xcode"
  echo " 2. Download Xcode 26.x (.xip) — NOT 27 (SDK/toolchain must match:"
  echo "      Xcode 26.x pairs with swift-bin 6.3.3; see FINDINGS.md 15-16)."
  echo " 3. Re-run:"
  echo "      XCODE_XIP=/path/to/Xcode.xip $0"
  echo
  echo " Already installed before with this script? The SDK cache in"
  echo " $SDK_CACHE may still have the bundle — try: $0 --repair"
  echo "==================================================================="
  exit 1
fi
swift sdk list   # must print: darwin

# If an app that failed against an earlier or broken SDK still fails now, the
# stale module cache is the cause: delete that project's .build directory (or
# build in a fresh copy of the project) and rebuild.

echo "== 8. Apple ID sign-in (interactive, needed before device deploys) =="
echo "Run: $HOME/.local/bin/xtool auth"
echo "Done. Next: plug in the iPhone and run ./device-run.sh"
