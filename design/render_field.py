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
# Palette.labelForState() with plainLabels on, which is the default.
LABEL = {
    STATE_REOXY: "RECOVER", STATE_STEADY: "HOLDING", STATE_ONKIN: "ONSET",
    STATE_CONTROL: "DRIFTING", STATE_OVERSHOOT: "FALLING", STATE_UNKNOWN: "--",
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
    "numberHot": 0.1600, "numberThaiHot": 0.1950,
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
        "avg": sum(h[1] for h in history) / len(history),
        "window": window,
        "laps": laps,
        "load": load.get(round(target), (None, None)),
    }


def pace_text(power, speed) -> str:
    """Running: pace in min/km. formatLoad() shows watts or km/h on the bike."""
    if speed and speed > 0.3:
        s = int(1000.0 / speed)
        return f"{s // 60}:{s % 60:02d}"
    return "--:--"


def load_text(st) -> str:
    """The load string. `load_text` in the state overrides it, which is how the
    audit tests the widest string the row can ever hold ("88.8kph")."""
    if st.get("load_text") is not None:
        return st["load_text"]
    return pace_text(*st["load"])


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

# Roboto advances, for offline text measurement: the digit width, the narrow
# period, and the percent sign, which is half again as wide as a digit and now
# rides on the end of the value.
ADVANCE = {".": 0.26, "%": 0.72}


def text_w(txt, em):
    return em * sum(ADVANCE.get(ch, 0.568) for ch in txt)


def dim(hexcol):
    c = int(hexcol[1:], 16)
    return "#%02X%02X%02X" % (((c >> 16) & 255) * 34 // 100,
                              ((c >> 8) & 255) * 34 // 100,
                              (c & 255) * 34 // 100)


def largest_number_font(fonts, sample, avail, max_h):
    """Port of SmO2ControlView.largestNumberFont()."""
    for name in ("numberThaiHot", "numberHot", "numberMedium", "numberMild",
                 "large", "medium", "small"):
        if name not in fonts:
            continue
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


def draw_chart(a, st, x, y, w, h, label_em, show_axis, boxes, tag=""):
    """Port of ChartRenderer.draw(). Appends every drawn box to `boxes` so the
    geometry checker can look for collisions without parsing SVG."""
    lo, hi = y_bounds(st)
    span = max(1.0, hi - lo)
    label_asc = label_em * ROBOTO_ASCENT

    px0, pw = x, w
    base_y = y + h

    def py(v):
        return y + h - min(1.0, max(0.0, (v - lo) / span)) * h

    t_end = st["now"]
    step = pw / (CHART_WINDOW - 1)

    def sx(t):
        return px0 + pw - (t_end - t) * step

    # Gridlines only. The bounds are cells in the grid below the chart now;
    # see drawCells().
    if show_axis:
        for yy in (y, base_y, py((lo + hi) / 2)):
            a(f'<line x1="{px0}" y1="{yy:.1f}" x2="{px0+pw}" y2="{yy:.1f}" '
              f'stroke="#555" stroke-width="1"/>')

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

    # Forecast: a needle at the right edge, pointing in at the level the
    # trend is heading to, the way a dashboard pointer marks a scale.
    if st["prediction"] is not None and win:
        tri = min(20, max(7, h / 8))
        half_b = tri * 3 / 5
        ex = px0 + pw
        pyf = min(base_y - half_b, max(y + half_b, py(st["prediction"])))
        lastx, lasty = sx(win[-1][0]), py(win[-1][1])
        a(f'<line x1="{lastx:.1f}" y1="{lasty:.1f}" x2="{ex-tri:.1f}" '
          f'y2="{pyf:.1f}" stroke="#555" stroke-width="1"/>')
        c = COLOUR[next((wv[2] for wv in reversed(win)
                         if wv[2] != STATE_UNKNOWN), STATE_UNKNOWN)]
        a(f'<polygon points="{ex:.1f},{pyf-half_b:.1f} {ex:.1f},{pyf+half_b:.1f} '
          f'{ex-tri:.1f},{pyf:.1f}" fill="{c}"/>')

    boxes.append(("chart" + tag, x, y, x + w, y + h))


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


NUMBER_FONTS = ("numberThaiHot", "numberHot", "numberMedium", "numberMild",
                "large", "medium", "small", "xtiny")
TEXT_FONTS = ("large", "medium", "small", "xtiny")

# SmO2ControlView.metricSample() / rateRowSample(). The value carries its unit
# now, and the rate shares its row with the load.
VALUE_SAMPLE = "88.8%"
RATE_ROW_SAMPLE = "-8.888%/s 88.8kph"


def chord_at(y_top, y_bot, cx, cy, cr, fw):
    """Port of SmO2ControlView.chordAt(): the full width on a rectangle, the
    chord on a circle, and 0 when the band is off the glass entirely.

    Telling the last two apart matters. Conflating them as "0 means all of it"
    put the bottom row off the display on the Venu 3, whose full-screen field
    sits at x = -6, y = 5 rather than at the origin, so the circle is not
    centred on the field and a band that is fine on an FR970 is past the edge.
    """
    if cr <= 0:
        return fw
    dy = max(abs(y_top - cy), abs(y_bot - cy))
    r_eff = cr - CIRCLE_MARGIN
    if dy >= r_eff:
        return 0
    return min(fw, int(2 * math.sqrt(r_eff * r_eff - dy * dy)))


def plan_cells(fonts, anchor, max_asc, cells, from_top, fh, cx, cy, cr, fw):
    """Port of SmO2ControlView.planCells(). The chord is re-measured for every
    candidate font, because the row height depends on the font and the chord
    depends on the height. Returns (rowH, cellW, cellX, capEm, cellEm) or None.
    """
    cap_em = fonts["xtiny"]
    cap_asc = cap_em * ROBOTO_ASCENT
    cap_w = text_w("MAX", cap_em)
    # The cells print whole per cent, so "88.8" is a deliberate over-estimate.
    sample = "88.8"

    for name in TEXT_FONTS:
        if name not in fonts:
            continue
        em = fonts[name]
        asc = em * ROBOTO_ASCENT
        if asc > max_asc or asc < cap_asc:
            continue
        row_h = cap_asc + asc
        top = anchor if from_top else anchor - row_h
        if top < PAD or top + row_h > fh - PAD:
            continue
        avail = chord_at(top, top + row_h, cx, cy, cr, fw) - 2 * PAD
        if avail <= 0:
            continue
        cw = avail / cells
        inner = cw - 2 * PAD
        if cap_w > inner or text_w(sample, em) > inner:
            continue
        return row_h, cw, cx - avail / 2, top, cap_em, em
    return None


def draw_cells(a, st, x0, y0, cell_w, cells, cap_em, cell_em, boxes, tag):
    """Port of SmO2ControlView.drawCells(): MIN, AVG, MAX."""
    cap_asc = cap_em * ROBOTO_ASCENT
    lo, hi = st["min"], st["max"]
    avg = st.get("avg")
    texts = [("MIN", f"{lo:.0f}", "#FFF"),
             ("AVG", "--" if avg is None else f"{avg:.0f}", "#FFF"),
             ("MAX", f"{hi:.0f}", "#FFF")]
    for i in range(cells):
        cap, txt, col = texts[i]
        cx = x0 + i * cell_w + cell_w / 2
        a(f'<text x="{cx:.0f}" y="{y0+cap_asc:.0f}" font-family="{FAM}" '
          f'font-size="{cap_em:.1f}" fill="#AAA" text-anchor="middle">'
          f'{cap}</text>')
        a(f'<text x="{cx:.0f}" y="{y0+cap_asc+cell_em*ROBOTO_ASCENT:.0f}" '
          f'font-family="{FAM}" font-size="{cell_em:.1f}" fill="{col}" '
          f'text-anchor="middle">{txt}</text>')
        w = max(text_w(cap, cap_em), text_w(txt, cell_em))
        boxes.append((f"cell{i}{tag}", cx - w / 2, y0, cx + w / 2,
                      y0 + cap_asc + cell_em * ROBOTO_ASCENT))


def cell_cap(fonts, value_asc):
    """Port of SmO2ControlView.cellCap(): half the value's height, floored at
    the caption font. Without it plan_cells() takes the largest font that fits
    and the supporting numbers come out bigger than the reading."""
    return max(fonts["xtiny"] * ROBOTO_ASCENT, value_asc / 2)


def fit_by_width(fonts, ladder, sample, avail_w, max_asc):
    """Port of SmO2ControlView.fitByWidth(). No chord, so rectangles only."""
    for name in ladder:
        if name not in fonts:
            continue
        em = fonts[name]
        if em * ROBOTO_ASCENT <= max_asc and text_w(sample, em) <= avail_w:
            return em
    return None


def _fits(fonts, em, sample, y_top, y_bot, with_dot, cx, cy, cr, fw):
    chord = chord_at(y_top, y_bot, cx, cy, cr, fw)
    need = text_w(sample, em) + 2 * PAD
    if with_dot:
        need += em * ROBOTO_ASCENT + PAD
    return need <= chord


def row_font_up(fonts, ladder, sample, bottom, max_asc, with_dot,
                cx, cy, cr, fw):
    """Port of SmO2ControlView.rowFontUp()."""
    for name in ladder:
        if name not in fonts:
            continue
        em = fonts[name]
        asc = em * ROBOTO_ASCENT
        if asc > max_asc or bottom - asc < 0:
            continue
        if _fits(fonts, em, sample, bottom - asc, bottom, with_dot,
                 cx, cy, cr, fw):
            return em
    return None


def row_font_down(fonts, ladder, sample, top, max_asc, fh, cx, cy, cr, fw):
    """Port of SmO2ControlView.rowFontDown()."""
    for name in ladder:
        if name not in fonts:
            continue
        em = fonts[name]
        asc = em * ROBOTO_ASCENT
        if asc > max_asc or top + asc > fh - PAD:
            continue
        if _fits(fonts, em, sample, top, top + asc, False, cx, cy, cr, fw):
            return em
    return None


def draw_full(a, st, fonts, ux, uy, uw, uh, boxes, circle=None, field=None):
    """Port of SmO2ControlView.drawFull() plus its share of layoutTier().

    Everything here is in FIELD coordinates, exactly as the Monkey C sees its
    own device context: (ux, uy) is the usable rectangle's origin inside the
    field, `circle` is (cx, cy, r) in the same frame or None on a rectangular
    screen, and `field` is (w, h) of the context. A caller placing the field
    somewhere other than the screen origin translates the result; mixing the
    two frames here is what made a Venu 3 row look 6 px off the glass when it
    was not.
    """
    label_em = fonts["xtiny"]
    label_asc = label_em * ROBOTO_ASCENT
    fw, fh = field if field else (uw, uh)
    cx, cy, cr = circle if circle else (ux + uw / 2, uy + uh / 2, 0)

    state = LABEL[st["state"]]
    load = load_text(st)
    sign = "+" if st["slope"] >= 0 else ""
    rate = f'{sign}{st["slope"]:.3f}%/s'
    col = COLOUR[st["state"]]
    min_line = fonts["xtiny"] * ROBOTO_ASCENT

    # --- layoutEdges(): rectangle, rows on the edges ---------------------
    # The value and its MIN / AVG / MAX trio above the chart, the state light
    # and the rate/load row below it; see layoutEdges() for why the numbers
    # are grouped that way.
    edges = None
    if cr <= 0 and field is not None:
        avail_w = fw - 2 * PAD
        v_em = fit_by_width(fonts, NUMBER_FONTS, VALUE_SAMPLE, avail_w, fh / 5)
        s_em = fit_by_width(fonts, TEXT_FONTS, "DRIFTING",
                            avail_w - fonts["large"] * ROBOTO_ASCENT - PAD,
                            fh / 10)
        if v_em and s_em:
            v_asc, s_asc = v_em * ROBOTO_ASCENT, s_em * ROBOTO_ASCENT
            r_em = fit_by_width(fonts, TEXT_FONTS, RATE_ROW_SAMPLE, avail_w,
                                max(min_line, s_asc * 3 / 4))
            if r_em:
                r_asc = r_em * ROBOTO_ASCENT
                plan = plan_cells(fonts, 2 * PAD + v_asc,
                                  cell_cap(fonts, v_asc), 3, True,
                                  fh, cx, cy, cr, fw)
                if plan:
                    cell_h, cell_w, cell_x0, cell_y, cap_em, cell_em = plan
                    top_h = 2 * PAD + v_asc + cell_h
                    bot_h = 3 * PAD + s_asc + r_asc
                    ch = fh - top_h - bot_h - 2 * PAD
                    if ch >= 110:
                        state_y = fh - bot_h + PAD
                        edges = (s_em, v_em, r_em,
                                 state_y, PAD,
                                 state_y + s_asc + PAD, cell_y,
                                 top_h + PAD, top_h + PAD + ch, avail_w,
                                 cell_x0, 3, cell_w, cap_em, cell_em, avail_w)

    # --- layoutThirds() --------------------------------------------------
    # Only for a field that *is* the screen; see layoutThirds().
    owns = (field is not None and (cr <= 0
            or (fh * 10 >= cr * 2 * 9 and fw * 10 >= cr * 2 * 9)))
    band = fh // 3
    grid = None
    if owns and band >= 6 * PAD:
        # Rows in a third are searched as a pair, largest first; see
        # layoutThirds() for why a greedy search fails here.
        cap = band - 3 * PAD - min_line

        # Top third: the cell trio against the inner edge, the value above it.
        # The trio takes the shortest row that can hold it (the caption font
        # twice over) and the wider chord, because it is the wider row; see
        # layoutThirds() for the measurement.
        cap_asc = fonts["xtiny"] * ROBOTO_ASCENT
        cellinfo = plan_cells(fonts, band - PAD, cap_asc, 3, False,
                              fh, cx, cy, cr, fw)
        v_em = None
        value_top = 0
        if cellinfo is not None:
            value_bottom = cellinfo[3] - PAD
            for name in NUMBER_FONTS:
                if name not in fonts:
                    continue
                em = fonts[name]
                asc = em * ROBOTO_ASCENT
                if asc > cap or value_bottom - asc < PAD:
                    continue
                if _fits(fonts, em, VALUE_SAMPLE, value_bottom - asc,
                         value_bottom, False, cx, cy, cr, fw):
                    v_em, value_top = em, value_bottom - asc
                    break

        # Bottom third: the state light against the inner edge, the rate and
        # the load sharing the row below it.
        state_top = 2 * band + PAD
        s_em = r_em = None
        rate_top = 0
        rate_w = 0
        for name in TEXT_FONTS:
            if name not in fonts:
                continue
            em = fonts[name]
            asc = em * ROBOTO_ASCENT
            if (asc > cap or (v_em and asc > v_em * ROBOTO_ASCENT)
                    or not _fits(fonts, em, "DRIFTING", state_top,
                                 state_top + asc, True, cx, cy, cr, fw)):
                continue
            r_top = state_top + asc + PAD
            rf = row_font_down(fonts, TEXT_FONTS, RATE_ROW_SAMPLE, r_top,
                               max(min_line, asc * 3 / 4), fh, cx, cy, cr, fw)
            if rf:
                s_em, r_em, rate_top = em, rf, r_top
                rate_w = chord_at(r_top, r_top + rf * ROBOTO_ASCENT,
                                  cx, cy, cr, fw) - 2 * PAD
                break

        ct, cb = band + PAD, 2 * band - PAD
        cw = chord_at(ct, cb, cx, cy, cr, fw) - 8 * PAD
        if v_em and s_em and r_em and cellinfo and cw >= 180:
            cell_h, cell_w, cell_x0, cell_y, cap_em, cell_em = cellinfo
            grid = (s_em, v_em, r_em, state_top, value_top,
                    rate_top, cell_y, ct, cb, cw,
                    cell_x0, 3, cell_w, cap_em, cell_em, rate_w)

    def state_group(x, mid_y, em, centred_flag, tag):
        asc = em * ROBOTO_ASCENT
        dot_r = max(3, int(asc / 2))
        tw = text_w(state, em)
        group_w = 2 * dot_r + PAD + tw
        x0 = x - group_w / 2 if centred_flag else x - group_w
        a(f'<circle cx="{x0+dot_r:.1f}" cy="{mid_y:.1f}" r="{dot_r}" '
          f'fill="{col}"/>')
        state_icon(a, x0 + dot_r, mid_y, dot_r, st["state"], "#000")
        # In the state colour, like the value: drawStateRow() sets one colour
        # for the light and its name.
        a(f'<text x="{x0+2*dot_r+PAD:.1f}" y="{mid_y+asc*0.36:.0f}" '
          f'font-family="{FAM}" font-size="{em:.1f}" fill="{col}">{state}</text>')
        boxes.append((tag, x0, mid_y - asc / 2, x0 + group_w, mid_y + asc / 2))

    def centred(txt, top, em, fill, tag, at=None):
        anchor_x = cx if at is None else at
        asc = em * ROBOTO_ASCENT
        a(f'<text x="{anchor_x:.0f}" y="{top+asc:.0f}" font-family="{FAM}" '
          f'font-size="{em:.1f}" fill="{fill}" text-anchor="middle">{txt}</text>')
        boxes.append((tag, anchor_x - text_w(txt, em) / 2, top,
                      anchor_x + text_w(txt, em) / 2, top + asc))

    if edges:
        grid = edges
    if grid:
        (s_em, v_em, r_em, sy, vy, ry, cy0, ct, cb, cw, cell_x0,
         cells, cell_w, cap_em, cell_em, rate_w) = grid
        anchor = cx
        centred(f'{st["level"]:.1f}%', vy, v_em, col, "value-grid", anchor)
        state_group(anchor, sy + s_em * ROBOTO_ASCENT / 2, s_em, True,
                    "state-grid")
        if rate_w:
            r_asc = r_em * ROBOTO_ASCENT
            lx, rx = anchor - rate_w / 2, anchor + rate_w / 2
            a(f'<text x="{lx:.0f}" y="{ry+r_asc:.0f}" font-family="{FAM}" '
              f'font-size="{r_em:.1f}" fill="{col}">{rate}</text>')
            boxes.append(("rate-grid", lx, ry, lx + text_w(rate, r_em),
                          ry + r_asc))
            a(f'<text x="{rx:.0f}" y="{ry+r_asc:.0f}" font-family="{FAM}" '
              f'font-size="{r_em:.1f}" fill="#FFF" text-anchor="end">'
              f'{load}</text>')
            boxes.append(("load-grid", rx - text_w(load, r_em), ry, rx,
                          ry + r_asc))
        else:
            centred(rate, ry, r_em, col, "rate-grid", anchor)
        draw_cells(a, st, cell_x0, cy0, cell_w, cells, cap_em, cell_em, boxes,
                   "-grid")
        chart_x = PAD if edges else cx - cw / 2
        draw_chart(a, st, chart_x, ct, cw, cb - ct, label_em, True, boxes,
                   "-grid")
        return

    # --- layoutTwoRow() --------------------------------------------------
    dot_r = max(3, int(label_asc / 2))
    state_w = text_w("DRIFTING", label_em) + 2 * dot_r + PAD
    value_em = largest_number_font(fonts, VALUE_SAMPLE, uw - state_w - 3 * PAD,
                                   uh / 3)
    value_asc = value_em * ROBOTO_ASCENT
    head_h = max(value_asc, label_asc)
    rate_y = uy + uh - PAD - label_asc
    chart_y = int(uy + PAD + head_h + PAD)
    chart_h = max(20, int(rate_y - PAD - chart_y))
    left, right = ux + PAD, ux + uw - PAD
    head_mid = uy + PAD + head_h / 2

    a(f'<text x="{left}" y="{head_mid+value_asc/2:.0f}" font-family="{FAM}" '
      f'font-size="{value_em:.1f}" fill="{col}">{st["level"]:.1f}%</text>')
    boxes.append(("value", left, head_mid - value_asc / 2,
                  left + text_w(VALUE_SAMPLE, value_em),
                  head_mid + value_asc / 2))
    state_group(right, head_mid, label_em, False, "state")
    a(f'<text x="{left}" y="{rate_y+label_asc:.0f}" font-family="{FAM}" '
      f'font-size="{label_em:.1f}" fill="{col}">{rate}</text>')
    boxes.append(("rate", left, rate_y, left + text_w(rate, label_em),
                  rate_y + label_asc))

    # The range in the middle of the footer, where the rate and the load leave
    # room for it; see layoutTwoRow().
    foot_w = (text_w("-8.888%/s", label_em) + text_w("88.8kph DEC", label_em)
              + text_w("88-88", label_em) + 4 * PAD)
    if foot_w <= uw - 2 * PAD:
        rng = f'{st["min"]:.0f}-{st["max"]:.0f}'
        mid = ux + uw / 2
        a(f'<text x="{mid:.0f}" y="{rate_y+label_asc:.0f}" font-family="{FAM}" '
          f'font-size="{label_em:.1f}" fill="#AAA" text-anchor="middle">'
          f'{rng}</text>')
        boxes.append(("range", mid - text_w(rng, label_em) / 2, rate_y,
                      mid + text_w(rng, label_em) / 2, rate_y + label_asc))
    a(f'<text x="{right}" y="{rate_y+label_asc:.0f}" font-family="{FAM}" '
      f'font-size="{label_em:.1f}" fill="#FFF" text-anchor="end">{load}</text>')
    boxes.append(("load", right - text_w(load, label_em), rate_y, right,
                  rate_y + label_asc))
    draw_chart(a, st, ux + PAD, chart_y, uw - 2 * PAD, chart_h, label_em, True,
               boxes)


def draw_gauge(a, st, fonts, tier, ux, uy, uw, uh, boxes):
    """Port of SmO2ControlView.drawGauge(): a traffic light and one number,
    as a single group centred in the cell, plus an optional second line."""
    label_em = fonts["xtiny"]
    label_asc = label_em * ROBOTO_ASCENT

    show_unit = tier == "medium" and uh >= 3 * label_asc
    content_h = uh - label_asc - PAD if show_unit else uh

    def gap_for(r):
        return max(3, r / 2)

    # The full number ladder, as largestGaugeFont() walks it. Stopping at
    # numberMedium here made the audit optimistic: the watch would pick a
    # larger font than the port had measured.
    value_em = fonts["xtiny"]
    for name in NUMBER_FONTS:
        if name not in fonts:
            continue
        asc = fonts[name] * ROBOTO_ASCENT
        w = asc + gap_for(asc / 2) + text_w(VALUE_SAMPLE, fonts[name])
        if w <= uw - 2 * PAD and asc <= content_h - 2 * PAD:
            value_em = fonts[name]
            break
    value_asc = value_em * ROBOTO_ASCENT
    dot_r = value_asc / 2
    gap = gap_for(dot_r)
    block_h = value_asc + PAD + label_asc if show_unit else value_asc
    block_top = uy + (uh - block_h) / 2
    dot_y = block_top + value_asc / 2

    txt = f'{st["level"]:.1f}%'
    tw = text_w(txt, value_em)
    x0 = ux + (uw - (2 * dot_r + gap + tw)) / 2

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
        a(f'<text x="{ux+uw/2:.0f}" y="{uy0+label_asc:.0f}" font-family="{FAM}" '
          f'font-size="{label_em:.1f}" fill="#AAA" text-anchor="middle">'
          f'{second}</text>')
        boxes.append(("unit", ux + uw / 2 - text_w(second, label_em) / 2, uy0,
                      ux + uw / 2 + text_w(second, label_em) / 2,
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
    circle = (sw / 2.0, sh / 2.0, sw / 2.0) if shape == "round" else None
    draw_full(o.append, st, fonts, ux, uy, uw, uh, boxes, circle, (sw, sh))
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
        boxes = []
        # The field draws in its own coordinates, so the cell is placed by a
        # transform rather than by adding the origin to every number. On a
        # device whose full-screen field is not at the screen origin (the
        # Venu 3 sits at -6, 5) the two are not the same thing.
        a(f'<g transform="translate({ox},{oy})">')
        if tier == "full":
            circle = ((sw / 2.0 - ox, sh / 2.0 - oy, sw / 2.0)
                      if shape == "round" else None)
            draw_full(a, st, fonts, ux, uy, uw, uh, boxes, circle, (w, h))
        else:
            draw_gauge(a, st, fonts, tier, ux, uy, uw, uh, boxes)
        a('</g>')
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
