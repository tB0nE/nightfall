#include "pcvr_frame_accounting.h"
#include <cassert>
int main() {
    PCVRFrameAccounting counts;
    counts.received=6; counts.queued=6;
    counts.select(0); counts.select(3); counts.select(4);
    assert(counts.selected==3 && counts.superseded==2);
    assert(counts.queued-counts.selected-counts.superseded==1); // Tail, not a latest-image skip.
    counts.reset(); counts.select(2);
    assert(counts.selected==1 && counts.superseded==2); // Initial skip is included.
    counts.reset();
    assert(counts.next_sequence==0 && counts.queued==0 && counts.selected==0);
}
