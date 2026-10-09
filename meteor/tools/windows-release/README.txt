Nightfall Meteor for Windows x64
================================

Keep this folder together and run nightfall-meteor.exe. Its tray icon opens
the depth model, rate, microphone, and startup controls. Meteor starts with
EdgePad 512x288. Video Depth Anything is offered as a verified download in
the tray's Depth model menu; it is not included in this package.

Requirements: Windows 10/11 x64, an NVIDIA GPU and current driver, a
Sunshine-compatible streaming host, and the Microsoft Visual C++ x64
Redistributable (for ncnn.dll's C++ and OpenMP runtime). VB-CABLE is needed
only for the headset microphone; choose CABLE Output in the recording app.

Windows may ask to let Meteor communicate on private networks the first
time it runs. Allow private networks so the Quest can reach the proxy and
depth ports. The installer creates Start menu and uninstall entries for the
current Windows user. It does not change firewall rules; automated firewall
setup is still planned.

Settings and state are stored in AppData\Roaming\Nightfall Meteor. Downloads,
models, the pairing key, and meteor.log are in AppData\Local\Nightfall
Meteor. Keep meteor.key if you move or reinstall Meteor: the Quest trusts
that key. Uninstall leaves these data folders in place. The tray has an Open
log item for troubleshooting.

The source and licence are at https://github.com/tB0nE/nightfall . See
share\doc\nightfall-meteor\LICENSE and THIRD_PARTY_NOTICES.txt in this package.
