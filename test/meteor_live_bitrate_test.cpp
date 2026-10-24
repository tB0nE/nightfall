#include "meteor_live_bitrate.h"
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <unistd.h>
int main() {
    char root[]="/tmp/meteor-bitrate-test-XXXXXX";
    assert(mkdtemp(root));
    const std::string prefix=std::string(root)+"/bitrate-";
    MeteorLiveBitrate control;
    uint32_t current=80000000;
    int calls=0;
    auto apply=[&](uint32_t target) { ++calls; return target==160000000 ? 12 : 0; };
    auto request=[&](const char *text) { std::ofstream(prefix+"request")<<text; control.poll(root,32000000,current,apply); };
    request("1 40\n"); assert(current==40000000 && calls==1);
    request("1 80\n"); assert(current==40000000 && calls==1);
    request("2 160\n"); assert(current==40000000 && calls==2);
    unsigned sequence,mbps,bps,status;
    std::ifstream ack(prefix+"ack"); ack>>sequence>>mbps>>bps>>status;
    assert(sequence==2 && mbps==160 && bps==40000000 && status==12);
    request("3 0\n"); assert(current==32000000 && calls==3);
    request("4 161\n"); request("4 40 junk\n");
    assert(control.sequence==3 && calls==3);
    request("4 32\n"); assert(control.sequence==4 && calls==3);
    unlink((prefix+"request").c_str()); unlink((prefix+"ack").c_str());
    assert(rmdir(root)==0);
}
