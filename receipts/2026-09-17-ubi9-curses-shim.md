# ubi9 Swift on Omarchy: the missing sonames, and mise working end to end

Host jwm1-linux, Omarchy 4.0.1rc2 aarch64, ncurses 6.6-2.
mise git build at `533346cc` (post #13293 + #13297).
Tarball: `swift-6.3.3-RELEASE-ubi9-aarch64.tar.gz`, 1001 MB.

## Complete set of missing sonames

`ldd` across all of `usr/bin` + `usr/lib/*.so*`:

```
libform.so.6
libncurses.so.6
libpanel.so.6
```

Host: `libncursesw.so.6`, `libformw.so.6`, `libpanelw.so.6` present.
`libtinfo.so.6` present. `libncurses.so.6` absent.
`/usr/lib/libncurses.so` is an 18-byte linker script.

## Why narrow→wide substitution is sound here

- `liblldb.so` wide-char curses imports (`_wch|_wstr|cchar`): **0**
- narrow imports observed: `keypad`, `newwin` (plus form/panel entry points)
- Arch exports them versioned: `keypad@@NCURSES6_TINFO_5.0.19991023`,
  `newwin@@NCURSESW6_5.1.20000708`, `new_form@@NCURSESW6_…`,
  `new_panel@@NCURSESW6_…`
- `readelf -V` on `liblldb.so`: **no version requirement** recorded against
  libncurses/libform/libpanel
- `ldd -r` with the wide libs substituted: `lldb` ALL RESOLVED,
  `liblldb.so` ALL RESOLVED, zero undefined symbols, zero version warnings

Debian/Ubuntu ship a single wide-compiled ncurses providing both sonames,
so the vendor tarball is already running against a wide build there.

## Shim (no root, no /usr/lib mutation)

```bash
mkdir -p ~/.local/lib/curses-narrow-compat
ln -sf /usr/lib/libncursesw.so.6 ~/.local/lib/curses-narrow-compat/libncurses.so.6
ln -sf /usr/lib/libformw.so.6    ~/.local/lib/curses-narrow-compat/libform.so.6
ln -sf /usr/lib/libpanelw.so.6   ~/.local/lib/curses-narrow-compat/libpanel.so.6
export LD_LIBRARY_PATH=~/.local/lib/curses-narrow-compat
```

## Results with the shim

Direct from the extracted tree:

- `swiftc h.swift -o h && ./h` → `hello from ubi9 swift on omarchy`
- `lldb --version` → `lldb version 21.0.0 (… revision 82cdc19fa54d)`
- `swift package init` + `swift build` → `Build complete! (1.53s)`

Through mise:

- `mise install swift@6.3.3` → passes its own gate, printing
  `Swift version 6.3.3 (swift-6.3.3-RELEASE)` /
  `Target: aarch64-unknown-linux-gnu`; `mise ✓ swift@6.3.3 49.1s`
- `mise ls swift` → `swift 6.3.3`
- `mise exec swift@6.3.3 -- swift build` → `Build complete! (1.47s)`

## Second mise gap found

`LD_LIBRARY_PATH` set in `mise.toml` `[env]` (shell var unset) does **not**
reach the post-extract verification child:

```
mise ✗ swift@6.3.3  48.3s · failed: …/installs/swift/6.3.3/bin/swift exited with non-zero status: exit code 127
```

Same 1 GB download wasted, same bare `exit code 127` with no named library.
Two reportable items: (1) config `[env]` is not applied to the install
verification step; (2) when a fallback artifact cannot be loaded, report the
missing soname instead of `exit code 127`.

Pre-existing and unrelated: `swift runtime: unable to protect path to
swift-backtrace … disabling backtracing` appears on the AUR `swift-bin`
toolchain too.

Scratch left on jwm1: `~/tmp/ubi9-probe/`, `~/.cache/mise-retest/`.

## Upstream, 2026-09-17

- Retest comment on #13289: https://github.com/jdx/mise/discussions/13289#discussioncomment-18482797
- Retest comment on #13291: https://github.com/jdx/mise/discussions/13291#discussioncomment-18482798
- New report #13306 (ubi9 exit 127 + config [env] not reaching install verification): https://github.com/jdx/mise/discussions/13306

Shipped here as `install-toolchain.sh --curses-compat` (commit a661c15), verified
on jwm1: flag reports all sonames resolve, `mise install swift@6.3.3` passes its
own gate, `mise exec -- swift build` links and the binary prints Hello, world!
