#include "pcvr_presentation_gate.h"
#include <cassert>

int main() {
    PCVRPresentationGate gate;
    assert(!gate.is_ready() && !gate.present() && !gate.input_enabled());
    gate.begin(false);
    assert(!gate.activate());
    gate.frame_ready();
    assert(gate.is_ready() && !gate.present() && !gate.input_enabled());
    assert(gate.activate());
    assert(gate.present() && gate.input_enabled());
    gate.reset();
    assert(!gate.is_ready() && !gate.present() && !gate.activate());
    gate.begin(true); // Existing exclusive DEV path keeps immediate input behavior.
    assert(gate.input_enabled() && !gate.present());
    gate.frame_ready();
    assert(gate.present());
    gate.begin(false); // A new run must not inherit prior readiness or input.
    assert(!gate.is_ready() && !gate.present() && !gate.input_enabled());
}
