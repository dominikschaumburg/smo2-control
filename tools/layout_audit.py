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
    "state": rf.STATE_CONTROL,      # "DRIFTING", the longest state label
    "slope": -8.888,                # "-8.888%/s", the longest rate string
    "sci": 0.5,
    "prediction": 40.0,
    "now": 100.0,
    "laps": [],
    "load": (None, 1.5),
    "load_text": "88.8kph",   # the widest load string the row is sized for
    # Three digits in every cell, which is the widest they can get.
    "min": 100.0,
    "avg": 100.0,
    "max": 100.0,
    "window": [(t, 50.0, rf.STATE_STEADY) for t in range(11, 101)],
}


def overlaps(a, b):
    return not (a[3] <= b[1] or b[3] <= a[1] or a[2] <= b[0] or b[2] <= a[0])


def corners_on_glass(box, sw, sh, shape, origin=(0, 0)):
    """Is every corner of `box` on the display?

    The box is in field coordinates, the way the field's own drawing code sees
    it, so `origin` is where the field sits on the screen. Skipping that
    translation reads a Venu 3, whose full-screen field starts at (-6, 5), six
    pixels off from the truth.
    """
    ox, oy = origin
    x1, y1, x2, y2 = box[0] + ox, box[1] + oy, box[2] + ox, box[3] + oy
    if shape != "round":
        return x1 >= 0 and y1 >= 0 and x2 <= sw and y2 <= sh
    cx, cy, r = sw / 2.0, sh / 2.0, sw / 2.0
    for x in (x1, x2):
        for y in (y1, y2):
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
                boxes = []
                sink = [].append
                if tier == "full":
                    circle = ((sw / 2.0 - ox, sh / 2.0 - oy, sw / 2.0)
                              if shape == "round" else None)
                    rf.draw_full(sink, STATE, fonts, ux, uy, uw, uh, boxes,
                                 circle, (w, h))
                else:
                    rf.draw_gauge(sink, STATE, fonts, tier, ux, uy, uw, uh,
                                  boxes)
                checked += 1
                where = f"{device} / {name} / {w}x{h} {tier}"

                # Everything below is in field coordinates; (ox, oy) is only
                # needed to ask whether a box is on the glass.
                usable = (ux, uy, ux + uw, uy + uh)
                for tag, x1, y1, x2, y2 in boxes:
                    box = (x1, y1, x2, y2)
                    if tag.endswith("-grid"):
                        # The thirds grid lays out against the whole field
                        # rather than the inscribed rectangle: a row of text
                        # needs only the chord at its own height. So being
                        # outside the rectangle is correct here, and the test
                        # that matters is whether it is on the glass.
                        if not corners_on_glass(box, sw, sh, shape, (ox, oy)):
                            problems.append(
                                f"{where}: {tag} "
                                f"{tuple(round(v) for v in box)} off the glass")
                        continue
                    # A half-pixel of slack: the port measures text from font
                    # tables, the device from its own rasteriser.
                    if not (box[0] >= usable[0] - 0.5
                            and box[1] >= usable[1] - 0.5
                            and box[2] <= usable[2] + 0.5
                            and box[3] <= usable[3] + 0.5):
                        problems.append(
                            f"{where}: {tag} {tuple(round(v) for v in box)} "
                            f"outside usable {tuple(round(v) for v in usable)}")
                    if not corners_on_glass(box, sw, sh, shape, (ox, oy)):
                        problems.append(
                            f"{where}: {tag} {tuple(round(v) for v in box)} "
                            f"off the glass")

                # The chart is the backdrop the axis labels sit in front of,
                # and the state dot is drawn inside the state label's box, so
                # neither pair is a collision.
                # The axis labels legitimately sit inside the plot rectangle;
                # nothing else may. The state dot is drawn inside the state
                # label's own box, so that is not a pair either.
                def kind(t):
                    return t[:-5] if t.endswith("-grid") else t
                for i in range(len(boxes)):
                    for j in range(i + 1, len(boxes)):
                        ti, tj = kind(boxes[i][0]), kind(boxes[j][0])
                        if frozenset((ti, tj)) == frozenset(("chart", "axis")):
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
