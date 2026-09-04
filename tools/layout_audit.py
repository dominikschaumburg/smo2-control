#!/usr/bin/env python3
"""Geometry audit: every device, every data field layout, every cell.

A green build says nothing about whether the elements fit. This walks all
`simulator.json` layouts the SDK ships, runs the same layout maths the field
does, and asserts three things about each cell:

  * every drawn element is inside the usable rectangle
  * every drawn element is on the glass (inside the circle, on round screens)
  * no two elements overlap

The element rectangles come from design/render_field.py, which is the port of
the Monkey C drawing code. So this checks the port, not the watch — keep the
two in step and it checks both.
"""

import importlib.util
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RENDER = os.path.join(HERE, "..", "design", "render_field.py")

_spec = importlib.util.spec_from_file_location("rf", RENDER)
rf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rf)

# A representative state per element set. The audit is about geometry, so what
# matters is the widest text each element can hold, not a plausible reading.
STATE = {
    "level": 88.8,
    "state": rf.STATE_CONTROL,      # "ZONE 2+", the longest state label
    "slope": -8.888,                # "-8.888%/s", the longest rate string
    "sci": 0.5,
    "prediction": 40.0,
    "now": 100.0,
    "laps": [],
    "load": (None, 2.5),
    "window": [(t, 50.0, rf.STATE_STEADY) for t in range(11, 101)],
}


def overlaps(a, b):
    return not (a[3] <= b[1] or b[3] <= a[1] or a[2] <= b[0] or b[2] <= a[0])


def corners_on_glass(box, sw, sh, shape):
    if shape != "round":
        return all(0 <= v for v in (box[0], box[1])) \
            and box[2] <= sw and box[3] <= sh
    cx, cy, r = sw / 2.0, sh / 2.0, sw / 2.0
    for x in (box[0], box[2]):
        for y in (box[1], box[3]):
            if math.hypot(x - cx, y - cy) > r:
                return False
    return True


def audit():
    problems = []
    checked = 0
    tiers = {"full": 0, "medium": 0, "compact": 0}

    for device in sorted(os.listdir(rf.SDK_DEVICES)):
        if not os.path.isdir(os.path.join(rf.SDK_DEVICES, device)):
            continue
        try:
            all_layouts = rf.layouts(device)
            (sw, sh), shape, fonts = rf.device_metrics(device)
        except KeyError as exc:
            if str(exc) == "'layouts'":
                continue          # no data field layouts at all (fr45, swim2)
            problems.append(f"{device}: cannot read metrics ({exc})")
            continue
        except Exception as exc:                      # noqa: BLE001
            problems.append(f"{device}: cannot read metrics ({exc})")
            continue

        for name, cells in sorted(all_layouts.items()):
            for (ox, oy, w, h) in cells:
                ux, uy, uw, uh = rf.usable_rect(w, h, ox, oy, sw, shape)
                tier = rf.tier_of(uw, uh, w, h, sw, sh)
                tiers[tier] += 1
                gx, gy = ox + ux, oy + uy
                boxes = []
                sink = [].append
                if tier == "full":
                    rf.draw_full(sink, STATE, fonts, gx, gy, uw, uh, boxes)
                else:
                    rf.draw_gauge(sink, STATE, fonts, tier, gx, gy, uw, uh,
                                  boxes)
                checked += 1
                where = f"{device} / {name} / {w}x{h} {tier}"

                usable = (gx, gy, gx + uw, gy + uh)
                for tag, x1, y1, x2, y2 in boxes:
                    box = (x1, y1, x2, y2)
                    # A half-pixel of slack: the port measures text from font
                    # tables, the device from its own rasteriser.
                    if not (box[0] >= usable[0] - 0.5
                            and box[1] >= usable[1] - 0.5
                            and box[2] <= usable[2] + 0.5
                            and box[3] <= usable[3] + 0.5):
                        problems.append(
                            f"{where}: {tag} {tuple(round(v) for v in box)} "
                            f"outside usable {tuple(round(v) for v in usable)}")
                    if not corners_on_glass(box, sw, sh, shape):
                        problems.append(
                            f"{where}: {tag} {tuple(round(v) for v in box)} "
                            f"off the glass")

                # The chart is the backdrop the axis labels sit in front of,
                # and the state dot is drawn inside the state label's box, so
                # neither pair is a collision.
                exempt = {frozenset(("chart", "axis")),
                          frozenset(("chart", "value")),
                          frozenset(("chart", "state")),
                          frozenset(("chart", "rate")),
                          frozenset(("chart", "load"))}
                for i in range(len(boxes)):
                    for j in range(i + 1, len(boxes)):
                        ti, tj = boxes[i][0], boxes[j][0]
                        if frozenset((ti, tj)) in exempt:
                            continue
                        if overlaps(boxes[i][1:], boxes[j][1:]):
                            problems.append(
                                f"{where}: {ti} overlaps {tj} — "
                                f"{tuple(round(v) for v in boxes[i][1:])} vs "
                                f"{tuple(round(v) for v in boxes[j][1:])}")

    return checked, tiers, problems


def main():
    checked, tiers, problems = audit()
    print(f"{checked} field rectangles checked  "
          f"(full {tiers['full']}, medium {tiers['medium']}, "
          f"compact {tiers['compact']})")
    if not problems:
        print("no geometry problems")
        return 0
    print(f"\n{len(problems)} problem(s):")
    for p in problems[:60]:
        print("  " + p)
    if len(problems) > 60:
        print(f"  ... and {len(problems) - 60} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
