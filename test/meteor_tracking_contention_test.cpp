// Include the bridge so this regression exercises its actual synchronization.
#include "meteor_tracking_client_bridge.cpp"
#include <cassert>
#include <future>
int main() {
    Client client;
    client.mapped_ns=now_ns();
    client.sample.pose={1,2,3,0,0,0,1};
    std::promise<void> locked;
    auto ready=locked.get_future();
    std::thread writer([&] {
        std::lock_guard<std::mutex> lock(client.mutex);
        locked.set_value();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    });
    ready.wait();
    float pose[7]{}; uint64_t stamp=0;
    assert(meteor_tracking_pose_v1(&client,int64_t(client.mapped_ns),pose,&stamp));
    assert(pose[6]==1 && pose[0]==1 && stamp==client.mapped_ns);
    writer.join();
    // Verify both hands' stick-click and B/Y bits survive a concurrent update.
    active_client=&client;
    client.controller_ns=now_ns();
    for(auto &hand:client.controllers.hands) {hand.flags=15; hand.buttons=127;}
    std::promise<void> input_locked;
    auto input_ready=input_locked.get_future();
    std::thread input_writer([&] {
        std::lock_guard<std::mutex> lock(client.mutex);
        input_locked.set_value();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    });
    input_ready.wait();
    for(unsigned hand=0;hand<2;++hand) {
        float poses[14]{},values[4]{}; uint32_t buttons=0,flags=0;
        assert(meteor_tracking_controller_v2(hand,int64_t(client.controller_ns),poses,values,&buttons,&flags,&stamp));
        assert(buttons==127 && flags==15);
    }
    input_writer.join();
    active_client=nullptr;
    client.mapped_ns=now_ns()-300000000;
    assert(!meteor_tracking_pose_v1(&client,int64_t(now_ns()),pose,&stamp));
    client.failed.store(true);
    assert(!meteor_tracking_pose_v1(&client,int64_t(now_ns()),pose,&stamp));
}
