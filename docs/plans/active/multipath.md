# Multipath: send the stream over every network path

Status: working prototype, 2026-11-15. Opt-in on the client
(`NF_MULTIPATH_REMOTE`); Meteor's side is always on and inert without a
second path.

## Why

A headset can reach the PC over more than one network at once. The Steam
Frame has two radios: Wi-Fi to the router, plus a dedicated 6 GHz link to
Valve's USB adapter in the PC (the adapter is an ordinary Wi-Fi network:
the headset runs an access point, the PC joins it). On a weak Wi-Fi
link every lost video packet costs a whole frame plus a wait for a
keyframe. Sending every packet over both paths and keeping whichever copy
arrives first removes nearly all of that: the two radios rarely lose the
same packet.

## Design

- **Client (moonlight-common-c, overlay patch
  `0004-multipath-second-path.patch`):** with `NF_MULTIPATH_REMOTE` set to
  the PC's IPv4 address on the second network, the video and audio streams
  open a second UDP socket, send their keep-alive pings over both, and the
  receive loop reads whichever socket has a packet. The RTP queues already
  reject duplicate sequence numbers, so the slower copy is simply dropped.
  Without the variable nothing changes (`recvUdpSocketMultipath()` falls
  through to `recvUdpSocket()`).
- **Meteor (`meteor/src/proxy.rs`):** video/audio pings carry the session's
  16-byte payload (Sunshine's `X-SS-Ping-Payload`). A new address pinging
  with a payload an existing flow already uses is another path of that
  client: it becomes an extra destination of the flow, and its pings are
  not forwarded, so the host still sees one peer. Every packet from the host
  goes to the flow's address and to each extra path that pinged within
  `MULTIPATH_IDLE` (3 s); a flow address that stops pinging while another
  path is alive stops getting copies. Every path counts as the streaming
  client for depth and the microphone. Whichever path's ping arrives first
  owns the flow; the order doesn't matter.
- Nothing changes in the host (Sunshine and its forks).

## Safety: a weak second path must never hurt the main one

Found on a Steam Frame two rooms away from the PC: the adapter link at
-76 dBm turned a smooth Wi-Fi stream into ~13 fps.

- **Only with Meteor.** Meteor's `/meteor` reply advertises
  `"multipath": {"protocol": 1}`; the client opens the second path only when
  the stream goes through such a Meteor (`LiSetMultipathRemote()` per
  stream). A plain host sends the stream to whichever path pinged last.
- **Meteor never waits for a path, and every path is equal.** Which path
  owns a flow is just whichever pinged first, so the slow one can be the
  owner. On Linux each path of a multipath client gets its own socket on the
  listener's port (`SO_REUSEPORT`, connected to that address; the kernel
  hands it that address's packets), so each path's send queue is its own:
  a copy is dropped when its path has more than a quarter of its send
  buffer unsent (`SIOCOUTQ`), and nothing ever waits. Elsewhere the
  listener is shared (owner waited for, extras skipped on a backlog).
- **The client rests whichever path falls behind**, main or second, never
  both: when one delivers under half of the other's packets for two 2 s
  windows, its pings stop (Meteor stops sending to it 3 s later) and it is
  tried again after 30 s, doubling up to 4 min while it keeps failing.
  When the flow's owning path rests, Meteor forwards the other path's pings
  to the host so it doesn't end the session.
- **A setting**: Stream tab > Multipath (Auto / Off), shown where a second
  network is configured.
- The status bar shows `2 paths <main>k/<second>k pkt/s`,
  `main path paused (too slow)`, `2nd path paused (too slow)` or
  `1 path (host can't use 2)`.

## Results (Steam Frame, Sunshine behind Meteor, 3440x1440 HEVC)

| | Dropped frames/min |
|---|---|
| Wi-Fi only, weak spot | 116-138 |
| Wi-Fi + Frame adapter, multipath | 0-2 |

Both radios each carried the full ~120 Mbit/s stream. Meteor's tests cover
fan-out to two paths, one host peer, depth/mic acceptance from both paths,
and a path that goes quiet.

## Trying it

1. Give the PC an address on the second network (for the Frame: plug in the
   adapter, enable Wi-Fi so NetworkManager can bring up Steam's profile, and
   turn off the adapter's Wi-Fi power saving, which otherwise drops most
   packets). Allow Meteor's ports from the headset's second address too.
2. Start Nightfall with `NF_MULTIPATH_REMOTE=<PC's address on that network>`
   and connect as usual (over the first network).
3. Meteor logs `video multipath: <addr> is another path of <addr>`; Nightfall
   logs `Multipath: second path to <addr>:<port>`.

## Next

- Discovery instead of the environment variable: Meteor's `/meteor` reply
  lists the PC's addresses; Nightfall tries each from each local interface.
- Duplicate the client's own upstream (input/control) too: small traffic,
  but the same benefit for input loss.
- Accept extra paths only from the PC's own local subnets (today anyone who
  can see a session's pings could ask for a copy of its stream).
- A setting in the Stream tab, and stats per path.
