#pragma once
#include <cmath>

// Kept independent of ALVR/OpenXR headers so malformed metadata is unit-testable.
template <typename View> bool pcvr_valid_view(const View &view) {
	const auto &q = view.pose.orientation;
	const float values[] = {q.x, q.y, q.z, q.w, view.pose.position[0], view.pose.position[1], view.pose.position[2],
		view.fov.left, view.fov.right, view.fov.up, view.fov.down};
	for (float value : values) if (!std::isfinite(value)) return false;
	float norm = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w;
	if (norm < 0.99f || norm > 1.01f) return false;
	const auto &f = view.fov;
	return (f.left > -1.57f) && (f.right < 1.57f) && (f.down > -1.57f) && (f.up < 1.57f) &&
		f.right - f.left > 0.01f && f.up - f.down > 0.01f;
}
