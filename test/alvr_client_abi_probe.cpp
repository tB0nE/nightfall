// Compiled against the header generated from our pinned ALVR revision.
// Syntax/layout verification only; does not execute Android or OpenXR code.
#include "alvr_client_core.h"

#include <cstdint>
#include <type_traits>

static_assert(sizeof(void *) == 8, "The spike targets Android arm64 only");
static_assert(sizeof(AlvrQuat) == 16);
static_assert(sizeof(AlvrPose) == 28);
static_assert(sizeof(AlvrFov) == 16);
static_assert(sizeof(AlvrViewParams) == 44);
static_assert(std::is_standard_layout_v<AlvrClientCapabilities>);
static_assert(std::is_standard_layout_v<AlvrStreamConfig>);
static_assert(std::is_same_v<decltype(&alvr_initialize_android_context), void (*)(void *, void *)>);
static_assert(std::is_same_v<decltype(&alvr_get_frame), bool (*)(uint64_t *, void **)>);
static_assert(std::is_same_v<decltype(&alvr_report_compositor_start), void (*)(uint64_t, AlvrViewParams *)>);
static_assert(std::is_same_v<decltype(&alvr_render_stream_opengl), void (*)(void *, const AlvrStreamViewParams *)>);
