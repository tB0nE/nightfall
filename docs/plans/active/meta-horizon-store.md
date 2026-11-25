# Nightfall on the Meta Horizon Store

> Status: In progress (branch `feat/meta-store`)
>
> Date: 2026-11-23
>
> First store build: 0.9.1, paid. Sideloading from GitHub stays free.

## Goal

Sell the Quest client on the Meta Horizon Store from 0.9.1, while the same app
stays free to sideload from GitHub. Meteor and the PC side keep shipping from
GitHub only.

App Lab no longer exists as a separate route. Every app goes through one set
of Virtual Reality Checks (VRCs): technical review first, then content review
("completeness, polish and value"). Meta asks for at least two weeks between
submission and the planned launch.

## Shape of the release

Two builds of one app, from one commit:

| | GitHub APK (sideload) | Store build |
|---|---|---|
| Price | free | paid |
| Package, signing key | `app.nightfall.quest`, release key | the same |
| Entitlement check | no | yes |
| Dev bridge, debug options | no | no |
| Target SDK | 34 | 34 |

The same package and key mean:
- someone who sideloaded can buy on the store and update in place, keeping
  pairings and settings;
- someone who bought can still install a GitHub APK over it.

The free sideload is a choice, not a leak: GPLv3 allows selling, and anyone
could build the source anyway. The store price pays for the convenience of
store installs and updates.

## Where the app stands

| Item | Today | Store needs |
|---|---|---|
| Target SDK | 32 in both Android presets (`NightfallDev`, `NightfallRelease`) | **34** for apps created after 1 March 2026; enforced on upload. Min SDK 29 stays. The Godot 4.7 template compiles against 36. |
| Architecture | arm64-v8a only | 64-bit (fine) |
| Entitlement check | none | Platform SDK initialised, check within 10 s of launch, no use after a failed check |
| Version code | MAJOR·10000 + MINOR·100 + PATCH; preview and stable share it | Every upload needs a higher code, so a rejected 0.9.1 couldn't be re-uploaded. Needs a build digit (below). |
| Dev bridge | only with `nightfall_dev` or debug builds | Not in the store build (verify on the APK) |
| Self-update, analytics | none | Good: nothing to remove |
| Permissions | internet, network state, Wi-Fi multicast, microphone | A reason for each, in the dashboard and the privacy policy |
| `usesCleartextTraffic` | true | Needed for plain HTTP to Meteor and Sunshine on the LAN; explain it |
| `profileable shell=true` | on | Leave it on for sideload builds; drop it from store builds |
| First run with no PC | server list | Must explain Meteor and where to get it; content review judges this screen |

## Phases

Phases 1–5 are code (agent work, headset tests). Phases 0 and 6–8 are the
user's: accounts, money, art and decisions.

### Phase 0: accounts and decisions (user)
- Meta developer organisation, verified.
- **Paid apps need payout and tax details:** a bank account and tax forms
  (for an EU-based seller, the non-US tax form), set up in the dashboard before
  a price can be set.
- Create the app. Note the **App ID**: the entitlement check needs it.
  Done: **1499244296598470** (Meta Horizon Store platform), in
  `src/store_build.gd`.
- Store title: "Nightfall" is common, so pick something distinct (for example
  "Nightfall: PC Streaming").
- Price, and whether there's a launch discount.

### Phase 1: target Android 14 (API 34)
1. Raise `gradle_build/target_sdk` to 34 in both Android presets.
2. Audit our Java (`android/src/main/java/com/godot/game/*`) and the bundled
   `.aar`s for API 33/34 behaviour changes:
   - runtime-registered broadcast receivers need an exported flag;
   - `PendingIntent`s need explicit mutability, and none may wrap implicit
     intents;
   - native code or dex loaded from writable files must be read-only;
   - Wi-Fi locks, multicast lock and `ConnectivityManager` (USB Link) still
     work;
   - the microphone permission prompt.
3. Build, install in place, and test on Quest 3 (Quest 2 if available):
   - discovery and mDNS; pairing; streaming at several resolutions;
   - PCVR handover; microphone; on-device AI depth; host depth;
   - browser; USB Link; pause/resume behind the Universal Menu.
4. `tools/verify.py unit` and `tools/verify.py quest`.

**Done when:** a target-34 build passes the tests above with no new warnings
in logcat, and the APK's manifest shows `targetSdkVersion=34`.

### Phase 2: store build and version codes
1. **Version codes with a build digit:** MAJOR·1000000 + MINOR·10000 +
   PATCH·100 + BUILD (0.9.1 → 90100). Every new code is higher than every
   old one, so existing installs still update. `--build N` (default 0) allows
   re-uploads of the same version.
2. **`build.sh --release --store`:** the release preset plus the
   `nightfall_store` export feature. In store builds:
   - the entitlement check is on (phase 3);
   - `profileable` is off;
   - experimental options are hidden (High Refresh Rates, and anything marked
     experimental or "lab").
3. Check the store APK: the manifest (target SDK, permissions, VR category,
   supported devices), no dev bridge, and a `strings` check for debug symbols.

### Phase 3: entitlement check
1. Add the [Godot Meta Toolkit](https://godot-sdk-integrations.github.io/godot-meta-toolkit/manual/platform_sdk/getting_started.html)
   (Platform SDK bindings) to store builds only. Check it loads beside our
   patched engine and `godotopenxrvendors`, and that it adds nothing to
   sideload builds.
2. At start-up, in `nightfall_store` builds only:
   - initialise the SDK with the App ID (`StoreBuild.META_APP_ID`; it's
     public, so it's a constant rather than a build secret);
   - run the entitlement check at once, without delaying discovery or the
     menus;
   - on failure, show a clear message in the headset ("This copy isn't
     licensed for this account") and quit.
3. Tests (they need a build in a release channel, so they come with phase 8):
   - a wrong App ID must fail;
   - an install from a release channel must pass;
   - an offline launch (Wi-Fi off) must still start, using the headset's
     cached entitlement. If it doesn't, decide what to do before submission.

### Phase 4: first run and polish for content review
- A first-run screen when no PC has been found: what Nightfall does, that it
  needs Meteor on a PC, and the download address (plus a QR code for the phone).
- Settings > About: version, licence (GPLv3), and a source link for this exact
  version.
- Walk every screen in the store build for leftover developer text, test
  labels and placeholders.

### Phase 5: VRC self-check
Go through the [VRC guidelines](https://developers.meta.com/horizon/resources/publish-quest-req/)
and keep evidence (screenshots and numbers) in this plan. The ones most likely
to need work:
- **Performance:** holds the refresh rate in menus and while streaming, with no
  long hitches on start or on resolution changes.
- **Focus and pause:** pauses behind the Universal Menu, Guardian and system
  dialogs, and resumes without a reconnect loop.
- **Input:** controllers and hands both work everywhere, or the listing says
  which is needed.
- **Packaging:** manifest, SDK and engine versions (VRC.Quest.Packaging.1, .4,
  .6).
- **Security:** the entitlement check.

`tools/quest.py` and `tools/verify.py quest`/`stream` produce most of the
evidence.

### Phase 6: privacy, rating, licence (user, with drafts from the agent)
- A privacy policy page:
  - what leaves the headset: video requests, head and controller poses, and the
    microphone, only to the user's own PC;
  - what is stored: pairing keys and settings, on the headset only;
  - no analytics.
- Data Use Checkup: only needed for Platform SDK user data; the in-app
  entitlement check doesn't need one.
- Age rating (IARC questionnaire): the browser reaches any website.
- Read Meta's developer distribution agreement for terms that add restrictions
  on users beyond GPLv3. Nightfall and moonlight-common-c are GPLv3; Moonlight
  ships on Google Play under it.

### Phase 7: store listing (user)
- A website (required for the product page); the "needs a PC running Meteor"
  line near the top of the description.
- Cover art in each format the dashboard asks for, icon, screenshots
  (`tools/quest.py shot`), a trailer.
- Supported devices, play area (stationary), comfort rating, support contact.

### Phase 8: release channels, then submission
1. Upload 0.9.1's store build to the **Alpha** channel and invite a few testers
   (invite links last 90 days, or until a new build is uploaded).
2. Confirm on a headset that has the sideloaded 0.9.1:
   - the store update installs in place;
   - pairings and settings survive.
3. Fix what testers find; re-upload with `--build 1`, `2`…
4. Move the build to **Production** and submit, at least two weeks before
   launch.
5. Once approved, release, and announce it in the GitHub release notes. The
   GitHub APK stays.

## Ongoing
- Each release: GitHub APK and store build from the same commit; store build to
  Alpha, then Production, then review. Review takes days, so the GitHub APK may
  come first.
- Keep the release keystore backed up in two places. Losing it ends updates
  for store and sideload users alike.
- Watch Meta's developer blog for target SDK rises; they're announced months
  ahead.

## Open questions
- The toolkit's guide says Platform SDK features need an approved Data Use
  Checkup. Confirm in the dashboard whether the entitlement check alone needs
  one; if it does, fill it in with no user data selected.
- Licence: the store build links Meta's closed `libovrplatformloader.so`.
  Check that this fits GPLv3 as a system-style library on the platform, or add
  a linking exception for it to Nightfall's licence (the code is all ours to
  relicense except the GPL dependencies, so look at those too).
- Does content review accept an app that does nothing without a PC? Virtual
  Desktop and Steam Link are precedents; the first-run screen matters.
- Which features stay in the store build and which go behind a "Labs" toggle
  (Linux browser lab, experimental depth models, high refresh rates)?

## Progress

- 2026-11-23: plan written; phase 1 started.
  - Target SDK raised to 34 in both Android presets; the APK reports
    `targetSdkVersion=34`. Our Java needs no API 33/34 changes: no runtime
    receivers, `PendingIntent`s or dynamic code loading; `requestNetwork` (USB
    Link) already has `CHANGE_NETWORK_STATE`.
  - On Quest 3: the app starts in XR (`verify.py quest` passes), and a stream
    runs at 2560x1440 HEVC, 72 fps, app 72 fps. Host depth at 20.7 Hz matches
    the target-32 build (19.5 Hz the same day), so it isn't a regression.
  - Fixed: the microphone's permission check ran every frame while streaming.
    Each call made Android log three stack traces (about 2,000 lines a
    minute). The grant is now cached (`MeteorMicrophone.has_permission`);
    after the fix the log has none.
  - Still to test by hand: microphone prompt and audio, PCVR handover, USB
    Link, browser, on-device AI depth, pause/resume. The headset lost tracking
    before the second stream run.
  - Seen once, on the earlier CRT build: a render-thread SIGSEGV (fault
    address 0x40) about 3 minutes after Meteor restarted while the host was
    stuck on a PipeWire freeze. No backtrace was kept. Watch for it during
    phase 5.

- 2026-11-24: phase 0 done by the user (team "Nightfall VR" verified, payout
  and tax set, app created). Phases 2 and 3 written:
  - Version codes are MAJOR·1000000 + MINOR·10000 + PATCH·100 + BUILD
    (`tools/build_support/app_version.sh`); 0.9.1 is 90100, above every old
    code (901 at most). `--build N` sets BUILD for release builds; dev and
    debug builds use 0, so they still replace the release they follow and
    the next release replaces them.
  - `build.sh --release --store [--build N]` writes
    `Nightfall-Android-arm64-v8a-store.apk`: export feature `nightfall_store`,
    `<profileable>` off, and the Godot Meta Toolkit 1.0.3 (pinned by
    checksum, `tools/build_support/meta_toolkit.sh`). The toolkit lives in
    `.build-cache/` and is copied into `addons/` only for the export, so
    other builds never load it; the build fails if a non-store APK carries
    `libovrplatformloader.so` or a store APK lacks it.
  - `src/store_build.gd`: in store builds on Android, initialise the SDK and
    check the entitlement beside start-up; on failure, say so on the main
    screen and quit after 10 s. The message is English only for now.
  - The dev bridge is off in store builds even with `--nf-dev-bridge`.
  - On Quest 3, the sideloaded store build fails the check as it should: the
    SDK initialises in under a millisecond, then the entitlement call
    returns code 8, "user does not have app in library", within a second of
    start, and the app quits. The message goes to the menu's status line
    (the toast alone only shows on the stream screen); not yet seen in the
    headset.
  - Phase 1 retest on the dev build: stream 2560x1440 HEVC 72 fps, app 72
    fps, host depth 25.6 Hz (the host's limit, as before). The microphone
    permission check now runs once per stream (one burst of log lines)
    instead of every frame.

- 2026-11-25: branch brought up to date with `main` after the 0.9.1 merges
  (#101, #102). On Quest 3 with that build: VRChat over PCVR with voice
  (the microphone now keeps flowing through the XR handover, from `main`'s
  PCVR fix); the user also checked the microphone prompt, browser,
  on-device AI depth and pause/resume. USB Link not retested (it carries
  the 2D stream; this stream used Wi-Fi).

- 2026-11-25: 0.9.1 store build in the **Alpha** channel.
  - The first upload (90100) had the same versionCode as the dev build already
    on the headset, so the store just opened that copy. Uploads must always
    have a higher versionCode than anything installed.
  - The release preset no longer sets `show_as_launcher_app`: it registered
    Nightfall as a Home launcher (`android.intent.category.HOME`), a store
    review risk, and the Library entry doesn't need it. Re-uploaded as
    `--build 1` (90101).
  - On Quest 3, installed from the store (installer `com.oculus.ocms`):
    `[STORE] Entitlement check passed` a second after start; the dev bridge
    isn't listening; 90100 → 90101 updated in place with pairings kept;
    stream and VRChat microphone work.

## Sources
- [Meta Horizon apps must target Android 14 from 1 March](https://developers.meta.com/horizon/blog/meta-quest-apps-android-14-march-1/)
- [Application manifests for release builds](https://developers.meta.com/horizon/resources/publish-mobile-manifest/)
- [Virtual Reality Check (VRC) guidelines](https://developers.meta.com/horizon/resources/publish-quest-req/)
- [Release channels](https://developers.meta.com/horizon/resources/publish-release-channels)
- [App review](https://developers.meta.com/horizon/resources/publish-app-review/)
- [Entitlement check](https://developers.meta.com/horizon/documentation/native/ps-entitlement-check/)
- [Godot Meta Toolkit: Platform SDK](https://godot-sdk-integrations.github.io/godot-meta-toolkit/manual/platform_sdk/getting_started.html)
- [Getting your app ready for the Horizon Store (App Lab merge)](https://developers.meta.com/horizon/blog/get-apps-ready-app-lab-meta-horizon-store-meta-quest-developers/)
