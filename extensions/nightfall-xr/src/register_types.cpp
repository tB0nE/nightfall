#include "register_types.h"

#include "fast_xr_renderer.h"
#include "pcvr_projection_test.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
#include <android/log.h>
// Register before Godot creates its OpenXR instance, not from scene _ready.
static NightfallXrProjectionTest *pcvr_clock_request = nullptr;
static constexpr ModuleInitializationLevel XR_REGISTRATION_LEVEL = MODULE_INITIALIZATION_LEVEL_CORE;
#else
static constexpr ModuleInitializationLevel XR_REGISTRATION_LEVEL = MODULE_INITIALIZATION_LEVEL_SCENE;
#endif

void initialize_nightfall_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != XR_REGISTRATION_LEVEL) {
		return;
	}
	ClassDB::register_class<NightfallXrRenderer>();
	ClassDB::register_class<NightfallXrProjectionTest>();
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
	pcvr_clock_request = memnew(NightfallXrProjectionTest);
	pcvr_clock_request->register_extension_wrapper();
	__android_log_print(ANDROID_LOG_INFO, "NightfallPCVR", "Clock extension wrapper registered at CORE, before OpenXR instance creation");
#endif
}

void uninitialize_nightfall_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != XR_REGISTRATION_LEVEL) {
		return;
	}
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
	// Godot owns the registered extension wrapper through OpenXR shutdown.
	pcvr_clock_request = nullptr;
#endif
}

extern "C" {
GDExtensionBool GDE_EXPORT nightfall_xr_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_nightfall_xr_module);
	init_obj.register_terminator(uninitialize_nightfall_xr_module);
	init_obj.set_minimum_library_initialization_level(XR_REGISTRATION_LEVEL);
	return init_obj.init();
}
}
