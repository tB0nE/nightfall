# USB Link Streaming (Quest 3)

> Status: Active. Steps 1-5 validated on Quest 3 against a real Sunshine
> host: discovery, pairing and streaming over the cable; unplug mid-stream
> falls back to Wi-Fi and moves back to USB once the host answers over it
> again. A saved host keeps separate network and USB addresses
> (`usb_address`) and each request picks USB while the link is up.
> Host requirements: Sunshine `address_family = both` (the link is IPv6
> link-local only), and on Linux a NetworkManager profile that brings the
> USB interface up link-local-only with `ipv6.never-default yes`.
> Open: the PC-side NM profile is tied to one USB port's interface name.
> Inspired by
> [Gilleece/moonlight-android-xr#31](https://github.com/Gilleece/moonlight-android-xr/pull/31)
> (not merged there as of this writing), which proved the approach end-to-end
> against a real Sunshine host on Quest 3 / Horizon OS 2.7.

## Problem

Nightfall only ever streams over Wi-Fi. A wired connection would give more
consistent bandwidth and lower jitter (useful for PyroWave in particular,
which assumes ~200+ Mbit/s is cheap), but the existing "wired" options on
Quest all go through `adb reverse` port forwarding, which needs `adb`
running, breaks on every reconnect, and adds a userspace hop.

## What actually makes this possible

Horizon OS 2.5+ lets an app ask Android's `ConnectivityManager` for the
headset's USB-C port as a real network interface
(`NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_USB)`).
This is a **public Android API**, not a private Meta hook and not ADB - once
granted, the link shows up as a normal interface (`usb0`) with its own
address. This directly reverses what I'd assumed a few days ago (that this
would need root); the reference PR is concrete proof against real hardware.

Because it's a real IP interface, **Sunshine needs zero changes.** The
existing moonlight protocol (HTTP/HTTPS for pairing and launch, RTSP, then
RTP video/audio/control over UDP) is transport-agnostic - it just needs its
traffic routed over `usb0` instead of Wi-Fi. The entire job is making our
networking code use that interface; nothing server-side changes.

## Why this is non-trivial anyway

The USB link has no default route and no DNS. Two problems follow directly:

1. **Discovery.** Our existing `MdnsBrowser` (own raw-socket mDNS client,
   `addons/nightfall-stream/src/network/mdns_browser.cpp`) binds `INADDR_ANY`,
   joins only the IPv4 multicast group `224.0.0.251`, and only ever resolves
   plain IPv4 `A` records (it parses `AAAA`/type 28 into the same dict as `A`
   with no v4/v6 preference - effectively accidental, not a real dual-stack
   path). None of that reaches a host that's only reachable over `usb0`:
   - The PC's `usb0`-equivalent adapter typically gets an IPv4 APIPA address
     on an independently-chosen `169.254.0.0/16` subnet - no guarantee it's
     reachable, and the reference PR found it unreliable in practice.
   - **IPv6 link-local (`fe80::/10`) is the reliable answer** - every
     interface gets one immediately, no DHCP/APIPA race, but a link-local
     address is only unambiguous together with a zone/interface scope
     (`fe80::abcd%usb0` or `%<ifindex>`).
   - Our mDNS socket also never binds to a specific interface, so even if it
     queried over IPv6 it has no reason to send/listen on `usb0` specifically
     rather than Wi-Fi.
2. **Socket binding.** Android's per-app routing means a plain socket keeps
   using whatever network Android picked as default (Wi-Fi), link-local
   destination or not. Every socket - our own libcurl HTTP client
   (`curl_http_client.cpp`) and moonlight-common-c's own UDP/RTP sockets
   (vendored, not code we maintain) - needs to be told to use the USB
   network specifically.

The reference PR's own write-up (see its "Details worth knowing" section) is
the single best source for the sharp edges here: capabilities that must be
*removed* from the request, `onLost` having to clear the request flag or the
link can never be rebuilt, the NSD re-scan needing a strict
stop-then-wait-then-start sequence, OkHttp refusing any host containing `%`
(forcing a placeholder-hostname + custom `Dns` trick), and the process-wide
network binding only covering sockets created after it's applied.

## Architecture

Nightfall is a Godot GDExtension (C++) with a thin JNI bridge to a few Java
helper classes on Android, not a pure Java app like the reference client -
so the Java-side request/discovery logic ports closely, but the two places
that actually *use* a resolved address (our curl HTTP client, and
moonlight-common-c) are both native C++, which the reference PR's
OkHttp-specific fix doesn't map onto directly - and is a simpler problem for
us, because libcurl has built-in support for exactly this
(`CURLOPT_INTERFACE`, `CURLOPT_ADDRESS_SCOPE`) with no custom-`Dns`-style
trick required.

```
Java (android/src/main/java/com/godot/game/)
  UsbLinkManager        - holds the TRANSPORT_USB NetworkRequest, reports up/down,
                          exposes the Network for bindSocket()/bindProcess()
  UsbMdnsDiscovery       - NsdManager.discoverServices(..., Network) on usb0,
                          same re-scan/stop-wait-start handling as the reference PR
  GodotApp               - static usbLinkManager instance + thin JNI-facing
                          static wrapper methods (mirrors depthEstimator's pattern)

JNI bridge (addons/nightfall-stream/src/network/)
  usb_link_bridge.cpp/h  - mirrors depth_bridge.cpp's JNI pattern exactly
                          (nightfall_get_jvm(), FindClass/GetStaticMethodID)

Native C++ (addons/nightfall-stream/src/network/)
  mdns_browser.cpp       - gains a second, IPv6/usb0-scoped query path
  curl_http_client.cpp   - sets CURLOPT_INTERFACE/CURLOPT_ADDRESS_SCOPE when
                          a USB link address is in use
  stream_connection.cpp  - binds the process to the USB network immediately
                          before LiStartConnection(), restores it after
                          disconnect or link loss (mirrors Game.java's
                          approach, done at the process level since
                          Nightfall is single-process, same granularity the
                          reference PR itself uses)

GDScript
  welcome_screen.gd / settings - a "USB Link" toggle, host-list entry shown
                          when a host is reachable over the link
```

## The real open question: moonlight-common-c and address scope - RESOLVED

Read `moonlight-common-c`'s vendored source directly
(`.build-cache/mlc-patch/upstream/src/{Connection,PlatformSockets}.c`):
`serverInfo->address` flows, completely unmodified, into exactly one place -
`resolveHostName()`'s `getaddrinfo(host, NULL, &hints, &res)` call - and the
resulting binary `sockaddr_in6` (whatever scope ended up in it) is what every
later `connect()`/`sendto()` actually uses. No custom address parsing, no
`%`-stripping, nothing else to patch.

That reduces the question to "does Android's `getaddrinfo()` resolve a
`%usb0`-suffixed numeric IPv6 literal into a correct `sin6_scope_id`?" -
tested directly on the Quest 3 with a tiny pushed-via-`adb` native binary
(not inferred): `getaddrinfo("fe80::...%usb0", ...)` returned
`sin6_scope_id=18` (the real `usb0` ifindex), while the bare literal with no
zone returned `scope_id=0` (unusable). **No moonlight-common-c patch needed
at all** - `StreamConnection::start()` just appends `%usb0` to the host
string itself before handing it to `LiStartConnection()` whenever it's a
bare `fe80:` literal, exactly mirroring the fix already applied to the HTTP
side as `_bracket_host()`+`set_bind_interface()`.

(`addrToUrlSafeString()` - the one place moonlight-common-c turns a resolved
address back into text, for its own local RTSP-URL bookkeeping - rebuilds
the string from the binary `sockaddr_in6`'s address bytes only, never the
zone, and is never sent to the server, so the `%usb0` suffix never leaks
anywhere it could break something.)

## Validation order (same philosophy as the PyroWave zero-copy plan: de-risk
before integrating, verify each step before building on it)

1. **Link only, no streaming.** `UsbLinkManager` requests `TRANSPORT_USB`,
   logs link up/down and the assigned `LinkProperties` (addresses, link
   speed). Verifiable with a USB-C cable to *any* PC - Sunshine not even
   required yet, matching exactly what the reference PR's own "Hardware...
   Quest 3, Horizon OS 2.7, over a USB 3 cable" verification did first.
2. **Discovery over the link.** `UsbMdnsDiscovery` resolves a running
   Sunshine host's scoped IPv6 link-local address over `usb0`. Verifiable via
   logcat alone (log the resolved address/scope), no stream yet.
3. **HTTP over the link.** Point `curl_http_client` at the resolved address
   with `CURLOPT_INTERFACE`/`CURLOPT_ADDRESS_SCOPE` set, confirm
   `/serverinfo` succeeds. This exercises pairing/launch, the highest-value
   partial win even if step 4 stalls.
4. **Full stream.** Bind the process, start the real stream, confirm video
   actually flows end-to-end. This is where the moonlight-common-c scope
   question gets answered for real.
5. **Lifecycle.** Disconnect/reconnect, physically unplugging mid-stream,
   leaving and restarting - matching the reference PR's own "both paths
   reset the process network" lesson learned the hard way.

## Fallback behavior

If the USB link request fails, times out, or discovery finds nothing on it,
fall back to the existing Wi-Fi flow automatically - same convention used
everywhere else in this codebase (native-XR falling back to the legacy
composition path, PyroWave's zero-copy pipeline falling back to CPU
readback). Never a hard failure; USB Link is purely additive.

## Platform gating

`minSdk=29`, `targetSdk=32` (`export_presets.cfg`); `TRANSPORT_USB` and the
`NsdManager.discoverServices(..., Network)` overload need API 31 and 34
respectively. Since every real target device is Quest 3 (Android
14-based Horizon OS), gate the whole feature behind a runtime
`Build.VERSION.SDK_INT` check and report "unavailable" below it, the same
pattern `SettingsPlatformPolicy`/`depth_gpu_priority_available()` already
use for other Android-version/device-gated features - no need for the
reference PR's `dlsym`-for-native-symbols trick, since we don't support
pre-23 devices at all.

## Critical files

`android/src/main/java/com/godot/game/UsbLinkManager.java` (new),
`android/src/main/java/com/godot/game/UsbMdnsDiscovery.java` (new),
`android/src/main/java/com/godot/game/GodotApp.java` (wiring),
`addons/nightfall-stream/src/network/usb_link_bridge.cpp/h` (new, JNI
bridge), `addons/nightfall-stream/src/network/mdns_browser.cpp/h` (IPv6/
usb0-scoped discovery path), `addons/nightfall-stream/src/network/
curl_http_client.cpp` (interface/scope binding), `addons/nightfall-stream/
src/video/stream_connection.cpp` (process binding around
`LiStartConnection`), `android/src/main/AndroidManifest.xml`
(`CHANGE_NETWORK_STATE`), `src/welcome_screen.gd` / settings (toggle, host
list integration).
