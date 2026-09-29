# FlClash iOS memory PoC (phase 0)

A minimal native app (SwiftUI + `NEPacketTunnelProvider`, no Flutter) whose only
job is to answer one question on a real device: **does the FlClash Go core
(mihomo) fit inside the iOS Packet Tunnel extension memory limit (~50 MB
`phys_footprint`)?**

The extension runs the same Go core as Android (`core/`, built as a static
`c-archive` for `GOOS=ios`) and drives it with the same call sequence as the
Flutter app: `initClash` → `setupConfig` → `startListener` → `startTUN(fd)`.
It publishes its memory footprint to the app once a second through the App Group.

> Status: CI (`.github/workflows/ios-poc.yml`, macOS + Xcode) builds the Go
> core for the device and links the app and extension, unsigned. It also runs
> the Go core bridge smoke tests on the iOS Simulator. Nothing has run on a
> device or inside a packet tunnel extension yet. See "What CI covers" and
> "Known unverified points" below.

## Prerequisites

- A Mac with Xcode 15 or newer, and an iPhone or iPad on iOS 15 or later. The
  simulator can't run packet tunnel extensions.
- A **paid** Apple Developer Program team. Free personal teams can't sign the
  Network Extension (`packet-tunnel-provider`) entitlement.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Go 1.24 or newer (CI uses 1.24): `brew install go`
- Flutter (or a standalone Dart SDK) to run `setup.dart`
- The `core/Clash.Meta` submodule: `git submodule update --init core/Clash.Meta`

## Build

From the repository root:

```sh
# 1. Resolve setup.dart's dependencies (the root pubspec, including setup_hooks).
flutter pub get

# 2. Build the Go core for iOS (arm64, GOOS=ios, CGO, -buildmode=c-archive,
#    tags with_gvisor,with_low_memory). Needs macOS + Xcode (uses xcrun).
dart setup.dart ios
#    -> libclash/ios/libclash.a, libclash/ios/libclash.h, libclash/ios/bride.h

# 3. Set your team, bundle id and App Group at the top of ios-poc/project.yml
#    (DEVELOPMENT_TEAM, POC_BUNDLE_ID, POC_APP_GROUP).

# 4. Generate and open the Xcode project.
cd ios-poc
xcodegen
open FlClashPoC.xcodeproj
```

In Xcode, select the `FlClashPoC` scheme and your device, then Run. Automatic
signing should register both bundle ids, the App Group and the Network
Extension capability. If it doesn't, create them in the developer portal:
- App id `POC_BUNDLE_ID` and `POC_BUNDLE_ID.PacketTunnel`
- Both with the App Groups capability (`POC_APP_GROUP`) and Network Extensions

Rebuild with step 2 whenever `core/` changes. Xcode only relinks the `.a`.

## Use

1. **Use sample config** or **Import YAML file…**, then **Save config**. This
   writes `config.yaml` into `<App Group>/clash/`, which is also the Go home dir.
2. **Install / save VPN profile** (iOS asks for permission once).
3. Pick a TUN stack (default `mixed`, same as FlClash), then **Start**.
4. Watch the **Extension memory** section. It refreshes every second.

Tunnel parameters match Android's `VpnService`: address `172.19.0.1/30`,
default route, DNS `172.19.0.2` (hijacked by mihomo), MTU 9000. There's no IPv6.

## What to observe

- **phys_footprint**: the number jetsam compares against the limit. Xcode's
  memory gauge shows the same number when attached to the `PacketTunnel` process.
- **Peak**: the highest value since the tunnel started.
- **Available before limit** (`os_proc_available_memory()`) and **Implied limit**
  (footprint + available): the actual limit on this device and OS version.

Suggested runs, recording the peak for each:
1. The sample config (DIRECT only), idle and then during a speed test
2. A realistic subscription with proxy groups, rule providers and GEOIP rules
3. Each of `mixed`, `system` and `gvisor`
4. After **Force GC in extension**. This calls `forceGC` → `runtime.GC()` +
   `debug.FreeOSMemory()` on iOS.

If the extension goes over the limit, iOS kills it. The tunnel drops to
"disconnected" and a `JetsamEvent` report appears under Settings → Privacy &
Security → Analytics Data.

The Go heap is soft-limited to 35 MB via `debug.SetMemoryLimit` (see
`core/lib_ios.go`). A `GOMEMLIMIT` environment variable takes precedence, but
the system launches the extension, so you can't easily set one. To try other
values, change `defaultIOSMemoryLimit` and rebuild. This limit covers the Go
runtime only. It isn't a hard cap on the process.

## Simulator smoke tests

`CoreSmokeTests` is a hostless unit-test bundle that drives the Go core
through `PacketTunnel/ClashCore.swift` on the iOS Simulator: Go runtime start
in an iOS process, the `bride.h` callbacks (result, `release_object`,
`free_string`), JSON method round trips, config parsing, the mixed listener
(including an HTTP request proxied to a loopback server), `forceGc`,
callback release after 200+ invokes, `stopListener` and `shutdown`. It needs
no signing, entitlements or network access. CI runs it on every push
(`.github/workflows/ios-poc.yml`).

```sh
# From the repository root: Apple Silicon simulator build of the core.
dart setup.dart ios --simulator
#    -> libclash/ios-simulator/libclash.a, libclash.h, bride.h
cd ios-poc && xcodegen
xcodebuild test -project FlClashPoC.xcodeproj -scheme CoreSmokeTests \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The test target picks `libclash/ios-simulator` or `libclash/ios` per SDK.
The TUN path, the extension sandbox and the real memory limit can only be
tested on a device.

## Debugging

- Console.app: filter on subsystem `FlClashPoC` for stage transitions, the
  chosen utun fd and forwarded core warnings and errors.
- The app shows `lastError` and the last 20 core warning and error log lines.
  Set `log-level: warning` or higher so log forwarding doesn't skew the memory
  numbers.
- To attach the debugger: Debug → Attach to Process → `PacketTunnel` (after Start).

## Layout

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen spec: app + packet tunnel extension, App Group, NE entitlements, links `../libclash/ios/libclash.a` into the extension only |
| `Shared/Shared.swift` | App Group id (from Info.plist), shared defaults keys and paths |
| `Shared/Memory.swift` | `task_vm_info.phys_footprint` |
| `App/` | SwiftUI UI: profile install/start/stop, config editor/import, memory display |
| `PacketTunnel/PacketTunnelProvider.swift` | Network settings, core start/stop, memory reporter |
| `PacketTunnel/ClashCore.swift` | Swift side of `core/bride.h` callbacks + `invokeMethod` JSON calls |
| `PacketTunnel/TunnelFD.swift` | Finds the utun fd (scan fds for `UTUN_OPT_IFNAME`, KVC fallback) |
| `PacketTunnel/PacketTunnel-Bridging-Header.h` | Imports `libclash.h` and `bride.h` |
| `CoreSmokeTests/` | Simulator XCTest bundle for the Go core bridge (see above) |

## What CI covers

- **Device build.** `dart setup.dart ios` (clang with the iPhoneOS SDK) and an
  unsigned `xcodebuild` of the app and the `PacketTunnel` extension for
  `iphoneos`. The extension compiles and links against `libclash.a` with
  `-lclash -lresolv` plus the NetworkExtension, Security and CoreFoundation
  frameworks. Code signing and the entitlements themselves aren't checked.
- **Simulator runtime (`CoreSmokeTests`, Address Sanitizer on).** The Go
  runtime starts in an iOS process, including package `init()`s such as the
  `/dev/null` open in `core/platform/limit.go` and the 35 MB
  `SetMemoryLimit`. The tests also cover the `bride.h` callbacks and their
  retain/release, `initClash`, `setupConfig` with valid and invalid configs,
  the mixed listener proxying HTTP over DIRECT, the `getProxies`,
  `getTraffic`, `getConnections` and `getMemoryStats` methods (the last goes
  through purego `dlopen`), `forceGc`, the exported
  `getTraffic`/`getTotalTraffic` C strings, `stopListener` and `shutdown`.

## Known unverified points

These need a device:

- **The extension sandbox.** CI never loads the extension, so App Group
  access, `/dev/null` and file access inside the Network Extension sandbox are
  untested. The simulator tests run the core in a plain test process.
- **Memory.** The ~50 MB extension limit, jetsam and `phys_footprint` numbers
  are what this PoC is for. The simulator can't measure them.
- **utun fd discovery.** The fd scan is the approach used by other iOS clients.
  The KVC fallback only helps on older iOS versions.
- **`core/platform/limit.go`** opens `/dev/null` in `init()` and panics if that
  fails. It works in the simulator test process. The extension sandbox hasn't
  been checked, and a failure there would crash the extension on load.
- **System DNS.** mihomo only lets the host set system DNS servers on Android.
  On iOS `updateDns` is a no-op, and mihomo's "system" resolver reads
  `/etc/resolv.conf`, which is probably unreadable or absent in the sandbox. Use
  explicit IP `nameserver`/`default-nameserver` entries in the config.
- **TUN forwarder binding.** In `core/Clash.Meta/listener/sing_tun/server.go`
  (after `tunNew`), the `getTunnelName` error check is inverted. When the utun
  name lookup succeeds, sing-tun's forwarder isn't bound to the utun interface
  (`ForwarderBindInterface` stays false). Android has always run this way. If
  the `system` or `mixed` stack doesn't pass TCP on iOS, compare with `gvisor`,
  which doesn't use that forwarder.
- **Geo data.** Unlike the Flutter app, the PoC doesn't pre-seed GeoIP, GeoSite
  or MMDB files. Configs with GEOIP or GEOSITE rules download them into the App
  Group on first start. That costs time and memory, and GeoSite matching is
  memory-heavy. Measure with and without these rules.
- **`startTUN` reports no errors.** Go only logs a TUN start failure. Check the
  error log lines in the app. `startTUN` and all TUN stacks are untested:
  the simulator can't run packet tunnels.
