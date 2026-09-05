#!/usr/bin/env python3
"""Figures and worked-example numbers for docs/paper/smo2-control.tex.

Everything here runs the REAL model (tools/kinetics_replay.py, the Python port
of source/Kinetics.mc) over a real recorded session, so every number in the
paper is one the watch would have produced. Nothing is drawn from a sketch.

Usage:
    ./figures.py <activity.fit>          # writes figures/*.pdf and numbers.json
"""

from __future__ import annotations

import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
from matplotlib.patches import Patch     # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
import kinetics_replay as kr              # noqa: E402

OUT = os.path.join(HERE, "figures")
os.makedirs(OUT, exist_ok=True)

# Print variants of Palette.mc. The watch colours are a status palette for a
# black OLED; on white paper they are too light and too close. These keep the
# hue meaning (blue up, green flat, ochre drift, red fall, orange onset) at a
# lightness that reads on paper. Identity is never colour-alone in any figure:
# every band carries its name.
COL = {
    kr.STATE_REOXY: "#0B5CB5",
    kr.STATE_STEADY: "#1E7A34",
    kr.STATE_CONTROL: "#B08900",
    kr.STATE_OVERSHOOT: "#B71C1C",
    kr.STATE_ONKIN: "#EF6C00",
    kr.STATE_UNKNOWN: "#9E9E9E",
}
NAME = {
    kr.STATE_REOXY: "RECOVER", kr.STATE_STEADY: "HOLDING",
    kr.STATE_CONTROL: "DRIFTING", kr.STATE_OVERSHOOT: "FALLING",
    kr.STATE_ONKIN: "ONSET", kr.STATE_UNKNOWN: "?",
}
INK, INK2, GRID, RAW = "#1F1F1F", "#5F5F5F", "#E3E3E3", "#B5B5B5"

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.size": 9,
    "axes.edgecolor": INK2,
    "axes.labelcolor": INK,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.color": GRID,
    "grid.linewidth": 0.6,
    "xtick.color": INK2,
    "ytick.color": INK2,
    "lines.linewidth": 1.5,
    "legend.frameon": False,
    "figure.dpi": 150,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.03,
})

ALPHA, BETA, TH_S, TH_D, WIN, HORIZON = 0.30, 0.15, 0.06, 0.15, 60, 15


class Args:
    dev_field = None
    time_col = "t"
    smo2_col = "smo2"


def run(samples):
    """Run the model, keeping the trend BEFORE each update so the Holt step
    can be reproduced by hand in the paper."""
    k = kr.Kinetics(ALPHA, BETA, TH_S, TH_D, predict_horizon=HORIZON,
                    steady_window=WIN)
    rows = []
    for t, raw in samples:
        t_prev, l_prev = k._last_t, k.level
        trend_prev = k.trend
        k.update(t, raw)
        rows.append(dict(t=t, raw=raw, level=k.level, trend=k.trend,
                         trend_prev=trend_prev, level_prev=l_prev,
                         t_prev=t_prev, slope=k.slow_slope, state=k.state,
                         pred=k.prediction()))
    return rows


def bands(ax, rows, y0, y1, alpha=0.18):
    """Shade the state under the curve, one span per run, and name each run
    that is long enough to hold a word."""
    start = 0
    for i in range(1, len(rows) + 1):
        if i == len(rows) or rows[i]["state"] != rows[start]["state"]:
            st = rows[start]["state"]
            ta, tb = rows[start]["t"], rows[i - 1]["t"]
            ax.axvspan(ta, tb, color=COL[st], alpha=alpha, lw=0)
            if tb - ta >= 40 and st != kr.STATE_UNKNOWN:
                ax.text((ta + tb) / 2, y1, NAME[st], ha="center", va="top",
                        fontsize=7, color=COL[st], fontweight="bold")
            start = i


def strip(ax, rows, letters=True):
    """A thin state timeline, letter-coded so it reads in greyscale."""
    for r in rows:
        ax.axvspan(r["t"] - 0.5, r["t"] + 0.5, color=COL[r["state"]], lw=0)
    ax.set_yticks([])
    ax.set_ylim(0, 1)
    ax.grid(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_visible(False)
    if letters:
        start = 0
        for i in range(1, len(rows) + 1):
            if i == len(rows) or rows[i]["state"] != rows[start]["state"]:
                st = rows[start]["state"]
                if rows[i - 1]["t"] - rows[start]["t"] >= 12:
                    ax.text((rows[start]["t"] + rows[i - 1]["t"]) / 2, 0.5,
                            NAME[st][0], ha="center", va="center",
                            fontsize=6.5, color="white", fontweight="bold")
                start = i


def legend(ax, states, loc="upper right"):
    ax.legend(handles=[Patch(color=COL[s], alpha=0.5, label=NAME[s])
                       for s in states], loc=loc, fontsize=7, ncol=len(states),
              handlelength=1.0, columnspacing=0.8)


def window(rows, labels, lap, pad_before=60):
    idx = [i for i, l in enumerate(labels) if l == lap]
    a, b = idx[0], idx[-1]
    return rows[max(0, a - pad_before):b + 1], rows[a]["t"], rows[b]["t"]


# ---------------------------------------------------------------------------

def fig_signal(rows, labels, num):
    seg, t0, t1 = window(rows, labels, "lap02")
    fig, (ax, axs) = plt.subplots(2, 1, figsize=(6.4, 3.4), sharex=True,
                                  gridspec_kw=dict(height_ratios=[10, 1],
                                                   hspace=0.05))
    t = [r["t"] - t0 for r in seg]
    ax.scatter(t, [r["raw"] for r in seg], s=4, color=RAW, lw=0,
               label="Rohwert (Moxy, 1 Hz)", zorder=2)
    ax.plot(t, [r["level"] for r in seg], color=INK, label="Level $L_t$ (Holt)",
            zorder=3)
    lo = min(r["raw"] for r in seg) - 3
    hi = max(r["raw"] for r in seg) + 6
    bands(ax, [dict(r, t=r["t"] - t0) for r in seg], lo, hi - 0.5)
    ax.axvline(0, color=INK2, lw=0.8, ls=":")
    ax.text(1, lo + 0.5, "Lap", fontsize=7, color=INK2)
    ax.set_ylim(lo, hi)
    ax.set_ylabel("SmO$_2$ (%)")
    ax.legend(loc="upper right", fontsize=7)
    strip(axs, [dict(r, t=r["t"] - t0) for r in seg])
    axs.set_xlabel("Zeit seit Intervallbeginn (s)")
    fig.savefig(os.path.join(OUT, "signal.pdf"))
    plt.close(fig)
    num["lap02_start"] = seg[len(seg) - 1 - int(t1 - t0)]["level"]
    num["lap02_end"] = seg[-1]["level"]


def fig_slope(rows, labels, num):
    seg, t0, t1 = window(rows, labels, "lap02")
    fig, (ax, axs) = plt.subplots(2, 1, figsize=(6.4, 3.4), sharex=True,
                                  gridspec_kw=dict(height_ratios=[10, 1],
                                                   hspace=0.05))
    t = [r["t"] - t0 for r in seg]
    # Threshold bands, named at the right edge so the colour is never alone.
    edges = [(TH_S, 99, kr.STATE_REOXY), (-TH_S, TH_S, kr.STATE_STEADY),
             (-TH_D, -TH_S, kr.STATE_CONTROL), (-2 * TH_D, -TH_D, kr.STATE_OVERSHOOT),
             (-99, -2 * TH_D, kr.STATE_ONKIN)]
    for lo, hi, st in edges:
        ax.axhspan(lo, hi, color=COL[st], alpha=0.12, lw=0)
    for y, lab in ((TH_S, r"$+\theta_{stable}$"), (-TH_S, r"$-\theta_{stable}$"),
                   (-TH_D, r"$-\theta_{drift}$"), (-2 * TH_D, r"$-2\,\theta_{drift}$")):
        ax.axhline(y, color=INK2, lw=0.6, ls="--")
        ax.text(t[-1] + 2, y, lab, fontsize=7, va="center", color=INK2)
    for lo, hi, st in edges:
        yy = max(min((lo + hi) / 2, 0.16), -0.42) if abs(lo) == 99 or abs(hi) == 99 else (lo + hi) / 2
        ax.text(t[0] + 2, yy, NAME[st], fontsize=6.5, color=COL[st],
                fontweight="bold", va="center")
    ax.plot(t, [r["slope"] for r in seg], color=INK,
            label="Regressionssteigung, 60 s Fenster")
    ax.plot(t, [r["trend"] for r in seg], color=INK2, lw=0.8, alpha=0.7,
            label="Holt-Trend $T_t$ (zum Vergleich)")
    ax.set_ylim(-0.45, 0.2)
    ax.set_xlim(t[0], t[-1] + 45)
    ax.set_ylabel("Steigung (%/s)")
    ax.legend(loc="lower right", fontsize=7)
    strip(axs, [dict(r, t=r["t"] - t0) for r in seg])
    axs.set_xlim(t[0], t[-1] + 45)
    axs.set_xlabel("Zeit seit Intervallbeginn (s)")
    fig.savefig(os.path.join(OUT, "slope.pdf"))
    plt.close(fig)

    # How often the Holt trend leaves the plateau band while the regression
    # says HOLDING: the measurement behind "two timescales".
    plateau = [r for r in seg if r["state"] == kr.STATE_STEADY]
    if plateau:
        out = sum(1 for r in plateau if abs(r["trend"]) > TH_S) / len(plateau)
        num["holt_outside_band_pct"] = 100 * out
        num["holt_outside_015_pct"] = 100 * sum(
            1 for r in plateau if abs(r["trend"]) > 0.15) / len(plateau)
        num["plateau_samples"] = len(plateau)


def recovery_lap(rows, labels):
    """First recovery lap of 100 to 200 s with no hole in the data, so the
    forecast figure shows the estimator and not a dropout."""
    groups = {}
    for r, lab in zip(rows, labels):
        groups.setdefault(lab, []).append(r)

    def clean(g):
        return not any(b["t"] - a["t"] > 5 for a, b in zip(g, g[1:]))

    # Recovery laps preferred; failing that, the first clean work interval.
    # In the reference session the recording pauses between intervals, so
    # every recovery lap holds a hole and the work interval is what is left.
    for want_recovery in (True, False):
        for lab in sorted(groups):
            g = groups[lab]
            dur = g[-1]["t"] - g[0]["t"]
            rising = g[-1]["level"] > g[0]["level"]
            if 100 <= dur <= 400 and rising == want_recovery and clean(g):
                return lab
    return "lap02"


def fig_forecast(rows, labels, num):
    lap = recovery_lap(rows, labels)
    num["fc_lap"] = lap
    seg, t0, t1 = window(rows, labels, lap, pad_before=20)
    fig, ax = plt.subplots(figsize=(6.4, 2.8))
    t = [r["t"] - t0 for r in seg]
    ax.plot(t, [r["level"] for r in seg], color=INK, label="Level $L_t$")
    # Each forecast is a statement about t + h; draw it there.
    fx = [r["t"] - t0 + HORIZON for r in seg if r["pred"] is not None]
    fy = [r["pred"] for r in seg if r["pred"] is not None]
    ax.plot(fx, fy, color=COL[kr.STATE_REOXY], lw=1.0, ls="--",
            label=f"Prognose $\\hat L_{{t+{HORIZON}}}$, an $t+{HORIZON}$ gezeichnet")
    # One worked example: pick the sample 40 s into the recovery.
    i = next(j for j, r in enumerate(seg) if r["t"] - t0 >= 40)
    r = seg[i]
    ax.annotate("", xy=(r["t"] - t0 + HORIZON, r["pred"]),
                xytext=(r["t"] - t0, r["level"]),
                arrowprops=dict(arrowstyle="->", color=COL[kr.STATE_REOXY], lw=1.2))
    ax.plot([r["t"] - t0], [r["level"]], "o", color=INK, ms=4)
    ax.set_xlabel("Zeit seit Rundenbeginn (s)")
    ax.set_ylabel("SmO$_2$ (%)")
    ax.legend(loc="upper right", fontsize=7)
    fig.savefig(os.path.join(OUT, "forecast.pdf"))
    plt.close(fig)
    num["fc_t"] = r["t"] - t0
    num["fc_level"] = r["level"]
    num["fc_trend"] = r["trend"]
    num["fc_pred"] = r["pred"]
    # what actually happened h seconds later
    later = next((q for q in seg if q["t"] >= r["t"] + HORIZON), None)
    num["fc_actual"] = later["level"] if later else None

    # Forecast error over the whole session, by state at forecast time.
    by_t = {round(q["t"]): q for q in rows}
    errs = {}
    for q in rows:
        if q["pred"] is None:
            continue
        a = by_t.get(round(q["t"]) + HORIZON)
        if a is None or a["t_prev"] is None or a["t"] - a["t_prev"] > 5:
            continue
        errs.setdefault(q["state"], []).append(a["level"] - q["pred"])
    num["fc_rmse_by_state"] = {
        NAME[s]: (sum(e * e for e in v) / len(v)) ** 0.5
        for s, v in errs.items() if len(v) > 30 and s != kr.STATE_UNKNOWN}
    allv = [e for v in errs.values() for e in v]
    num["fc_rmse_all"] = (sum(e * e for e in allv) / len(allv)) ** 0.5
    # naive baseline: "it stays where it is"
    naive = []
    for q in rows:
        a = by_t.get(round(q["t"]) + HORIZON)
        if a is not None and a["t_prev"] is not None and a["t"] - a["t_prev"] <= 5:
            naive.append(a["level"] - q["level"])
    num["fc_rmse_naive"] = (sum(e * e for e in naive) / len(naive)) ** 0.5


def fig_sci(rows, labels, num):
    groups = {}
    for r, lab in zip(rows, labels):
        groups.setdefault(lab, []).append(r)
    laps = []
    for lab in sorted(groups):
        g = groups[lab]
        dur = g[-1]["t"] - g[0]["t"]
        if dur < 200 or dur > 600:
            continue                       # the 6-minute work steps only
        start, end = g[0]["level"], g[-1]["level"]
        if end >= start:
            continue                       # recoveries are not steps
        laps.append(dict(lap=lab, start=start, end=end, drop=start - end,
                         ratio=end / start, rate=(end - start) / dur, dur=dur,
                         steady=100 * sum(1 for r in g if r["state"] == kr.STATE_STEADY) / len(g)))
    num["steps"] = laps

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(6.4, 2.6))
    x = list(range(1, len(laps) + 1))
    a1.bar(x, [l["drop"] for l in laps], color=COL[kr.STATE_OVERSHOOT], width=0.6, lw=0)
    for xi, l in zip(x, laps):
        a1.text(xi, l["drop"] + 0.6, f"{l['drop']:.1f}", ha="center", fontsize=7, color=INK)
    a1.set_xticks(x)
    a1.set_xticklabels([f"Stufe {i}" for i in x], fontsize=7)
    a1.set_ylabel("SCI, Abfall (Prozentpunkte)")
    a1.set_ylim(0, max(l["drop"] for l in laps) * 1.18)
    a1.grid(axis="x", visible=False)
    a2.plot(x, [l["ratio"] for l in laps], "o-", color=COL[kr.STATE_REOXY], ms=5)
    for xi, l in zip(x, laps):
        a2.text(xi, l["ratio"] + 0.02, f"{l['ratio']:.2f}", ha="center", fontsize=7, color=INK)
    a2.set_xticks(x)
    a2.set_xticklabels([f"Stufe {i}" for i in x], fontsize=7)
    a2.set_ylabel("SCI, Verhältnis Ende / Start")
    a2.set_ylim(min(l["ratio"] for l in laps) - 0.1, max(l["ratio"] for l in laps) + 0.12)
    fig.savefig(os.path.join(OUT, "sci.pdf"))
    plt.close(fig)


def fig_synthetic(num):
    samples = list(kr.synthetic())
    rows = run([(t, v) for t, v, _ in samples])
    labels = [lab for _, _, lab in samples]
    fig, axes = plt.subplots(2, 1, figsize=(6.4, 4.0), sharex=False,
                             gridspec_kw=dict(hspace=0.45))
    for ax, lap, title in zip(axes, ("work1", "work3"),
                              ("Nachhaltiges Intervall (work1): ONSET, dann HOLDING",
                               "Nicht nachhaltiges Intervall (work3): ONSET, dann FALLING und DRIFTING")):
        seg, t0, t1 = window(rows, labels, lap, pad_before=30)
        seg = [dict(r, t=r["t"] - t0) for r in seg]
        t = [r["t"] for r in seg]
        ax.scatter(t, [r["raw"] for r in seg], s=3, color=RAW, lw=0)
        ax.plot(t, [r["level"] for r in seg], color=INK)
        lo = min(r["raw"] for r in seg) - 3
        hi = max(r["raw"] for r in seg) + 7
        bands(ax, seg, lo, hi - 0.5)
        ax.set_ylim(lo, hi)
        ax.set_title(title, fontsize=8, loc="left", color=INK)
        ax.set_ylabel("SmO$_2$ (%)")
        g = [r for r in seg if 0 <= r["t"] <= t1 - t0]
        num[f"syn_{lap}_steady_pct"] = 100 * sum(
            1 for r in g if r["state"] == kr.STATE_STEADY) / len(g)
        num[f"syn_{lap}_onkin_pct"] = 100 * sum(
            1 for r in g if r["state"] == kr.STATE_ONKIN) / len(g)
    axes[-1].set_xlabel("Zeit seit Intervallbeginn (s)")
    fig.savefig(os.path.join(OUT, "synthetic.pdf"))
    plt.close(fig)


def worked_examples(rows, labels, samples, num):
    """Numbers for the by-hand calculations in the paper."""
    # --- Holt: one update, 60 s into lap02 ---------------------------------
    idx = [i for i, l in enumerate(labels) if l == "lap02"]
    i = idx[0] + 60
    r = rows[i]
    med = sorted(s[1] for s in samples[i - 2:i + 1])[1]
    dt = r["t"] - r["t_prev"]
    fc = r["level_prev"] + r["trend_prev"] * dt
    lvl = ALPHA * med + (1 - ALPHA) * fc
    slope = (lvl - r["level_prev"]) / dt
    trend = BETA * slope + (1 - BETA) * r["trend_prev"]
    assert abs(lvl - r["level"]) < 1e-6 and abs(trend - r["trend"]) < 1e-6
    num["holt"] = dict(raw3=[s[1] for s in samples[i - 2:i + 1]], median=med,
                       dt=dt, L_prev=r["level_prev"], T_prev=r["trend_prev"],
                       forecast=fc, L=lvl, slope=slope, T=trend)

    # --- Regression: a 7-sample window from inside the plateau --------------
    j = next(k for k in idx[120:] if rows[k]["state"] == kr.STATE_STEADY)
    win = rows[j - 6:j + 1]
    y = [w["level"] for w in win]
    n = len(y)
    sy = sum(y)
    sxy = sum(k * v for k, v in enumerate(y))
    sx = n * (n - 1) / 2
    sxx = (n - 1) * n * (2 * n - 1) / 6
    per_sample = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    span = win[-1]["t"] - win[0]["t"]
    num["regression"] = dict(y=y, n=n, sy=sy, sxy=sxy, sx=sx, sxx=sxx,
                             per_sample=per_sample, span=span,
                             slope=per_sample * (n - 1) / span,
                             slope60=rows[j]["slope"], t=rows[j]["t"] - rows[idx[0]]["t"])

    # --- SCI for lap02 ------------------------------------------------------
    g = [rows[k] for k in idx]
    num["sci_lap02"] = dict(start=g[0]["level"], end=g[-1]["level"],
                            dur=g[-1]["t"] - g[0]["t"])


def dwell_counts(samples, num):
    """Flicker with and without the dwell, for the robustness section."""
    def short_runs(dwell):
        kr.STATE_DWELL = dwell
        k = kr.Kinetics(ALPHA, BETA, TH_S, TH_D, steady_window=WIN)
        st = []
        for t, v in samples:
            k.update(t, v)
            st.append(k.state)
        runs, cur = [], 1
        for a, b in zip(st, st[1:]):
            if a == b:
                cur += 1
            else:
                runs.append(cur)
                cur = 1
        runs.append(cur)
        return sum(1 for r in runs if r < 5), len(runs)
    num["dwell"] = {d: short_runs(d) for d in (1, 2, 3, 4)}
    kr.STATE_DWELL = 3


def main(path):
    samples, labels = kr.load(path, Args())
    rows = run(samples)
    num = {"file": os.path.basename(path), "n": len(samples)}
    fig_signal(rows, labels, num)
    fig_slope(rows, labels, num)
    fig_forecast(rows, labels, num)
    fig_sci(rows, labels, num)
    fig_synthetic(num)
    worked_examples(rows, labels, samples, num)
    dwell_counts(samples, num)
    with open(os.path.join(HERE, "numbers.json"), "w") as fh:
        json.dump(num, fh, indent=2)
    emit_tex(num)
    print(json.dumps(num, indent=2))


# LaTeX row terminator, kept out of the f-strings where its backslashes are
# easy to mangle.
ROW_END = " \\\\"
ROW_SEP = ROW_END + "\n"


def emit_tex(num):
    """Every number the paper quotes, as a LaTeX macro, so the text can never
    drift from the data it describes."""
    h, g, f = num["holt"], num["regression"], num
    m = {
        "File": num["file"].replace("_", "\\_"), "N": num["n"],
        "HoltRawA": f"{h['raw3'][0]:.1f}", "HoltRawB": f"{h['raw3'][1]:.1f}",
        "HoltRawC": f"{h['raw3'][2]:.1f}", "HoltMed": f"{h['median']:.1f}",
        "HoltDt": f"{h['dt']:.1f}", "HoltLprev": f"{h['L_prev']:.3f}",
        "HoltTprev": f"{h['T_prev']:.4f}", "HoltFc": f"{h['forecast']:.3f}",
        "HoltL": f"{h['L']:.3f}", "HoltSlope": f"{h['slope']:.4f}",
        "HoltT": f"{h['T']:.4f}",
        "RegN": g["n"], "RegSy": f"{g['sy']:.3f}", "RegSxy": f"{g['sxy']:.3f}",
        "RegSx": f"{g['sx']:.0f}", "RegSxx": f"{g['sxx']:.0f}",
        "RegPerSample": f"{g['per_sample']:.4f}", "RegSpan": f"{g['span']:.0f}",
        "RegSlope": f"{g['slope']:.4f}", "RegSlopeSixty": f"{g['slope60']:.4f}",
        "RegT": f"{g['t']:.0f}",
        "RegRows": ROW_SEP.join(f"{k} & {v:.3f}" for k, v in enumerate(g["y"])) + ROW_END,
        "HoltOutBand": f"{f['holt_outside_band_pct']:.0f}",
        "HoltOutFifteen": f"{f['holt_outside_015_pct']:.0f}",
        "PlateauN": f["plateau_samples"],
        "FcLap": f["fc_lap"].replace("lap", "Runde "),
        "FcT": f"{f['fc_t']:.0f}", "FcLevel": f"{f['fc_level']:.2f}",
        "FcTrend": f"{f['fc_trend']:.3f}", "FcPred": f"{f['fc_pred']:.2f}",
        "FcActual": f"{f['fc_actual']:.2f}",
        "FcErr": f"{f['fc_actual'] - f['fc_pred']:.2f}",
        "FcRmseAll": f"{f['fc_rmse_all']:.2f}", "FcRmseNaive": f"{f['fc_rmse_naive']:.2f}",
        "SciStart": f"{f['sci_lap02']['start']:.1f}", "SciEnd": f"{f['sci_lap02']['end']:.1f}",
        "SciDur": f"{f['sci_lap02']['dur']:.0f}",
        "SciDrop": f"{f['sci_lap02']['start'] - f['sci_lap02']['end']:.1f}",
        "SciRatio": f"{f['sci_lap02']['end'] / f['sci_lap02']['start']:.2f}",
        "SciRate": f"{(f['sci_lap02']['end'] - f['sci_lap02']['start']) / f['sci_lap02']['dur']:.3f}",
        "StepsRows": ROW_SEP.join(
            f"{i + 1} & {s['dur']:.0f} & {s['start']:.1f} & {s['end']:.1f} & {s['drop']:.1f} "
            f"& {s['ratio']:.2f} & {s['rate']:.3f} & {s['steady']:.0f}"
            for i, s in enumerate(f["steps"])) + ROW_END,
        "SynOneSteady": f"{f['syn_work1_steady_pct']:.0f}",
        "SynOneOnkin": f"{f['syn_work1_onkin_pct']:.0f}",
        "SynThreeSteady": f"{f['syn_work3_steady_pct']:.0f}",
        "SynThreeOnkin": f"{f['syn_work3_onkin_pct']:.0f}",
    }
    for st, v in f["fc_rmse_by_state"].items():
        m["FcRmse" + st.title()] = f"{v:.2f}"
    for d, (short, runs) in f["dwell"].items():
        word = {"1": "One", "2": "Two", "3": "Three", "4": "Four"}[str(d)]
        m["Dwell" + word] = short
        m["Runs" + word] = runs
    with open(os.path.join(HERE, "numbers.tex"), "w") as fh:
        fh.write("% generated by figures.py, do not edit\n")
        for k, v in m.items():
            fh.write(f"\\newcommand{{\\n{k}}}{{{v}}}\n")


if __name__ == "__main__":
    main(sys.argv[1])
