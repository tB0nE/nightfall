# Meteor managed-host releases

Meteor's Linux host is a separately versioned portable package from
[tB0nE/Vibepollo](https://github.com/tB0nE/Vibepollo). Nightfall's APK, Meteor and
the host do not share a version number. Changing a host release does not publish
new APKs, AppImages, Windows installers or macOS applications automatically.

## Current Linux pin

Meteor-Vibepollo **0.1.0-preview.6**, tag
[`meteor-vibepollo-v0.1.0-preview.6`](https://github.com/tB0nE/Vibepollo/releases/tag/meteor-vibepollo-v0.1.0-preview.6),
adds the paired Host Cursor API. Source commit:
`805235cf73ee37e5db334aba78b08a933ad84fbb` (Vibepollo 2.0.6 baseline).

- Archive: `Meteor-Vibepollo-0.1.0-preview.6-linux-x86_64.tar.zst`
- Bytes: `30759727`
- SHA-256: `b1199a053a9f8512fa4fe0c0cfc325f292fac33d8c514c0a72cf127c6b597b0c`
- Matching source archive and checksum files accompany the binary.
- Linux x86_64, glibc 2.35+. Graphics drivers and desktop/audio services are
  provided by the operating system. Do not substitute this package on Windows
  or macOS; their installers/application bundles carry platform-specific hosts
  and must be built from a revision containing the cursor implementation.

`meteor/src/host/install.rs` pins version, public URL, exact size and digest.
The downloader verifies the archive, safely extracts it, verifies installed
files against the manifest and keeps the prior installed version for rollback.
Settings/pairings are outside the archive. A new pin takes effect in a new
Meteor build; already-distributed Meteor versions retain their original pins.
A custom `host_binary` override can also keep a development package selected.

The API is `GET /polaris/v1/session/status` and
`POST /polaris/v1/session/cursor` with `{"visible": true|false}`. It requires
paired TLS and stream-view permission, rejects invalid/oversized input, and
shares an atomic cursor request with the existing keyboard shortcut. Capture
backends receive a local bool refreshed between frames, not a mutable pointer
shared with an HTTP thread. This controls captured-video cursor inclusion, not
cursor size, desktop theme or Nightfall's own pointer.

## Preparing a release

Use the host fork's `packaging/meteor/README.md` and scripts. Commit source
first; do not publish a dirty-tree package or reuse a development archive under
a production filename. Build the optimized Linux target in its documented
Ubuntu container. Package with an explicit `METEOR_HOST_VERSION`, and create
the source companion from that same clean commit and initialized dependencies.

Before publishing:

1. Run the focused cursor-state test and relevant capture/geometry tests.
2. Verify every manifest digest, source revision and `source_dirty=false`.
3. Check the executable in a relocated extraction, its relative library paths
   and glibc baseline. Do not start another desktop capture just to check metadata.
4. Upload binary, matching sources and checksums to a draft host prerelease.
5. Check remote sizes/digests, publish, then verify a download from the public URL.
6. Update Meteor's pin from the actual uploaded bytes. Run unit/repository checks
   and the installer's real `--download-host` path using isolated XDG directories.
7. Ship a new Meteor artifact through the normal release process. This package
   release alone does not update existing users' applications.

To exercise the actual downloader without changing the selected/running host:

```sh
XDG_DATA_HOME=/tmp/nightfall-host-download-data \
XDG_CONFIG_HOME=/tmp/nightfall-host-download-config \
meteor/target/release/nightfall-meteor --download-host
```

Use a build containing the intended pin. Keep isolation directories separate
from real profiles. Do not reset credentials or pairings as an update test.

## Remaining validation

Concurrent visibility/shortcut tests and packaging checks do not establish
capture support on every desktop/backend. Confirm captured-video inclusion on
actual X11/Wayland streams; modern AMD/Intel and Windows/macOS need their normal
platform acceptance. The development package had been tested on this PC; that
is not a blanket compatibility claim.

## Preview.6 verification record

Published 2026-11-12. All four remote asset sizes and SHA-256 digests matched
the local binary, source companion and checksum files. The final binary archive
was extracted outside the checkout: all 389 manifest files verified and the
relocated executable reported the correct source commit. Meteor built with the
new pin then downloaded and installed the public package through
`--download-host` under an isolated XDG profile. No running host, pairings or
user configuration was changed. The unit check passed 198 Rust tests and the
GDScript suite. These checks do not replace real cursor-inclusion acceptance on
each capture backend.
