# Nightfall for Steam Frame — experimental preview

1. Extract the archive into a writable folder on your Steam Frame.
2. Add **launch-from-steam.sh** to Steam as a non-Steam game and launch it from
   Steam. Do not add the `nightfall` binary directly: Steam may show its flat
   desktop dashboard over the XR application.
3. Pair with Sunshine/Apollo/Vibepollo or Meteor's bundled host, then connect.

This is a Linux ARM64 client, not the Android APK or the PC's Meteor server.
SteamVR supplies OpenXR. The launcher uses the session's systemd user service;
keep the complete extracted folder together. Diagnostic output is `nightfall.log`
in that folder. No root installation is required.

H.264 and HEVC use V4L2 hardware decoding when the Frame driver exposes it.
Select H.264 or HEVC; AV1 hardware decoding is not supported by the Frame.
AI 3D in this package requires Meteor host-generated depth. Local AI inference,
Android WebView browsers and Quest-specific passthrough are not included.
Multipath remains experimental and opt-in: set
`NF_MULTIPATH_REMOTE=<PC address on the second network> %command%` in Steam's
launch options if you have two working network paths to the Meteor PC.

Frame controls: dedicated face buttons, D-pad, bumpers and stick clicks retain
their gamepad mappings; left View is Select/Back and right Menu is Start.
Squeeze both grips to toggle gamepad mode. The first guide waits for a fresh
button press before continuing.

This preview is cross-compiled on x86_64. Package/static checks do not establish
playback, controller feel or performance on actual Steam Frame hardware.
Please report logs and results on the Nightfall GitHub repository.
