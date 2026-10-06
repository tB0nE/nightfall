package com.godot.game;

import android.view.InputDevice;
import android.view.MotionEvent;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

// Godot's Android joypad driver only passes a device NAME to the engine, and
// numbers each pad's axes by position after sorting the Android axis IDs
// (GodotInputHandler.onInputDeviceAdded). Which Android axis ended up as Godot
// axis 4 is lost, so the "Default Android Gamepad" mapping (a4 = left trigger,
// a5 = right trigger) is wrong for any pad that reports triggers as GAS/BRAKE
// or on RX/RY. This reports the same sorted axis list, plus vendor/product IDs,
// so ControllerLayout can build a correct mapping per pad (GitHub #37, #34).
public class GamepadInfo {
	public static String describe() {
		JSONArray pads = new JSONArray();
		for (int id : InputDevice.getDeviceIds()) {
			InputDevice device = InputDevice.getDevice(id);
			if (device == null) continue;
			if (!device.supportsSource(InputDevice.SOURCE_GAMEPAD) &&
					!device.supportsSource(InputDevice.SOURCE_JOYSTICK)) {
				continue;
			}
			try {
				pads.put(describeDevice(device));
			} catch (Exception ignored) {
			}
		}
		return pads.toString();
	}

	private static JSONObject describeDevice(InputDevice device) throws Exception {
		JSONObject pad = new JSONObject();
		pad.put("name", device.getName());
		pad.put("vendor", device.getVendorId());
		pad.put("product", device.getProductId());

		// Mirror GodotInputHandler exactly: joystick/gamepad ranges only, hats
		// excluded, duplicates dropped, then sorted by Android axis ID. The
		// index in this list is the Godot raw axis index.
		Set<Integer> seen = new HashSet<>();
		List<InputDevice.MotionRange> ranges = new ArrayList<>();
		boolean hasHat = false;
		for (InputDevice.MotionRange range : device.getMotionRanges()) {
			if (!range.isFromSource(InputDevice.SOURCE_JOYSTICK) &&
					!range.isFromSource(InputDevice.SOURCE_GAMEPAD)) {
				continue;
			}
			int axis = range.getAxis();
			if (axis == MotionEvent.AXIS_HAT_X || axis == MotionEvent.AXIS_HAT_Y) {
				hasHat = true;
			} else if (seen.add(axis)) {
				ranges.add(range);
			}
		}
		Collections.sort(ranges, (a, b) -> Integer.compare(a.getAxis(), b.getAxis()));

		JSONArray axes = new JSONArray();
		for (InputDevice.MotionRange range : ranges) {
			JSONObject axis = new JSONObject();
			axis.put("id", range.getAxis());
			axis.put("min", (double) range.getMin());
			axis.put("max", (double) range.getMax());
			axes.put(axis);
		}
		pad.put("axes", axes);
		pad.put("hat", hasHat);
		return pad;
	}
}
