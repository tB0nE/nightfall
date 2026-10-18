#pragma once
#if defined(__ANDROID__) && defined(NIGHTFALL_PCVR_ALVR)
#include <alvr_client_core.h>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>

// One decoder owner. Worker owns core setup/events/teardown; render thread owns
// borrowed images until its GPU fence signals and acknowledges the final drain.
class PCVRAlvrClient {
public:
	~PCVRAlvrClient();
	bool start();
	void stop_after_gpu_drain();
	bool idle() const { return done.load(); }
	bool ready() const { return decoder_ready.load(); }
	std::string message() const;
	bool failed() const { return failure.load(); }
	bool frame(uint64_t &timestamp, void *&buffer, AlvrViewParams (&views)[2]);
	void tracking(uint64_t now_ns, const AlvrDeviceMotion &head, const AlvrViewParams (&eyes)[2]);
	void submitted(uint64_t timestamp, uint64_t queue_ns);
private:
	std::thread worker;
	std::atomic<bool> done{true}, stop{false}, decoder_ready{false}, failure{false};
	mutable std::mutex message_mutex;
	std::mutex api_mutex;
	std::string text;
	void set_message(const std::string &value, bool error = false);
	void run();
};
#endif
