Nightfall Meteor for Windows x64
================================

Keep this folder together and run nightfall-meteor.exe. Its tray icon opens
the depth model, rate, microphone, and startup controls. Meteor starts with
EdgePad 512x288. Video Depth Anything is offered as a verified download in
the tray's Depth model menu; it is not included in this package.

Requirements: Windows 10/11 x64, a Vulkan-capable NVIDIA or AMD GPU and current driver.
The installer includes the built-in desktop host, Windows XR runtimes, and
app-local Microsoft C++ runtime DLLs. An external Sunshine-compatible host is
optional. VB-CABLE is needed
only for the headset microphone; choose CABLE Output in the recording app.
On AMD, Meteor uses D3D11VA for video decoding and ncnn Vulkan for EdgePad.
The included FFmpeg DLLs are required for this path. NVIDIA keeps its NVDEC
path. Video Depth Anything's TensorRT download requires NVIDIA; the Vulkan
VDA option requires compatible model graphs.

Windows may ask to let Meteor communicate on private networks the first
time it runs. Allow private networks so the Quest can reach the proxy and
depth ports. The installer creates Start menu and uninstall entries for the
current Windows user. It does not change firewall rules; automated firewall
setup is still planned.

Setup offers the built-in host and PCVR. It discovers installed VR games from
Steam's VR application manifest across your Steam libraries. SteamVR handles
general VR games; Moss also has a Monado/xrizer profile. This Windows encoder
currently requires NVIDIA/NVENC. Install SteamVR through Steam. PCVR setup registers Meteor's bundled
SteamVR driver automatically. SteamVR and games are not redistributed.
After installing a game, quit Meteor and use Set up Nightfall Meteor in Start.
Run Steam first so it can refresh its VR application list. PCVR setup can
enable the SteamVR connection even before any game profiles are discovered.
To pair, select this PC in Nightfall, then choose Game streaming host > Pair
headset... in Meteor's tray (or Pair a Nightfall headset from Start). Enter
the four-digit headset PIN; no host web login is needed. Finish pairing in
Nightfall, then compare and approve the PCVR
headset code in Meteor's tray. VR Apps launches need no Steam launch options.
For direct Moss launches from Steam, use the line in the PCVR profiles folder's
steam-launch-options.txt as Moss's Steam launch options. VRChat uses the
registered SteamVR driver and needs no Meteor launch options, as do other
SteamVR games. Existing Steam
settings are not automatically overwritten by the installer.
Setup diagnostics: AppData\Local\Nightfall Meteor\setup-summary.json.
The built-in multi-monitor backend currently supports SDR displays on one GPU.

Settings and state are stored in AppData\Roaming\Nightfall Meteor. Downloads,
models, the pairing key, and meteor.log are in AppData\Local\Nightfall
Meteor. Keep meteor.key if you move or reinstall Meteor: the Quest trusts
that key. Uninstall leaves these data folders in place. The tray has an Open
log item for troubleshooting.

The source and licence are at https://github.com/tB0nE/nightfall . See
share\doc\nightfall-meteor\LICENSE and THIRD_PARTY_NOTICES.txt in this package.
