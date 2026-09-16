# Build and deploy iOS apps on Omarchy Linux (Apple Silicon and x86_64)

SwiftUI apps built on Omarchy Linux, installed on a physical iPhone over USB,
with no Xcode and no macOS in the loop.

Based on a first successful run on 2026-09-09 with:

| Tool | Version | Source |
|------|---------|--------|
| Swift | 6.3.3 (aarch64-unknown-linux-gnu) | AUR `swift-bin` |
| xtool | 1.19.0 | xtool-org/xtool AppImage |
| pymobiledevice3 | latest from PyPI at install time | venv |
| LLDB | 21.0.0 (Swift toolchain) | bundled with `swift-bin` |
| iOS SDK | iPhoneOS 26.5 | Xcode 26.6 on a Mac, streamed as a directory |

Confirmed on x86_64 (community report, Jon Kinney, 2026-09-15): the same flow
works on a Framework Desktop with an iPhone 16, used for a real client project.

Works with a free Apple ID. Paid membership not required for device installs.

## What you need

- An Apple Silicon or x86_64 Linux box running Omarchy (Arch-based). Both
  architectures are covered: AUR `swift-bin` ships aarch64 and x86_64, and
  xtool publishes an AppImage for each.
- An iOS device and a USB cable.
- An Apple ID (free) for **one download from Apple**: `Xcode.xip` from
  developer.apple.com. The download works from any OS — no Mac, no macOS
  install, and no Xcode install anywhere is needed. The iOS SDK artifacts
  exist only inside Apple's Xcode distribution, so this one download is the
  only external requirement that cannot be automated away.

Version matching matters: the SDK pieces must come from an Xcode whose Swift
matches the installed `swift-bin` (Xcode 26.x for swift 6.3.3 — see
FINDINGS.md item 16), and swift-bin 6.4.0 is not yet usable (item 15).
Download **Xcode 26.x, not 27**.

## Install

```
git clone https://github.com/joshuaswarren/omarchy-apple-dev
cd omarchy-apple-dev
./install-toolchain.sh
```

The script installs the toolchain, applies the SDK-install workarounds
(toolchain-tree ownership, toolchain clang first on PATH), and tells you
exactly what is left if anything is. Safe to re-run. When it stops at the SDK
step, download `Xcode 26.x .xip` from
https://developer.apple.com/download/all/?q=Xcode and re-run:

```
XCODE_XIP=/path/to/Xcode.xip ./install-toolchain.sh
```

Verify with `swift sdk list` (should print `darwin`).

Already have a Mac with a matching Xcode? You can stream just the ~3 GB of
SDK pieces xtool needs instead of the full .xip — see Route B in
`install-toolchain.sh` section 6. Optional; the .xip route above needs no Mac.

## First app

```
xtool new HelloOmarchy
cd HelloOmarchy
xtool dev run
```

`xtool dev build` alone produces `xtool/HelloOmarchy.app` (arm64 Mach-O).

## Device

Plug the iPhone in, tap Trust when prompted, then:

```
./device-run.sh
```

First run needs `xtool auth` (interactive, your Apple ID; password mode works
with free accounts). Pairing happens through usbmuxd on first connect.

Wireless deploy (same network as the phone): `./device-run.sh --network` —
unverified, expects a one-time USB pair first. A phone reachable only over a
VPN (Tailscale included) cannot be targeted directly; `device-run.sh` documents
the tunneld bridge pattern pymobiledevice3 supports for that case.

## Scripts

- `install-toolchain.sh`: everything up to and including the SDK install.
- `device-run.sh`: pair, install, launch, LLDB attach; `--network` and
  `--rsd` modes for wireless deploys (unverified).

## Findings

[FINDINGS.md](FINDINGS.md) records the sixteen findings behind the working
run: what broke and how each was fixed (SDK install failures, a clang version
mismatch that breaks SwiftUI, the unstated prerequisites for debugging on
iOS 17+), plus the Swift/Xcode version matrix (items 15-16).

## Notes

- `clang` on PATH must be the Swift toolchain's own clang, not the system
  clang. The SDK install copies the host clang headers into the bundle; a
  version mismatch between host clang and the Swift compiler produces
  `__builtin_bit_cast` size errors when compiling SwiftUI. Both scripts in
  this repo export that PATH themselves; prefix it by hand only when running
  xtool directly in your own shell.
- Building SwiftUI pulls in simd/arm_neon headers; first build takes about a
  minute on an M1.

## License

MIT
