#include "pcvr_view_validation.h"
#include <cassert>
#include <limits>
struct View {
	struct { struct { float x, y, z, w; } orientation; float position[3]; } pose;
	struct { float left, right, up, down; } fov;
};
int main() {
	View valid{{{0, 0, 0, 1}, {0, 1.7f, 0}}, {-0.8f, 0.8f, 0.8f, -0.8f}};
	assert(pcvr_valid_view(valid));
	View bad = valid; bad.pose.orientation.w = 0; assert(!pcvr_valid_view(bad));
	bad = valid; bad.pose.position[0] = std::numeric_limits<float>::quiet_NaN(); assert(!pcvr_valid_view(bad));
	bad = valid; bad.fov.left = bad.fov.right; assert(!pcvr_valid_view(bad));
	bad = valid; bad.fov.up = std::numeric_limits<float>::infinity(); assert(!pcvr_valid_view(bad));
	bad = valid; bad.fov.down = -1.58f; assert(!pcvr_valid_view(bad));
}
