"""Validate app-level XRController3D observations, not just bridge packets."""
import math
import re


def inspect_input(log, *, synthetic):
    rows = [tuple(map(float, row)) for row in re.findall(
        r'UPSTREAM_INPUT left_active=(\d) right_active=(\d) left=([-\d.]+),([-\d.]+) '
        r'right=([-\d.]+),([-\d.]+) origin=([-\d.]+),([-\d.]+),([-\d.]+) yaw=([-\d.]+)', log)]
    if len(rows) < 2 or not all(math.isfinite(v) for row in rows for v in row):
        raise RuntimeError('Missing/invalid upstream app input observations')
    both_active = any(row[0] == row[1] == 1 for row in rows)
    if (synthetic and not both_active) or not any(row[1] == 1 for row in rows):
        raise RuntimeError('Required upstream controller trackers were not active')
    if any(abs(row[2]) > .001 or abs(row[3]) > .001 for row in rows):
        raise RuntimeError('Unbound upstream left movement action was nonzero')
    moving = any(abs(row[4]) > .1 or abs(row[5]) > .1 for row in rows)
    changed = any(max(row[i] for row in rows)-min(row[i] for row in rows) > .005
                  for i in (6, 8, 9))
    if synthetic and (not moving or not changed or not all(abs(row[5]-.25) < .001 for row in rows)):
        raise RuntimeError('Synthetic stick did not reach upstream action and locomotion')
    return dict(samples=len(rows), both_trackers_active=both_active, right_stick_nonzero=moving,
                locomotion_changed=changed, synthetic_assertions=synthetic)
