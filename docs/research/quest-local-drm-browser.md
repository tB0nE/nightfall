# Local browser / VM feasibility for protected video on Quest

Investigation and working experiment: 2026-10-31.

Current result: the user confirmed Netflix video, headset audio and AI 3D work
inside Nightfall through a separate ARM64 Linux/PRoot companion. Performance is
poor and fan activity is high; this is a feasibility prototype, not a shipping
browser. Its Linux environment is not a VM. The x86 desktop VM also played Netflix;
the emulated ARM64 VM was unusably slow and was removed at the user's request.

The native Android WebView test did not establish Netflix playback: a desktop UA
bypassed the app prompt, but playback returned a session-expired M7111-family
error. Official ARM64 Linux Chrome provided the working path. The sections below
retain initial platform evidence and subsequent experiment results.

Resume from [the session handoff](../handoffs/QUEST_LINUX_BROWSER_HANDOFF_2026-10-31.md).

## Question

Could Nightfall run Meta Quest Browser in a local Android VM, or Chrome in a
local Linux VM, and receive its picture in the same way that a PC browser can
sometimes be captured by a GameStream host?

Three capabilities must be established separately:

1. The local browser can run in the selected environment.
2. A service authorizes playback through that browser's supported DRM stack.
3. The resulting video is available through a permitted display/capture path
   that Nightfall can consume. Authorized playback does not establish access to
   readable frames for AI 3D.

Additional compute does not establish any of these capabilities. A loopback
encode/decode stage cannot make a protected surface capturable.

## Evidence from this Quest 3

Read-only ADB checks found:

- Android 14 / API 34, ARM64 with ARM32 ABI support.
- No `/dev/kvm`, `/dev/gunyah`, or `/dev/gh` entries (not merely a failed open).
- No advertised virtualization feature, AVF APEX package, or identifiable AVF
  VirtualizationService. Services named virtual camera/device/input are not
  hypervisor services.
- `/proc/misc` was permission denied; it was not inspected using root.
- System WebView is `com.android.webview`, version
  `149.1.0.10.52.1018773402`.
- Meta Browser is an updated system package, version
  `154.1.0.32.54.1101200317`. It declares Meta-specific shared libraries including
  `meta_supplement_staging` and `horizonos.supplement.meta.ndk.libraryapk`, plus
  Meta native libraries. An arbitrary AOSP guest cannot be assumed to supply
  these dependencies.
- A query for the conventional `media.drm` service did not find it. This does
  **not** establish that Quest or Meta Browser lacks Widevine: the browser and
  vendor may use another integration. No Android MediaDrm API or EME playback
  probe was completed. Nightfall's existing diagnostic bridge timed out; the app
  was not relaunched or replaced to obtain one.

The machine-readable initial checks are saved locally in
`.build-cache/browser-drm-research/quest-capabilities.json`. They contain system
capabilities, not DRM keys, device-unique DRM identifiers, account data, or media.

These checks establish no exposed accelerated VM route on this firmware. They
are not proof that the chipset lacks virtualization, or that every Quest OS
version has the same configuration.

## Option A: Meta Browser in an Android VM

**Assessment: low-priority / no supported route established.**

- Normal AVF VM APIs are system APIs with restricted permissions. An ordinary
  sideloaded Nightfall app cannot assume access even on an AVF-enabled device.
- This headset does not expose the expected VM interfaces checked above.
- Copying Meta Browser's APK would not recreate its Horizon OS shared libraries,
  services, platform integration, or the browser's approved playback environment.
- DRM capability, authorization and device provisioning do not automatically
  transfer to a guest simply because the physical headset plays the service.
- A software-emulated Android guest remains conceptually possible but would need
  its own graphics/decoding/DRM integration. No performance claim is justified.
- App-virtualization containers are not a substitute for a full guest with the
  same platform services; they do not establish protected-output capture either.

Netflix officially supports Meta Quest Browser on Quest 2/Pro/3/3S. That is a
statement about the supported browser on Horizon OS, not about running its APK
in another OS or accessing its video from Nightfall.

## Option B: Chrome in a Linux environment

**Assessment: functional ARM64 Linux/PRoot proof completed; production viability unresolved.**

Google announced ARM64 Linux Chrome in March 2026. A read-only HEAD request to
its official package URL returned HTTP 200 on 2026-10-31:

`https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb`

At the initial research stage no package had been installed. The later headset
experiment installed official ARM64 Chrome successfully. Native availability means
we should not design around emulating an x86 desktop browser. Package availability
alone does not verify Widevine operation inside a Quest-hosted Linux environment.

A true hardware-accelerated Linux VM faces the same missing host interfaces as
option A. Two distinct alternatives remain:

- **Full software emulation:** could boot a guest without KVM, but guest graphics,
  hardware video decoding, memory and sustained performance are unmeasured.
- **Linux userspace under PRoot/Termux:** does not need a guest kernel or KVM.
  ARM64 code runs on the native CPU, with syscall/path translation overhead.
  This is not a security-isolated VM. Kernel features, namespaces and graphics
  access remain constrained by Android; Chrome's sandbox must also be evaluated.

Before integrating this with Nightfall, demonstrate browser startup, ordinary
video, normal authorized DRM playback, and permitted frame delivery. A browser
window rendering successfully is insufficient. Do not transfer/extract device
keys or patch capture protections. A local shared-surface path could eventually
avoid an extra encode/decode if graphics interoperability supports it, but that
has not been established.

## Existing WebView path

`android/src/main/java/com/godot/game/BrowserPrototype.java` currently:

- Renders a WebView in a Presentation on a non-secure VirtualDisplay backed by
  Nightfall's Surface/SurfaceTexture.
- In normal releases, denies `onPermissionRequest` requests.
- In DEV builds with the protected-media-test manifest metadata, grants only
  requested `RESOURCE_PROTECTED_MEDIA_ID` on HTTPS origins. Camera, microphone
  and unknown resources remain denied. This is an explicit test policy, not
  confirmation of DRM support.

The permission denial is one known blocker; removing it would not create a CDM,
service authorization, secure decoder or protected output path.

Android documents that protected-media-ID permission lets an origin generate
license requests via EME. It is not permission to read decrypted video frames.
A secure VirtualDisplay requires privileged authorization; adding the secure
flag is not a general solution for this texture-backed browser.

## Recommended experiments, in order

1. **Small capability probe in an isolated development build:** report only
   WebView/provider version, EME key-system availability, supported robustness
   configurations and relevant MediaDrm/codec capabilities. Do not collect DRM
   unique identifiers, account cookies, content keys or license bodies.
2. **Ordinary authorized playback test:** start with clear video and public
   DRM demonstration assets in the official Shaka demo, then test the intended
   service using the user's normal account if required. Any protected-media
   permission grant must be user-approved and scoped to the requested origin
   and resource; camera/microphone permissions stay separate.
3. **Separate presentation from frame access:** record whether playback is
   rejected, audio-only, visible through a supported protected path, or readable
   through the existing allowed texture path. Do not promise AI 3D for protected
   playback. Respect output protection if the path excludes readable textures.
4. **If native support is insufficient, prototype ARM64 Linux userspace first:**
   isolate its files, verify the official browser and supported DRM behavior,
   then measure ordinary video playback and CPU/GPU/memory cost before adding
   any local streaming layer. Stop if it cannot provide a supported playback
   and output path.
5. **Keep Android-guest work deferred** unless Meta exposes a supported route
   to browser/runtime portability and accelerated guest execution.

Pass/fail gates should separate browser launch, authorized playback, permitted
frame access, audio, input, video cadence, memory and thermals. Subsequent playback and stability results are recorded below; active Netflix
performance remains unprofiled.

## Current three-stage test

1. **Desktop baseline (ready):** use `tools/experiments/browser-vm/run.sh`.
   Ubuntu 24.04 x86_64, Fluxbox and official Chrome run in a KVM guest with
   4 vCPUs, 4 GiB RAM and a sparse 12 GiB disk. Software graphics avoids host
   GPU changes. Open <http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale>,
   sign into your own account and test playback. Check whether video is visible
   through this remote desktop too. noVNC does not forward audio, so silence in
   the host browser is not an audio-playback failure. The user confirmed Netflix playback and visibility through the remote desktop.
   **ARM64 intermediate check (ended):** a separate Ubuntu ARM64 guest used QEMU's
   `virt` machine and software CPU emulation, with official ARM64 Chrome selected
   in cloud-init. Its web desktop is on port 6081, SSH on 2224, and storage/profile
   separate from the working x86 baseline. Launch with `BROWSER_VM_ARCH=arm64`.
   It was too slow to obtain a playback result and was stopped and removed at the
   user's request. Its source scripts remain for reference; the x86 VM is retained.
2. **Quest Linux environment (prototype running):** ARM64 Ubuntu userspace and
   official Chrome now run under PRoot in a separate companion app. The desktop x86/KVM result does not prove
   ARM64 Chrome DRM compatibility or that Quest exposes accelerated VMs.
3. **Playback inside that environment (still unverified):** test ordinary video,
   authorized Netflix playback, and permitted frame delivery separately before
   attempting Nightfall integration. Measure resource cost only after these gates.

The native WebView DEV test is a parallel, cheaper check: Netflix permission
requests are no longer rejected solely by Nightfall's permission policy.
YouTube now uses its regular desktop URL and a desktop-style UA retaining the
installed WebView's Chrome version. Mobile YouTube redirects are canonicalized. The protected-media DEV test also
requests a Linux ARM64 desktop UA for Netflix to test its browser/app routing.
Other sites retain their default UA. This changes site identification, not
WebView DRM capabilities, and does not hide every platform-detection signal.

Changing a UA does not reproduce Meta Browser's platform capabilities. Its DRM
components cannot simply be supplied as files to make another browser equivalent;
provisioning, supported APIs and output requirements still apply. This experiment
uses ordinary browser APIs without copying DRM components or device secrets.

## Native Quest follow-up

See [the reproducible headset lab](../../tools/experiments/browser-quest-linux/README.md).
Official Termux PRoot, Ubuntu Base ARM64 and official ARM64 Chrome now execute
on the Quest without root. Linux shell/glibc/apt, Chrome version, sandbox-disabled
blank-page rendering and the visible Xvfb/noVNC desktop were checked.

Android denied Chrome's filesystem UNIX socket in shell-owned temporary storage;
SELinux logs confirmed the denial. Moving the prepared userspace into a separate
companion app's own private data resolved that specific failure. The app is
`app.nightfall.browserlab`; Nightfall itself was not replaced for this step.

Two substantial limits remain: Chrome currently needs `--no-sandbox`, and the
companion targets API 28 to test execution of downloaded Linux binaries. These
results do not establish a safe browser architecture or compatibility with the
shipping Nightfall target SDK. PRoot does not provide VM isolation. A silent
PulseAudio sink permits audio-path initialization for a picture-only test, but
headset speaker output is not wired. No VM browser profiles or logins were copied.
The local EME probe successfully obtains `com.widevine.alpha` access and creates
MediaKeys; the rendered result was checked through the remote desktop. The user subsequently confirmed Netflix video playback through the Quest-hosted
browser. The browser/viewer then failed. Android logs subsequently established the
initiating event: ActivityManager killed the PRoot tracer while `Trimming phantom
processes`; the device child-process limit is 32. ENOSYS and audio errors followed
that kill. The lab now reduces child count using a threaded viewer proxy and
less browser background activity, without changing device-wide process policies.
A seven-minute monitored clear-video run kept the original tracer alive with a
maximum of 22 children; the rendered counters at 476 seconds showed 14,059 frames,
zero drops and no error. An extended Netflix replay remains to be checked. Sustained cadence, audio output, sandboxing
and production suitability remain outstanding.

## Sources

- [Android AVF APIs and permission restrictions](https://android.googlesource.com/platform/packages/modules/Virtualization/+/HEAD/libs/framework-virtualization/README.md)
- [AVF architecture](https://source.android.com/docs/core/virtualization/architecture)
- [VirtualizationService](https://source.android.com/docs/core/virtualization/virtualization-service)
- [Google: Chrome for ARM64 Linux](https://blog.google/chromium/bringing-chrome-to-arm64-linux-devices/)
- [Meta Browser video support and runtime capability detection](https://developers.meta.com/vr/documentation/web/browser-video/)
- [Netflix supported browsers and Quest devices](https://help.netflix.com/en/node/30081)
- [Android protected-media permission](https://developer.android.com/reference/android/webkit/PermissionRequest#RESOURCE_PROTECTED_MEDIA_ID)
- [Android secure virtual displays](https://developer.android.com/reference/android/hardware/display/DisplayManager#VIRTUAL_DISPLAY_FLAG_SECURE)
- [PRoot-Distro's design and limitations](https://github.com/termux/proot-distro)
- [Official Shaka Player demo](https://shaka-project.github.io/shaka-player/demo/)

## Audio and Nightfall proof

The lab now forwards its own PulseAudio monitor through `parec` into an Android
AudioTrack (48 kHz stereo PCM16), owned alongside the Linux runtime by a foreground
media service. Non-zero PCM, advancing playback-head frames and retained focus
were checked; the user heard the generated test noise. No microphone permission,
recording, system-volume adjustment or device-wide process-policy change was used.

The existing Nightfall browser was navigated to the local noVNC viewer without a
new Nightfall APK. The user confirmed the Linux Chrome page is visible inside
Nightfall. Existing headset inference reports depth updates. The user subsequently confirmed Netflix sound and AI 3D work in that combined
path, but reported poor frame rate and loud fan activity. Lip sync and exact
decoder/viewer/presentation cadence remain to be measured. See the
[integration plan](../plans/active/quest-linux-browser-integration.md) for replacing
VNC and addressing sandbox, private IPC, executable packaging and distribution.
