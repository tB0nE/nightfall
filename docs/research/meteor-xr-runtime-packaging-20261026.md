# XR runtime Linux packaging findings — 26 October 2026

Branch: `feat/meteor-xr-streaming`.

The development runtime was built on Ubuntu 24.04. Its service and OpenXR
library require GLIBC_2.38; putting them in the Ubuntu 22.04-based Meteor
AppImage would silently raise the supported OS baseline. Both also link cJSON,
which was absent from the original staged bundle.

The baseline rebuild uses Ubuntu 22.04 and the same pinned sources and capture,
controller, session-event and layer-policy hooks as development. It builds the
service/OpenXR library, bridge shader headers, validated helper tests and two
bridge libraries. It excludes Godot and the optional diagnostic application.

| Check | Development bundle | Baseline bundle |
|---|---|---|
| Maximum glibc requirement | 2.38 | 2.34 |
| Private cJSON | Missing | Bundled, baseline-built |
| Static audit at glibc 2.35 | Rejected | Passed |
| Minimal Ubuntu runtime loading | Not attempted | Passed |
| GPU/game/headset validation of packaged layout | Outstanding | Outstanding |

Host dependencies remain Python 3, Vulkan loader, libudev and current compatible
C/C++ runtimes. The baseline bridge reports GLIBCXX_3.4.30. The current XR encoder
also needs the matching NVIDIA Vulkan ICD, libcuda and libnvidia-encode from the
host graphics driver. These driver libraries are loaded dynamically and are
listed separately by the audit; their presence/performance is not established by
an ELF-only check.

The runtime-only check used Ubuntu 22.04 with Python, libvulkan, libudev and the
current distribution libstdc++. It had no Git, compiler, Godot, GPU access or
installed cJSON. The OpenXR library and both bridges loaded, the service's
libraries resolved, and cJSON resolved specifically from the package. All Python
modules compiled and the manifest check passed.

Monado license texts, cJSON notice, ffmpeg/NVIDIA codec-header notices and
baseline Eigen/cJSON copyright metadata are included in the final staging
output. The notice inventory still requires a compiled-component review before
publishing a complete release; this report is not a legal certification.

For implementation details, commands and remaining work, see
[the Linux installation plan](../plans/active/meteor-linux-installation.md).
