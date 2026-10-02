#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "nightfall_stream.h"
#include "config/config_manager.h"
#include "config/stream_config.h"
#include "config/computer_manager.h"
#include "network/http_requester.h"
#include "network/mdns_browser.h"
#include "network/usb_link_bridge.h"
#include "video/ffmpeg_decoder.h"
#include "video/texture_uploader.h"
#include "video/depth_bridge.h"
#include "video/stream_connection.h"
#include "audio/opus_decoder.h"
#include "audio/audio_renderer.h"
#include "input/input_bridge.h"

#ifdef __ANDROID__
#include "video/pyrowave_decoder.h"
#endif

using namespace godot;

void initialize_nightfall_types(ModuleInitializationLevel p_level)
{
#ifdef __ANDROID__
    // Create PyroWave's Vulkan device at the earliest GDExtension level,
    // before Godot's renderer creates its own GLES/EGL context - see
    // pyrowave_warmup_device()'s comment for why this ordering matters.
    if (p_level == MODULE_INITIALIZATION_LEVEL_CORE) {
        pyrowave_warmup_device();
        return;
    }
#endif

    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    GDREGISTER_CLASS(NightfallStream);
    GDREGISTER_CLASS(NightfallConfigManager);
    GDREGISTER_CLASS(NightfallStreamConfig);
    GDREGISTER_CLASS(NightfallStreamOptions);
    GDREGISTER_CLASS(NightfallComputerManager);
    GDREGISTER_CLASS(HttpRequester);
    GDREGISTER_CLASS(MdnsBrowser);
    GDREGISTER_CLASS(UsbLinkBridge);
    GDREGISTER_CLASS(FfmpegDecoder);
    GDREGISTER_CLASS(TextureUploader);
    GDREGISTER_CLASS(DepthBridge);
    GDREGISTER_CLASS(StreamConnection);
    GDREGISTER_CLASS(OpusDecoderWrapper);
    GDREGISTER_CLASS(AudioRenderer);
    GDREGISTER_CLASS(InputBridge);
}

void uninitialize_nightfall_types(ModuleInitializationLevel p_level)
{
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C"
{
    GDExtensionBool GDE_EXPORT nightfall_stream_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
    {
        GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
        init_obj.register_initializer(initialize_nightfall_types);
        init_obj.register_terminator(uninitialize_nightfall_types);
#ifdef __ANDROID__
        init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);
#else
        init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
#endif

        return init_obj.init();
    }
}
