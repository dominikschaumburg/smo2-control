#!/usr/bin/env python3
"""Render the full-tier layout to SVG, from a real session through the real model.

This is a RENDERING, not a device screenshot. The Connect IQ simulator cannot
feed a generic ANT channel, so a genuine capture needs the watch or SimulANT+.
What this does give you is honest in the ways that matter: the SmO2 values, the
smoothing, the state classification and the chart geometry all come from the
same computation the watch runs, driven by a real .fit file. Only the text
metrics are reconstructed, from the device's own font table in simulator.json.

Usage:
    ./render_field.py <activity.fit> [--lap N] [--offset SECONDS]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import fitreader                                        # noqa: E402
from kinetics_replay import (                           # noqa: E402
    Kinetics, SessionRange,
    STATE_UNKNOWN, STATE_REOXY, STATE_STEADY, STATE_CONTROL, STATE_OVERSHOOT,
    STATE_ONKIN,
)

DEVICE = "fr970"   # overridden by --device
SDK_DEVICES = os.path.expanduser(
    "~/Library/Application Support/Garmin/ConnectIQ/Devices")

# source/Palette.mc
COLOUR = {
    STATE_REOXY: "#00AAFF",
    STATE_STEADY: "#00C853",
    STATE_ONKIN: "#FF8A00",
    STATE_CONTROL: "#FFD600",
    STATE_OVERSHOOT: "#FF3B30",
    STATE_UNKNOWN: "#555555",
}
# Palette.labelForState() with zoneLabels on, which is the default.
LABEL = {
    STATE_REOXY: "ZONE 1", STATE_STEADY: "ZONE 2", STATE_ONKIN: "ONSET",
    STATE_CONTROL: "ZONE 2+", STATE_OVERSHOOT: "ZONE 3", STATE_UNKNOWN: "--",
}

# source/SmO2ControlView.mc
PAD = 4
CHART_WINDOW = 90
CIRCLE_MARGIN = 1.0
# source/ChartRenderer.mc
AUTO_PADDING = 3.0
WINDOW_MIN_SPAN = 25.0


# Median em-height / screen-height across the 114+ devices that declare one.
FONT_RATIO = {
    "xtiny": 0.0505, "small": 0.0769, "medium": 0.0893,
    "large": 0.1000, "numberMild": 0.1111, "numberMedium": 0.1417,
}


def device_metrics(device: str):
    """Screen size, shape and the em size in pixels of each named font.

    Two font descriptions exist in the SDK. Newer devices give a point size
    plus a display ppi; older ones give only a bitmap filename whose trailing
    number IS the pixel size (FNT_..._ROBOTO_13B -> 13 px). Both are needed:
    the audit covers every device the field builds for, and roughly half of
    them predate the ppi field.
    """
    with open(os.path.join(SDK_DEVICES, device, "simulator.json")) as fh:
        cfg = json.load(fh)
    loc = cfg["display"]["location"]
    size = (loc["width"], loc["height"])
    shape = cfg["display"]["shape"]
    ppi = cfg.get("ppi")
    fonts = {}
    for fs in cfg["fonts"]:
        if fs.get("fontSet") != "ww":
            continue
        for f in fs["fonts"]:
            px = None
            if ppi is not None and "size" in f:
                # Sizes are points; the device renders them at its own ppi.
                px = f["size"] * ppi / 72.0
            else:
                m = re.search(r"_(\d+)B?$", f.get("filename", ""))
                if m:
                    px = float(m.group(1))
            if px is not None:
                fonts[f["name"]] = px
        break

    # A handful of older targets name their fonts without any size at all
    # (FNT_..._XLARGE). Their em heights track screen height closely across
    # every device that does declare one, so the median ratio is a good enough
    # stand-in for a geometry audit — and it is only ever a fallback.
    for name, ratio in FONT_RATIO.items():
        if name not in fonts:
            fonts[name] = size[1] * ratio
    return size, shape, fonts


# Roboto hhea ascender / unitsPerEm. Graphics.getFontAscent() returns the
# typographic ascent, so this is the closest reconstruction available offline.
ROBOTO_ASCENT = 1900 / 2048


def build(path: str, lap_index: int, offset: float):
    data = fitreader.decode(path)
    samples = data.smo2_series()
    if not samples:
        raise SystemExit(f"{path}: no SmO2 samples")

    key = data.find_smo2_field()
    t0 = next(r["t"] for r in data.records
              if r.get("t") is not None and r.get(key) is not None)
    laps = [(a - t0, b - t0) for a, b in data.laps]
    if not 1 <= lap_index <= len(laps):
        raise SystemExit(f"lap {lap_index} out of range (1..{len(laps)})")
    lap_start, lap_end = laps[lap_index - 1]
    target = lap_start + offset
    if target > lap_end:
        raise SystemExit(
            f"offset {offset:.0f}s is past the end of lap {lap_index} "
            f"({lap_end - lap_start:.0f}s long)")

    # Load, so the pace/power line shows what was really happening.
    load = {r["t"] - t0: (r.get("power"), r.get("speed"))
            for r in data.records if r.get("t") is not None}

    k = Kinetics(0.30, 0.15, 0.06, 0.15, steady_window=60)
    rng = SessionRange()
    history = []           # (t, level, state) at ~1 Hz, exactly what the ring holds
    for t, v in samples:
        if t > target:
            break
        k.update(t, v)
        if k.level is None:
            continue
        rng.update(t, k.level)
        history.append((t, k.level, k.state))

    if len(history) < 10:
        raise SystemExit("not enough data before the chosen moment")

    # ChartRenderer.centredState(): colour every segment from a window CENTRED
    # on it, shrinking symmetrically at the live edge. Anything else paints the
    # colour beside the shape it describes.
    lag = 60 // 2
    MIN_FIT = 7
    lv = [h[1] for h in history]
    coloured = []
    for i in range(len(history)):
        reach = min(lag, i, len(history) - 1 - i)
        n = 2 * reach + 1
        if n < MIN_FIT:
            coloured.append((history[i][0], lv[i], STATE_UNKNOWN))
            continue
        seg = lv[i - reach:i + reach + 1]
        sy, sxy = sum(seg), sum(j * v for j, v in enumerate(seg))
        nf = float(n)
        sx = nf * (nf - 1) / 2
        sxx = (nf - 1) * nf * (2 * nf - 1) / 6
        slope = (nf * sxy - sx * sy) / (nf * sxx - sx * sx)
        coloured.append((history[i][0], lv[i], k.state_for_slope(slope)))
    window = [h for h in coloured if h[0] > target - CHART_WINDOW]
    return {
        "now": target,
        "level": k.level,
        "state": k.state,
        "slope": k.slow_slope,
        "sci": k.sci(rng.range()),
        "prediction": k.prediction(),
        "min": rng.lo,
        "max": rng.hi,
        "window": window,
        "laps": laps,
        "load": load.get(round(target), (None, None)),
    }


def pace_text(power, speed) -> str:
    """Running: pace in min/km. formatLoad() only uses watts for cycling."""
    if speed and speed > 0.3:
        s = int(1000.0 / speed)
        return f"{s // 60}:{s % 60:02d}"
    return "--:--"


def layouts(device: str):
    """The device's real data field rectangles, per layout."""
    with open(os.path.join(SDK_DEVICES, device, "simulator.json")) as fh:
        cfg = json.load(fh)
    out = {}
    for L in cfg["layouts"][0]["datafields"]["datafields"]:
        out[L["name"]] = [
            (f["location"]["x"], f["location"]["y"],
             f["location"]["width"], f["location"]["height"])
            for f in L["fields"]]
    return out


# Mirrors SmO2ControlView: FULL_MIN_*, FULL_MIN_*_PCT, MEDIUM_MIN_*.
def tier_of(uw, uh, w, h, sw, sh):
    owns = h * 100 >= sh * 45 and w * 100 >= sw * 90
    if owns and uw >= 180 and uh >= 110:
        return "full"
    if uw >= 120 and uh >= 70:
        return "medium"
    return "compact"


def usable_rect(w, h, ox, oy, screen, shape):
    """Port of SmO2ControlView.computeUsableRect / fitRectToCircle."""
    if shape != "round":
        return 0, 0, w, h
    cx, cy = screen / 2.0 - ox, screen / 2.0 - oy
    r = screen / 2.0 - CIRCLE_MARGIN
    step = max(1, h // 16)
    best_area, best_landscape, best = -1, False, (0, 0, w, h)
    for top in range(0, h // 2 + 1, step):
        for bot in range(0, h // 2 + 1, step):
            y1, y2 = top, h - bot
            if y2 - y1 < h / 4:
                continue
            dy = max(abs(y1 - cy), abs(y2 - cy))
            if dy >= r:
                continue
            hw = math.sqrt(r * r - dy * dy)
            x1, x2 = max(0, math.ceil(cx - hw)), min(w, math.floor(cx + hw))
            wd, ht = x2 - x1, y2 - y1
            if wd <= 0:
                continue
            area, landscape = wd * ht, wd >= ht
            better = (landscape and not best_landscape) or (
                landscape == best_landscape and area > best_area)
            if better:
                best_area, best_landscape, best = area, landscape, (x1, y1, wd, ht)
    return best


FAM = "Roboto, Helvetica Neue, Helvetica, Arial, sans-serif"

# Roboto digit / period advance, for offline text measurement.
def text_w(txt, em):
    return em * sum(0.26 if ch == "." else 0.568 for ch in txt)


def dim(hexcol):
    c = int(hexcol[1:], 16)
    return "#%02X%02X%02X" % (((c >> 16) & 255) * 34 // 100,
                              ((c >> 8) & 255) * 34 // 100,
                              (c & 255) * 34 // 100)


def largest_number_font(fonts, sample, avail, max_h):
    """Port of SmO2ControlView.largestNumberFont()."""
    for name in ("numberMedium", "numberMild", "large", "medium", "small"):
        if (text_w(sample, fonts[name]) <= avail
                and fonts[name] * ROBOTO_ASCENT <= max_h):
            return fonts[name]
    return fonts["xtiny"]


def y_bounds(st):
    """ChartRenderer Y_WINDOW bounds: what is on screen, floored."""
    vals = [v for _, v, _ in st["window"]]
    lo, hi = min(vals) - AUTO_PADDING, max(vals) + AUTO_PADDING
    if hi - lo < WINDOW_MIN_SPAN:
        mid = (hi + lo) / 2
        lo, hi = mid - WINDOW_MIN_SPAN / 2, mid + WINDOW_MIN_SPAN / 2
    return max(0.0, lo), min(100.0, hi)


def draw_chart(a, st, x, y, w, h, label_em, show_axis, boxes):
    """Port of ChartRenderer.draw(). Appends every drawn box to `boxes` so the
    geometry checker can look for collisions without parsing SVG."""
    lo, hi = y_bounds(st)
    span = max(1.0, hi - lo)
    label_asc = label_em * ROBOTO_ASCENT

    stack = h >= 5 * label_asc
    axis_w = 0
    if show_axis:
        num_w, word_w = text_w("88", label_em), text_w("MAX", label_em)
        axis_w = int((max(num_w, word_w) if stack
                      else text_w("MAX 88", label_em)) + 4)
    px0, pw = x + axis_w, w - axis_w
    if pw < 20:
        px0, pw, axis_w = x, w, 0
    base_y = y + h

    def py(v):
        return y + h - min(1.0, max(0.0, (v - lo) / span)) * h

    t_end = st["now"]
    step = pw / (CHART_WINDOW - 1)

    def sx(t):
        return px0 + pw - (t_end - t) * step

    if axis_w:
        for yy in (y, base_y, py((lo + hi) / 2)):
            a(f'<line x1="{px0}" y1="{yy:.1f}" x2="{px0+pw}" y2="{yy:.1f}" '
              f'stroke="#555" stroke-width="1"/>')
        lx = px0 - 3
        if stack:
            for word, num, ytop in (("MAX", hi, y),
                                    ("MIN", lo, base_y - 2 * label_asc)):
                a(f'<text x="{lx}" y="{ytop+label_asc:.0f}" font-family="{FAM}" '
                  f'font-size="{label_em:.1f}" fill="#888" text-anchor="end">'
                  f'{word}</text>')
                a(f'<text x="{lx}" y="{ytop+2*label_asc:.0f}" font-family="{FAM}" '
                  f'font-size="{label_em:.1f}" fill="#FFF" text-anchor="end">'
                  f'{num:.0f}</text>')
                boxes.append(("axis", lx - max(text_w("MAX", label_em),
                                               text_w("88", label_em)), ytop,
                              lx, ytop + 2 * label_asc))
        else:
            for txt, ytop in ((f"MAX {hi:.0f}", y),
                              (f"MIN {lo:.0f}", base_y - label_asc)):
                a(f'<text x="{lx}" y="{ytop+label_asc:.0f}" font-family="{FAM}" '
                  f'font-size="{label_em:.1f}" fill="#FFF" text-anchor="end">'
                  f'{txt}</text>')
                boxes.append(("axis", lx - text_w(txt, label_em), ytop,
                              lx, ytop + label_asc))

    for ls, _ in st["laps"]:
        if t_end - CHART_WINDOW < ls <= t_end:
            a(f'<line x1="{sx(ls):.1f}" y1="{y}" x2="{sx(ls):.1f}" '
              f'y2="{base_y}" stroke="#555" stroke-width="1"/>')

    win = st["window"]
    for i in range(1, len(win)):
        t1, v1, _ = win[i - 1]
        t2, v2, s2 = win[i]
        a(f'<polygon shape-rendering="crispEdges" points="{sx(t1):.1f},{py(v1):.1f} '
          f'{sx(t2):.1f},{py(v2):.1f} {sx(t2):.1f},{base_y:.1f} '
          f'{sx(t1):.1f},{base_y:.1f}" fill="{dim(COLOUR[s2])}"/>')
    lw = 3 if show_axis else 2
    for i in range(1, len(win)):
        t1, v1, _ = win[i - 1]
        t2, v2, s2 = win[i]
        a(f'<line x1="{sx(t1):.1f}" y1="{py(v1):.1f}" x2="{sx(t2):.1f}" '
          f'y2="{py(v2):.1f}" stroke="{COLOUR[s2]}" stroke-width="{lw}" '
          f'stroke-linecap="round"/>')

    # Forecast: a triangle at the right edge, pointing the way it is heading.
    if st["prediction"] is not None and win:
        tri = min(9, max(4, pw // 12))
        pyf = min(base_y - tri, max(y + tri, py(st["prediction"])))
        ex = px0 + pw
        lastx, lasty = sx(win[-1][0]), py(win[-1][1])
        a(f'<line x1="{lastx:.1f}" y1="{lasty:.1f}" x2="{ex-tri}" '
          f'y2="{pyf:.1f}" stroke="#555" stroke-width="1"/>')
        c = COLOUR[next((w[2] for w in reversed(win)
                         if w[2] != STATE_UNKNOWN), STATE_UNKNOWN)]
        dy = pyf - lasty
        if dy > 2:
            pts = f"{ex-tri},{pyf-tri:.1f} {ex},{pyf-tri:.1f} {ex-tri/2},{pyf:.1f}"
        elif dy < -2:
            pts = f"{ex-tri},{pyf+tri:.1f} {ex},{pyf+tri:.1f} {ex-tri/2},{pyf:.1f}"
        else:
            pts = f"{ex},{pyf-tri:.1f} {ex},{pyf+tri:.1f} {ex-tri},{pyf:.1f}"
        a(f'<polygon points="{pts}" fill="{c}"/>')

    boxes.append(("chart", x, y, x + w, y + h))


def draw_full(a, st, fonts, gx, gy, uw, uh, boxes):
    """Port of SmO2ControlView.drawFull() plus its share of layoutTier()."""
    label_em = fonts["xtiny"]
    label_asc = label_em * ROBOTO_ASCENT
    dot_r = max(3, int(label_asc / 2))
    state_w = text_w(LABEL[st["state"]], label_em) + 2 * dot_r + PAD
    widest_w = text_w("ZONE 2+", label_em) + 2 * dot_r + PAD
    value_em = largest_number_font(fonts, "88.8", uw - widest_w - 3 * PAD, uh / 3)
    value_asc = value_em * ROBOTO_ASCENT
    head_h = max(value_asc, label_asc)

    left, right, top = gx + PAD, gx + uw - PAD, gy + PAD
    chart_x = gx + PAD
    chart_y = int(gy + PAD + head_h + PAD)
    chart_w = uw - 2 * PAD
    chart_h = max(20, int(gy + uh - PAD - label_asc - PAD - chart_y))

    col = COLOUR[st["state"]]
    head_mid = top + head_h / 2
    a(f'<text x="{left}" y="{head_mid+value_asc/2:.0f}" font-family="{FAM}" '
      f'font-size="{value_em:.1f}" fill="{col}">{st["level"]:.1f}</text>')
    boxes.append(("value", left, head_mid - value_asc / 2,
                  left + text_w("88.8", value_em), head_mid + value_asc / 2))

    a(f'<circle cx="{right-state_w+dot_r:.1f}" cy="{head_mid:.1f}" r="{dot_r}" '
      f'fill="{col}"/>')
    state_icon(a, right - state_w + dot_r, head_mid, dot_r, st["state"], "#000")
    a(f'<text x="{right}" y="{head_mid+label_em*0.35:.0f}" font-family="{FAM}" '
      f'font-size="{label_em:.1f}" fill="#FFF" text-anchor="end">'
      f'{LABEL[st["state"]]}</text>')
    boxes.append(("state", right - state_w, head_mid - label_asc / 2, right,
                  head_mid + label_asc / 2))

    draw_chart(a, st, chart_x, chart_y, chart_w, chart_h, label_em, True, boxes)

    sign = "+" if st["slope"] >= 0 else ""
    rate = f'{sign}{st["slope"]:.3f}%/s'
    load = pace_text(*st["load"])
    foot_top = gy + uh - PAD - label_asc
    a(f'<text x="{left}" y="{gy+uh-PAD:.0f}" font-family="{FAM}" '
      f'font-size="{label_em:.1f}" fill="{col}">{rate}</text>')
    a(f'<text x="{right}" y="{gy+uh-PAD:.0f}" font-family="{FAM}" '
      f'font-size="{label_em:.1f}" fill="#FFF" text-anchor="end">{load}</text>')
    boxes.append(("rate", left, foot_top, left + text_w(rate, label_em),
                  foot_top + label_asc))
    boxes.append(("load", right - text_w(load, label_em), foot_top, right,
                  foot_top + label_asc))


def state_icon(a, cx, cy, r, state, colour):
    """Port of StateIcon.draw(). SVG gets round caps for free; the Monkey C
    fakes them with a disc at every vertex, which comes out the same."""
    if r < 7:
        return
    w = max(2, r / 3)
    half, rise = max(2, r * 0.44), max(1, r * 0.26)
    # Two-element glyphs are drawn smaller and lighter so the pair still fits
    # inside the same disc.
    pw, ph, pr = max(2, w * 3 / 4), max(2, half * 0.85), max(1, rise * 0.7)
    gap = max(2, w)

    def style(sw):
        return (f'stroke="{colour}" stroke-width="{sw:.1f}" '
                f'stroke-linecap="round" stroke-linejoin="round" fill="none"')

    def bar(y, hw, sw):
        a(f'<line x1="{cx-hw:.1f}" y1="{y:.1f}" x2="{cx+hw:.1f}" '
          f'y2="{y:.1f}" {style(sw)}/>')

    def chevron(y, down, hw, rs, sw):
        d = rs if down else -rs
        a(f'<polyline points="{cx-hw:.1f},{y-d:.1f} {cx:.1f},{y+d:.1f} '
          f'{cx+hw:.1f},{y-d:.1f}" {style(sw)}/>')

    if state == STATE_REOXY:
        chevron(cy, False, half, rise, w)
    elif state == STATE_STEADY:
        bar(cy, half, w)
    elif state == STATE_CONTROL:
        chevron(cy, True, half, rise, w)
    elif state == STATE_OVERSHOOT:
        chevron(cy - gap, True, ph, pr, pw)
        chevron(cy + gap, True, ph, pr, pw)
    elif state == STATE_ONKIN:
        bar(cy - gap, ph, pw)
        chevron(cy + gap, True, ph, pr, pw)


def draw_gauge(a, st, fonts, tier, gx, gy, uw, uh, boxes):
    """Port of SmO2ControlView.drawGauge(): a traffic light and one number,
    as a single group centred in the cell, plus an optional second line."""
    label_em = fonts["xtiny"]
    label_asc = label_em * ROBOTO_ASCENT

    show_unit = tier == "medium" and uh >= 3 * label_asc
    content_h = uh - label_asc - PAD if show_unit else uh

    def gap_for(r):
        return max(3, r / 2)

    value_em = fonts["xtiny"]
    for name in ("numberMedium", "numberMild", "large", "medium", "small"):
        asc = fonts[name] * ROBOTO_ASCENT
        w = asc + gap_for(asc / 2) + text_w("88.8", fonts[name])
        if w <= uw - 2 * PAD and asc <= content_h - 2 * PAD:
            value_em = fonts[name]
            break
    value_asc = value_em * ROBOTO_ASCENT
    dot_r = value_asc / 2
    gap = gap_for(dot_r)
    block_h = value_asc + PAD + label_asc if show_unit else value_asc
    block_top = gy + (uh - block_h) / 2
    dot_y = block_top + value_asc / 2

    txt = f'{st["level"]:.1f}'
    tw = text_w(txt, value_em)
    x0 = gx + (uw - (2 * dot_r + gap + tw)) / 2

    a(f'<circle cx="{x0+dot_r:.1f}" cy="{dot_y:.1f}" r="{dot_r:.1f}" '
      f'fill="{COLOUR[st["state"]]}"/>')
    state_icon(a, x0 + dot_r, dot_y, dot_r, st["state"], "#000")
    boxes.append(("dot", x0, dot_y - dot_r, x0 + 2 * dot_r, dot_y + dot_r))

    tx = x0 + 2 * dot_r + gap
    a(f'<text x="{tx:.1f}" y="{dot_y+value_asc*0.36:.1f}" font-family="{FAM}" '
      f'font-size="{value_em:.1f}" fill="#FFF">{txt}</text>')
    boxes.append(("value", tx, dot_y - value_asc / 2, tx + tw,
                  dot_y + value_asc / 2))

    if show_unit:
        sign = "+" if st["slope"] >= 0 else ""
        second = f'{sign}{st["slope"]:.3f}%/s'
        uy0 = block_top + value_asc + PAD
        a(f'<text x="{gx+uw/2:.0f}" y="{uy0+label_asc:.0f}" font-family="{FAM}" '
          f'font-size="{label_em:.1f}" fill="#AAA" text-anchor="middle">'
          f'{second}</text>')
        boxes.append(("unit", gx + uw / 2 - text_w(second, label_em) / 2, uy0,
                      gx + uw / 2 + text_w(second, label_em) / 2,
                      uy0 + label_asc))


def frame(sw, sh, shape):
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{sw}" height="{sh}" '
         f'viewBox="0 0 {sw} {sh}">']
    if shape == "round":
        o.append('<defs><clipPath id="glass">'
                 f'<circle cx="{sw/2}" cy="{sh/2}" r="{sw/2}"/></clipPath></defs>')
    else:
        o.append('<defs><clipPath id="glass">'
                 f'<rect width="{sw}" height="{sh}"/></clipPath></defs>')
    o.append(f'<rect width="{sw}" height="{sh}" fill="#000"/>')
    o.append('<g clip-path="url(#glass)">')
    return o


def close(o, sw, sh, shape):
    o.append('</g>')
    if shape == "round":
        o.append(f'<circle cx="{sw/2}" cy="{sh/2}" r="{sw/2-0.5}" fill="none" '
                 f'stroke="#2A2F37" stroke-width="1"/>')
    else:
        o.append(f'<rect x="0.5" y="0.5" width="{sw-1}" height="{sh-1}" '
                 f'fill="none" stroke="#2A2F37" stroke-width="1"/>')
    o.append('</svg>')


def render(st: dict, out: str, device: str) -> None:
    (sw, sh), shape, fonts = device_metrics(device)
    ux, uy, uw, uh = usable_rect(sw, sh, 0, 0, sw, shape)
    o = frame(sw, sh, shape)
    boxes = []
    draw_full(o.append, st, fonts, ux, uy, uw, uh, boxes)
    close(o, sw, sh, shape)
    with open(out, "w") as fh:
        fh.write("\n".join(o))
    print(f"{out}  ({sw}x{sh}, {shape}, {device})")
    print(f"  usable rect   x {ux}..{ux+uw}, y {uy}..{uy+uh}")
    print(f"  value {st['level']:.1f} %   state {LABEL[st['state']]}   "
          f"slope {st['slope']:+.3f} %/s   SCI {st['sci']:.3f}")


def render_layout(st, out, device, layout_name):
    """Render one of the device's multi-field layouts, our field in every cell.

    The tier each cell gets is decided exactly as onLayout() does, so what
    comes out is the tier the watch would pick.
    """
    (sw, sh), shape, fonts = device_metrics(device)
    cells = layouts(device).get(layout_name)
    if cells is None:
        raise SystemExit(f"unknown layout {layout_name!r}; have: "
                         + ", ".join(layouts(device)))
    o = frame(sw, sh, shape)
    a = o.append
    tiers = []
    for (ox, oy, w, h) in cells:
        ux, uy, uw, uh = usable_rect(w, h, ox, oy, sw, shape)
        tier = tier_of(uw, uh, w, h, sw, sh)
        tiers.append(f"{w}x{h}->{tier}")
        gx, gy = ox + ux, oy + uy
        boxes = []
        if tier == "full":
            draw_full(a, st, fonts, gx, gy, uw, uh, boxes)
        else:
            draw_gauge(a, st, fonts, tier, gx, gy, uw, uh, boxes)
        a(f'<rect x="{ox}" y="{oy}" width="{w}" height="{h}" fill="none" '
          f'stroke="#333" stroke-width="1"/>')
    close(o, sw, sh, shape)
    with open(out, "w") as fh:
        fh.write("\n".join(o))
    print(f"{out}  ({layout_name}, {device})  " + "  ".join(tiers))


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("fit")
    p.add_argument("--lap", type=int, default=4)
    p.add_argument("--offset", type=float, default=100.0,
                   help="seconds into that lap")
    p.add_argument("-o", "--out", default="field-fr970.svg")
    p.add_argument("--device", default=DEVICE)
    p.add_argument("--layout", default=None,
                   help="a device layout name, e.g. \"4 Fields B\"; "
                        "renders the field in every cell of it")
    a = p.parse_args(argv)
    st = build(a.fit, a.lap, a.offset)
    if a.layout:
        render_layout(st, a.out, a.device, a.layout)
    else:
        render(st, a.out, a.device)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
