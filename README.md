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
- One of:
  - A Mac with Xcode installed (any host on your network that you can SSH
    into), or
  - `Xcode.xip` downloaded from developer.apple.com (requires an Apple ID).


Version matching matters: the SDK pieces must come from an Xcode whose Swift
matches the installed `swift-bin` (Xcode 26.x for swift 6.3.3 — see
FINDINGS.md item 16), and swift-bin 6.4.0 is not yet usable (item 15).

`xtool sdk install` accepts a path to an `Xcode.xip` **or an extracted
`Xcode.app` directory**. The directory route avoids the multi-GB download.

## Install

Run `install-toolchain.sh`. It installs the toolchain, applies the SDK-install
workarounds (toolchain-tree ownership, toolchain clang first on PATH), and
registers the SDK if source material is present. Safe to re-run. Give it SDK
material by one of:

- Directory route: stream only the pieces xtool needs from a Mac with Xcode
  (see the script, section 6) into `~/xcode-apple-sdk-src/Xcode.app`, then
  re-run the script. A tree anywhere else works too: run it as
  `SDK_SRC=/path/to/dir ./install-toolchain.sh`.
- XIP route: download `Xcode.xip` from
  https://developer.apple.com/download/all/?q=Xcode and re-run the script as
  `XCODE_XIP=/path/to/Xcode.xip ./install-toolchain.sh`.

Verify with `swift sdk list` (should print `darwin`).

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

[FINDINGS.md](FINDINGS.md) records the fifteen things that broke on the way to the
first working run, with error text, root cause, and fix for each: SDK install
failures, a clang version mismatch that breaks SwiftUI, and the four unstated
prerequisites for debugging on iOS 17 and later.

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
