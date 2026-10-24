#include "meteor_live_foveation.h"
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <unistd.h>
int main() {
    char root[]="/tmp/meteor-foveation-test-XXXXXX"; assert(mkdtemp(root));
    const std::string prefix=std::string(root)+"/foveation-";
    bool enabled=false;
    auto request=[&](const char *text) {std::ofstream(prefix+"request")<<text; meteor_poll_foveation(root,enabled);};
    request("1 1\n"); assert(enabled);
    request("1 0\n"); assert(enabled); // stale commands cannot undo a newer choice
    request("2 0\n"); assert(!enabled);
    request("3 2\n"); request("3 1 junk\n"); assert(!enabled);
    request("3 1\n"); assert(enabled);
    unsigned sequence,requested,applied,status;
    std::ifstream ack(prefix+"ack"); ack>>sequence>>requested>>applied>>status;
    assert(sequence==3 && requested==1 && applied==1 && status==0);
    unlink((prefix+"request").c_str()); unlink((prefix+"ack").c_str()); assert(rmdir(root)==0);
}
