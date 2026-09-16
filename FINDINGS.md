# Findings: getting an iOS build and debug loop working on Omarchy Linux

Everything below came out of one session on 2026-09-09, taking a 13" M1 MacBook Pro
running Omarchy from a bare install to a SwiftUI app running and debuggable on an
iPhone 16 Pro Max (iOS 26.6.1). Fourteen things broke in the first run, and a
fifteenth surfaced on 2026-09-16. Each is recorded with the
error text, the root cause where it was found, and the fix. `install-toolchain.sh`
applies every fix that can be automated (items 1 to 7); only Apple ID sign-in and
sudo consent genuinely need a human.

Versions: Swift 6.3.3 (AUR `swift-bin`), xtool 1.19.0, LLDB 21.0.0, pymobiledevice3
from PyPI, iPhoneOS SDK 26.5 taken from Xcode 26.6.

Confirmed on x86_64 (community report, Jon Kinney, 2026-09-15): the same flow
works on a Framework Desktop with an iPhone 16, used for a real client project.

## Toolchain

**1. No Swift in the Omarchy or Arch repos.** AUR `swift-bin` is the binary package:
about 3.3 GB installed, roughly 7 minutes. It ships clang and LLDB too.

**2. LLDB will not start: `libpython3.9.so.1.0: cannot open shared object file`.**
`swift-bin` lists a matching `python3xx` as an optional dependency and LLDB is the
thing that needs it; the install script reads that note off the installed package
and installs it (python39 through 6.3.x, python312 from 6.4).

**3. `usbmuxd.socket` does not exist on Arch.** Guides tell you to enable it.
`usbmuxd.service` is static here and udev starts it when a device is plugged in.
Nothing to enable; `systemctl is-active usbmuxd` reads `active` once the phone is
connected.

## SDK

**4. `xtool sdk install` dies partway through copying.** It failed at 76,600 files
with `NSCocoaErrorDomain Code=513 "You don't have permission to save the file"`
while copying `/usr/lib/clang/22/include/fuzzer`. Root cause: swift-corelibs
`FileManager.copyItem` preserves ownership, so it calls `lchown` to root, which is
EPERM for a normal user. Fix: take ownership of the toolchain trees first,
`sudo chown -R "$USER:" /usr/lib/clang /usr/lib/swift` (the colon matters:
copyItem restores the group too, so it must be the user's login group). The
install script does this automatically before the SDK install.

**5. The SDK installs "successfully" and then SwiftUI will not compile.** The error
is `size of '__builtin_bit_cast' source type 'int' does not match destination type
'int64_t'` inside the simd/arm_neon C++ module. Root cause: xtool copies the clang
headers it finds on PATH into the SDK bundle. The system clang here is 22.1.8 while
the Swift compiler's own clang frontend is 21.0.0, and the headers are not
compatible across that gap. Fix: run the SDK install with the toolchain's clang
first on PATH, `PATH=/usr/lib/swift/bin:$PATH xtool sdk install ...`. The
install script exports that PATH itself before installing the SDK.

**6. A poisoned module cache survives the fix.** After rebuilding the SDK correctly,
the same project in the same directory kept failing with the same error. Fix: build
in a clean project directory, or delete `.build/arm64-apple-ios` before rebuilding.
The install script prints this cleanup note after the SDK install.

**7. No `.xip` and no Apple ID are needed for the SDK.** xtool 1.19.0 accepts a path
to an extracted `Xcode.app` directory, not only an `Xcode.xip`
(`SDKCommand.swift`: "Path to Xcode.xip, Xcode.app, or darwin.xtoolsdk"). If any
machine on your network has Xcode installed, stream the pieces xtool wants (about
3 GB) instead of downloading a multi-gigabyte archive behind a sign-in.

## Signing and install

**8. `xtool auth` password mode works with a free Apple ID.** Mode 1 uses private
APIs; mode 0 wants a paid membership and an API key. 2FA is prompted once. If your
Apple ID belongs to more than one team, it asks which team to sign under.

**9. `xtool dev run` is the whole loop.** Build, unpack, prepare device, provision,
sign, package, connect, install, verify. It took 11 seconds on this M1 with a warm
build, and the app launched on the phone with no further steps.

## Debugging, iOS 17 and later

These four are the ones that cost the most time, because the tools report the same
generic error for several different unmet prerequisites.

**10. `pymobiledevice3 developer debugserver start-server` fails on iOS 26**, even
with `--rsd` passed correctly. It prints a five-item list of possible causes, none
of which applies. Use `pymobiledevice3 developer debugserver lldb <bundle-id>
--rsd <address> <port>` instead: it starts debugserver and drives LLDB itself.

**11. The same generic error appears when the personalized developer image is not
mounted.** Check with `pymobiledevice3 mounter list` (an empty `[]` means nothing is
mounted), then `pymobiledevice3 mounter auto-mount`. It fetches a personalized image
through TSS and mounts it in a few seconds.

**12. `debugserver lldb` takes the bundle id as a positional argument.** There is no
`--bundle-id` option; passing one exits 2.

**13. The RemoteXPC tunnel needs root.** `sudo pymobiledevice3 lockdown start-tunnel`
creates `tun0` and prints the RSD address and port to pass to every later
`--rsd` call. Without sudo it cannot create the interface.

**14. Expect a long wait on attach, not a hang.** LLDB parses symbol tables out of
the device's shared cache before the process stops. On this 16 GB M1 that took about
90 seconds, printing a long stream of "Reading binary from memory" lines. The
successful result looks like this:

```
Attaching to pid 45977
platform select remote-ios
process connect connect://[fd57:f2c9:d44a::1]:63592
process attach --pid 45977
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
```

## Known regression, 2026-09-16

**15. Swift 6.4.0 cannot build against the xtool darwin SDK.** AUR `swift-bin`
6.4.0 installs fine, the SDK registers fine (`swift sdk list` prints `darwin`),
and then every app build dies at planning with `error: unable to find platform
for 'iphoneos'`. Proven by an isolated A/B on one machine, one user, one SDK
bundle: the build fails under 6.4.0 with both xtool 1.19.0 and 1.19.2, and
succeeds the moment the system runs swift-bin 6.3.3 again. The bundle metadata
is identical in both cases (schemaVersion 4.0, same toolset.json), so the
regression is on the SwiftPM side. Workaround: run swift-bin 6.3.3 (build it
from the AUR package's git history). `install-toolchain.sh` warns when it
installs a 6.4+ toolchain. Confirmed on aarch64 and x86_64.

**16. The streamed SDK's Xcode must match the Linux Swift version.** The SDK
pieces carry Apple's prebuilt swiftmodules, and the Linux compiler refuses a
module built by a newer Apple Swift: an iOS 27.0 SDK from Xcode 27 (Apple
Swift 6.4) fails under swift 6.3.3 with `this SDK is not supported by the
compiler (the SDK is built with 'Apple Swift version 6.4 ...', while this
compiler is 'Swift version 6.3.3 ...')`. The matrix, all tested 2026-09-16:

| Linux toolchain | SDK source | Result |
|---|---|---|
| swift 6.3.3 | Xcode 26.6 (iOS 26.5) | builds; Mach-O produced |
| swift 6.3.3 | Xcode 27 (iOS 27.0) | rejected: SDK built by Apple Swift 6.4 |
| swift 6.4.0 | Xcode 26.6 (iOS 26.5) | planning failure, item 15 |
| swift 6.4.0 | Xcode 27 (iOS 27.0) | planning failure, item 15 |

Rule: stream pieces from an Xcode whose Swift is 6.3.x (Xcode 26.x) while
swift-bin is on 6.3.3. When the Mac's Xcode moves past the working pair, the
fix has to come from upstream (item 15 or a newer xtool SDK format).

## Working sequence

```bash
# once
./install-toolchain.sh          # handles python dep, chown, PATH, SDK install
xtool auth                      # mode 1, Apple ID, 2FA, pick team

# per app
xtool new HelloOmarchy && cd HelloOmarchy
PATH=/usr/lib/swift/bin:$PATH xtool dev run

# debugging, phone connected, Developer Mode on
pymobiledevice3 mounter auto-mount
sudo pymobiledevice3 lockdown start-tunnel     # note the RSD address and port
PATH=/usr/lib/swift/bin:$PATH pymobiledevice3 developer debugserver lldb \
  <bundle-id> --rsd <address> <port>
```

## Where it stands

Closed 2026-09-10, after this list was written: the source-level breakpoint.
`ContentView.describe(tick:)` at `ContentView.swift:27` was hit on device, source
lines printed, `p tick` returned `(Int) 1`. A static SwiftUI app still cannot be
breakpointed usefully: instrument the app with a `.task` timer loop so execution
reaches the breakpoint without a physical tap. Single-stepping is untested
(`next` reported an unchanged frame line, inconclusive) and needs the phone
connected for five minutes.

New on 2026-09-16 (Milestone 3): `install-toolchain.sh` applies items 1 to 7 by
itself and was proven end to end by a fresh-user install on a second M1 Omarchy
machine and in a clean x86_64 Arch container, through `swift sdk list` and a
Mach-O sample build. `device-run.sh` gained a `--network` mode (same-LAN
wireless deploy, xtool native) and an `--rsd HOST PORT PKG` mode (install to an
explicit address); both are written from the tool sources and are UNVERIFIED
until run against a phone.

**17. Wireless deploy on iOS 26 requires a host-specific RemotePairing tunnel that only a Mac can currently establish (tested exhaustively 2026-09-16).** With Developer Mode on, USB-paired, unlocked, same SSID/subnet, `EnableWifiConnections` true, an active USB RSD tunnel (`lockdown start-tunnel` succeeded), and DDI mounted, an iPhone on iOS 26.6.2 never becomes wirelessly deployable from Linux: pulling the USB cable kills the tunnel and nothing re-establishes over WiFi.

What the phone actually does on the network: every host that wants wireless debugging gets its OWN encrypted RemotePairing tunnel, advertised per-host as `<uuid>._rp-tunnel._tcp` with an ephemeral port (observed 55518/55520) on IPv6 link-local/ULA addresses. A macOS host that once enabled "Connect via Network" holds a live tunnel (devicectl: Transport `localNetwork`) — the phone accepts only that host; connections from other IPs to the tunnel port are refused. The pre-iOS-17 paths are dead on 26.6.2: `_remoted._tcp` is advertised only over USB; legacy `_apple-mobdev2._tcp` is advertised but its listener (tcp/32498) never binds; tcp/62078 accepts and then resets the lockdown handshake; usbmuxd2's WiFi heartbeat fails on the same wall. `pymobiledevice3 remote pair` needs the device to advertise `_remotepairing-manual-pairing._tcp`, which no iOS 26.6.2 settings screen we could find produces (the `remote pair-host` device-initiated flow is iOS 27+).

Practical guidance: use USB (proven end to end by this repo). Wireless works only for hosts the phone already tunneled with via a Mac/Xcode; for that case `pymobiledevice3 remote tunneld` on a Mac that holds the tunnel, plus `--tunnel UDID@HOST:PORT` from Linux, is the bridge pattern (documented in device-run.sh). The Linux side is otherwise ready: with usbmuxd2 (AUR `usbmuxd2-git` + the -git libimobiledevice stack) and pymobiledevice3, a future iOS that reopens device-side pairing needs zero new plumbing here.
