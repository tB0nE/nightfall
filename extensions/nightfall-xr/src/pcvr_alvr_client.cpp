#include "pcvr_alvr_client.h"
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
#include <android/log.h>
#include <jni.h>
#include <chrono>
#include <vector>

namespace {
JavaVM *java_vm = nullptr;
jobject app_context = nullptr; // Activity held until the worker/core fully stops.
std::mutex context_mutex;
}

extern "C" JNIEXPORT jboolean JNICALL Java_com_godot_game_GodotApp_initializePcvrContext(JNIEnv *env, jclass, jobject context) {
	std::lock_guard<std::mutex> lock(context_mutex);
	if (!context || env->GetJavaVM(&java_vm) != JNI_OK) return false;
	if (app_context) env->DeleteGlobalRef(app_context);
	app_context = env->NewGlobalRef(context);
	return app_context != nullptr;
}

PCVRAlvrClient::~PCVRAlvrClient() {
	stop.store(true);
	if (worker.joinable()) worker.join();
}
void PCVRAlvrClient::set_message(const std::string &value, bool error) {
	{ std::lock_guard<std::mutex> lock(message_mutex); text = value; }
	if (error) failure.store(true);
	__android_log_print(error ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, "NightfallPCVR", "ALVR: %s", value.c_str());
}
std::string PCVRAlvrClient::message() const {
	std::lock_guard<std::mutex> lock(message_mutex); return text;
}
bool PCVRAlvrClient::start() {
	if (!done.load()) return false;
	if (worker.joinable()) worker.join();
	{ std::lock_guard<std::mutex> lock(context_mutex); if (!java_vm || !app_context) { set_message("Android context not prepared", true); return false; } }
	stop.store(false); failure.store(false); decoder_ready.store(false); done.store(false);
	worker = std::thread(&PCVRAlvrClient::run, this);
	return true;
}
void PCVRAlvrClient::stop_after_gpu_drain() { stop.store(true); }
void PCVRAlvrClient::run() {
	JNIEnv *env = nullptr;
	bool attached = java_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_EDETACHED;
	if (attached && java_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
		set_message("Cannot attach ALVR worker to JVM", true); done.store(true); return;
	}
	alvr_initialize_android_context(java_vm, app_context);
	alvr_initialize_logging();
	const float refresh_rates[] = {72.0f};
	AlvrClientCapabilities caps{};
	caps.default_view_width = 1024; caps.default_view_height = 1024;
	caps.refresh_rates = refresh_rates; caps.refresh_rates_count = 1;
	caps.preferred_encoding_gamma = 1.0f;
	alvr_initialize(caps);
	alvr_resume();
	set_message("Discovering matching ALVR 20.14.1 host (manual trust required)");
	bool decoder_created = false;
	while (!stop.load()) {
		AlvrEvent event{};
		for (int n = 0; n < 16 && alvr_poll_event(&event); ++n) {
			if (event.tag == ALVR_EVENT_HUD_MESSAGE_UPDATED) {
				uint64_t size = alvr_hud_message(nullptr);
				if (size > 0 && size <= 16384) {
					std::vector<char> msg(size); alvr_hud_message(msg.data());
					msg.back() = 0; set_message(msg.data());
				}
			} else if (event.tag == ALVR_EVENT_STREAMING_STARTED) {
				const auto &stream = event.STREAMING_STARTED;
				if (stream.enable_hdr || stream.enable_foveated_encoding || stream.view_width == 0 || stream.view_height == 0 || stream.view_width > 4096 || stream.view_height > 4096) {
					set_message("Unsupported host configuration: use SDR, no foveated encoding, <=4096 per eye", true);
				} else set_message("Stream started: " + std::to_string(stream.view_width) + "x" + std::to_string(stream.view_height) + " per eye");
			} else if (event.tag == ALVR_EVENT_DECODER_CONFIG && !decoder_created && !failure.load()) {
				uint64_t size = alvr_get_decoder_config(nullptr);
				if (!size || size > 1024 * 1024) { set_message("Invalid decoder configuration", true); continue; }
				std::vector<uint8_t> config(size);
				alvr_get_decoder_config(reinterpret_cast<char *>(config.data()));
				AlvrDecoderConfig decoder{};
				decoder.codec = event.DECODER_CONFIG.codec;
				decoder.max_buffering_frames = 1.5f; decoder.buffering_history_weight = 0.9f;
				decoder.config_buffer = config.data(); decoder.config_buffer_size = config.size();
				std::lock_guard<std::mutex> lock(api_mutex);
				alvr_create_decoder(decoder); decoder_created = true; decoder_ready.store(true);
				set_message("Hardware decoder created; waiting for first frame");
			} else if (event.tag == ALVR_EVENT_STREAMING_STOPPED) {
				decoder_ready.store(false);
				set_message("Remote stream stopped; returning to welcome", true);
			}
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(5));
	}
	decoder_ready.store(false);
	// Only requested after the render thread releases/fences its last buffer.
	alvr_pause();
	{ std::lock_guard<std::mutex> lock(api_mutex); if (decoder_created) alvr_destroy_decoder(); alvr_destroy(); }
	{ std::lock_guard<std::mutex> lock(context_mutex); if (app_context) env->DeleteGlobalRef(app_context); app_context = nullptr; }
	if (attached) java_vm->DetachCurrentThread();
	set_message("Core and decoder stopped"); done.store(true);
}
bool PCVRAlvrClient::frame(uint64_t &timestamp, void *&buffer, AlvrViewParams (&views)[2]) {
	if (!decoder_ready.load() || failure.load()) return false;
	std::unique_lock<std::mutex> lock(api_mutex, std::try_to_lock);
	if (!lock.owns_lock() || !alvr_get_frame(&timestamp, &buffer) || !buffer) return false;
	alvr_report_compositor_start(timestamp, views);
	return true;
}
void PCVRAlvrClient::tracking(uint64_t now_ns, const AlvrDeviceMotion &head, const AlvrViewParams (&eyes)[2]) {
	if (!decoder_ready.load() || failure.load()) return;
	std::unique_lock<std::mutex> lock(api_mutex, std::try_to_lock);
	if (!lock.owns_lock()) return;
	alvr_send_view_params(eyes);
	alvr_send_tracking(now_ns, &head, 1, nullptr, nullptr);
}
void PCVRAlvrClient::submitted(uint64_t timestamp, uint64_t queue_ns) {
	if (decoder_ready.load()) alvr_report_submit(timestamp, queue_ns);
}
#endif
