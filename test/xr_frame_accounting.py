"""Map encoded output back to submitted app frames; never compare by ordinal."""


def match_submitted_frames(submitted, encoded, *, allow_drops=False):
    if not submitted or not encoded:
        raise ValueError("Empty submitted/encoded sequence")
    for values in (submitted, encoded):
        if values[0] <= 0 or any(b <= a for a, b in zip(values, values[1:])):
            raise ValueError("Timestamps must be positive and strictly ordered")
    lookup = {stamp: i for i, stamp in enumerate(submitted)}
    if any(stamp not in lookup for stamp in encoded):
        raise ValueError("Encoded timestamp was never submitted")
    indices = [lookup[stamp] for stamp in encoded]
    if indices[-1] != len(submitted)-1:
        raise ValueError("Final submitted frame was not drained")
    if not allow_drops and len(indices) != len(submitted):
        raise ValueError("Missing app frame in stop-and-wait mode")
    return indices
