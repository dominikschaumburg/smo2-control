#!/usr/bin/env python3
"""Offline replay of the SmO2 kinetics model.

This is a faithful port of source/Kinetics.mc. Tuning alpha, beta, theta_stable
and theta_drift on the watch is slow and imprecise; tuning them here against
your own recorded intervals takes seconds, and the numbers transfer directly
into the app settings.

Usage
-----
  # sanity check the model against a synthetic interval session
  ./kinetics_replay.py --synthetic

  # replay real activities — .fit straight off the watch, or .csv
  ./kinetics_replay.py activity.fit
  ./kinetics_replay.py *.fit                 # several sessions at once
  ./kinetics_replay.py session.csv --time-col timestamp --smo2-col smo2

  # sweep alpha/beta and report which pair tracks the signal most tightly
  ./kinetics_replay.py activity.fit --sweep

FIT input
---------
Reads SmO2 from the native record fields the watch writes when the Moxy is
paired as a native sensor. If the file instead only has this data field's own
developer fields, pass --dev-field smo2 — but note those are already smoothed,
so the alpha/beta you derive from them will be too weak.

Lap boundaries in the FIT are used to break the report down per interval, which
is where the tuning actually happens: you want your sustainable intervals to
show real STEADY time and your hard ones not to.

Settings mapping
----------------
  alpha        -> smoothingAlpha100  (alpha * 100)
  beta         -> smoothingBeta100   (beta * 100)
  theta_stable -> thetaStable1000    (theta * 1000)
  theta_drift  -> thetaDrift1000     (theta * 1000)
  steady_window-> steadyWindowSec

What to look for
----------------
The model is working when sustainable intervals spend a real share of their
time in STEADY while unsustainable ones essentially never reach it. On the
synthetic session (2 sustainable + 2 unsustainable intervals) the defaults give
roughly STEADY 40 % vs STEADY 2 %. If your own intervals do not separate that
way, adjust theta_stable first — it is the boundary that decides "plateau".
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import random
import sys
from dataclasses import dataclass, field
from typing import Iterable, Iterator

STATE_UNKNOWN, STATE_REOXY, STATE_STEADY, STATE_CONTROL, STATE_OVERSHOOT, STATE_ONKIN = range(6)

STATE_NAMES = {
    STATE_UNKNOWN: "UNKNOWN",
    STATE_REOXY: "REOXY",
    STATE_STEADY: "STEADY",
    STATE_CONTROL: "CONTROL",
    STATE_OVERSHOOT: "OVER",
    STATE_ONKIN: "ON-KIN",
}

STATE_GLYPH = {
    STATE_UNKNOWN: ".",
    STATE_REOXY: "^",
    STATE_STEADY: "=",
    STATE_CONTROL: "v",
    STATE_OVERSHOOT: "V",
    STATE_ONKIN: "!",
}

HYSTERESIS = 0.15
DT_MIN = 0.2
DT_MAX = 5.0


class SlopeWindow:
    """Rolling least-squares slope over a fixed window of smoothed values."""

    def __init__(self, window_sec: int = 60):
        self.size = max(5, window_sec)
        self.buf: list[tuple[float, float]] = []

    def clear(self) -> None:
        self.buf.clear()

    def push(self, value: float, t: float) -> None:
        self.buf.append((t, value))
        if len(self.buf) > self.size:
            self.buf.pop(0)

    def ready(self) -> bool:
        return len(self.buf) >= self.size // 3

    def slope(self) -> float:
        n = len(self.buf)
        if n < 3:
            return 0.0
        sy = sum(v for _, v in self.buf)
        sxy = sum(i * v for i, (_, v) in enumerate(self.buf))
        sx = n * (n - 1) / 2
        sxx = (n - 1) * n * (2 * n - 1) / 6
        den = n * sxx - sx * sx
        if den == 0:
            return 0.0
        per_sample = (n * sxy - sx * sy) / den
        span = self.buf[-1][0] - self.buf[0][0]
        return per_sample * (n - 1) / span if span > 0 else per_sample


@dataclass
class Kinetics:
    """Two-timescale model: fast Holt trend + slow regression slope.

    The Holt trend reacts in seconds and drives the forecast. The regression
    slope over `steady_window` seconds is what the state classification uses,
    because plateau-vs-drift is decided at 0.02-0.05 %/s, well under the noise
    floor of a reactive Holt trend.
    """

    alpha: float = 0.30
    beta: float = 0.15
    theta_stable: float = 0.06
    theta_drift: float = 0.15
    predict_horizon: float = 15.0
    steady_window: int = 60

    level: float | None = None
    trend: float = 0.0
    slow_slope: float = 0.0
    state: int = STATE_UNKNOWN
    _last_t: float = 0.0
    _win: SlopeWindow = field(default_factory=SlopeWindow)
    _window_dirty: bool = False
    peak_transient: float = 0.0

    def __post_init__(self):
        self._win = SlopeWindow(self.steady_window)

    def update(self, t: float, raw: float) -> None:
        if self.level is None or (t - self._last_t) > DT_MAX:
            # Cold start, or a gap long enough that extrapolating across it
            # would invent a slope that never happened.
            self.level, self.trend, self._last_t = raw, 0.0, t
            self.state = STATE_UNKNOWN
            self._win.clear()
            self._win.push(raw, t)
            return

        dt = t - self._last_t
        if dt < DT_MIN:
            return

        prev = self.level
        forecast = prev + self.trend * dt
        level = self.alpha * raw + (1.0 - self.alpha) * forecast
        slope = (level - prev) / dt
        self.trend = self.beta * slope + (1.0 - self.beta) * self.trend
        self.level = level
        self._last_t = t

        # Everything below is decided from the regression slope, never from
        # self.trend. On real Moxy data the fast Holt trend swings past
        # 0.15 %/s on half of all samples even inside a rock-solid plateau, so
        # no threshold on it can separate anything.
        self._win.push(level, t)
        self.slow_slope = self._win.slope()

        if not self._win.ready():
            self.state = STATE_ONKIN     # just restarted; we do not know yet
            return

        st = self._classify(self.slow_slope)

        # Rapid desaturation at interval start is the on-transient, not a
        # verdict about sustainability: sustainable and unsustainable intervals
        # both begin with a steep fall. Judging the fall itself as "overshoot"
        # marks every hard interval red for its first minute.
        if st == STATE_ONKIN:
            self.peak_transient = min(self.peak_transient, self.slow_slope)
            self._window_dirty = True
        elif self._window_dirty:
            # The fall is over: refit from post-transient data only.
            self._window_dirty = False
            self._win.clear()
            self._win.push(level, t)
            self.state = STATE_ONKIN
            return

        self.state = st

    def _classify(self, slope: float) -> int:
        stable, drift = self.theta_stable, self.theta_drift
        on_kin = self.theta_drift * 2.0
        if self.state == STATE_STEADY:
            stable *= 1.0 + HYSTERESIS
        elif self.state == STATE_CONTROL:
            stable *= 1.0 - HYSTERESIS
            drift *= 1.0 + HYSTERESIS
        elif self.state == STATE_OVERSHOOT:
            drift *= 1.0 - HYSTERESIS
            on_kin *= 1.0 + HYSTERESIS
        elif self.state == STATE_ONKIN:
            on_kin *= 1.0 - HYSTERESIS

        if slope > stable:
            return STATE_REOXY
        if slope >= -stable:
            return STATE_STEADY
        if slope >= -drift:
            return STATE_CONTROL
        if slope >= -on_kin:
            return STATE_OVERSHOOT
        return STATE_ONKIN

    def state_for_slope(self, slope: float) -> int:
        """Classify with no hysteresis — for colouring a finished shape, where
        a segment's colour must depend on what it is, not on what preceded it.
        Mirrors Kinetics.stateForSlope()."""
        if slope > self.theta_stable:
            return STATE_REOXY
        if slope >= -self.theta_stable:
            return STATE_STEADY
        if slope >= -self.theta_drift:
            return STATE_CONTROL
        if slope >= -self.theta_drift * 2.0:
            return STATE_OVERSHOOT
        return STATE_ONKIN

    def prediction(self) -> float | None:
        if self.level is None or self.predict_horizon <= 0:
            return None
        return min(100.0, max(0.0, self.level + self.trend * self.predict_horizon))

    def sci(self, session_range: float) -> float:
        if self.level is None or session_range < 1.0:
            return 0.0
        return abs(self.slow_slope) / session_range


@dataclass
class SessionRange:
    """Session min/max with the same slow relaxation as the watch."""

    relax_rate: float = 0.02
    deadband: float = 3.0
    min_range: float = 5.0
    lo: float | None = None
    hi: float | None = None
    _last_t: float | None = None

    def update(self, t: float, level: float) -> None:
        self.lo = level if self.lo is None else min(self.lo, level)
        self.hi = level if self.hi is None else max(self.hi, level)
        if self._last_t is not None:
            dt = t - self._last_t
            if 0 < dt <= 10.0:
                step = self.relax_rate * dt
                if level - self.lo > self.deadband:
                    self.lo = min(self.lo + step, level)
                if self.hi - level > self.deadband:
                    self.hi = max(self.hi - step, level)
        self._last_t = t

    def range(self) -> float:
        if self.lo is None or self.hi is None:
            return self.min_range
        return max(self.min_range, self.hi - self.lo)


# --------------------------------------------------------------------------
# Data sources
# --------------------------------------------------------------------------


def read_csv(path: str, time_col: str, smo2_col: str) -> list[tuple[float, float]]:
    rows: list[tuple[float, float]] = []
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise SystemExit(f"{path}: no header row")
        for col in (time_col, smo2_col):
            if col not in reader.fieldnames:
                raise SystemExit(
                    f"{path}: column {col!r} not found. "
                    f"Available: {', '.join(reader.fieldnames)}"
                )
        t0 = None
        for row in reader:
            try:
                t = float(row[time_col])
                v = float(row[smo2_col])
            except (TypeError, ValueError):
                continue  # blank or non-numeric sample
            if not 0.0 <= v <= 100.0:
                continue  # invalid / ambient marker
            if t0 is None:
                t0 = t
            rows.append((t - t0, v))
    if not rows:
        raise SystemExit(f"{path}: no usable samples")
    return rows


def read_fit(path: str, dev_field: str | None):
    """Return (samples, labels) from a FIT activity, labelled by lap."""
    import fitreader

    data = fitreader.decode(path)
    samples = data.smo2_series(prefer=dev_field)
    if not samples:
        avail = ", ".join(data.available_fields()) or "none"
        raise SystemExit(
            f"{path}: no SmO2 samples found.\n"
            f"  Fields present: {avail}\n"
            f"  If this session recorded SmO2 under a developer field, "
            f"pass --dev-field <name>."
        )

    # smo2_series() rebases time to the first usable sample; rebase the laps the
    # same way so the labels line up.
    key = dev_field or data.find_smo2_field()
    t0 = None
    for r in data.records:
        if r.get("t") is not None and r.get(key) is not None:
            t0 = r["t"]
            break
    labels = None
    if data.laps and t0 is not None:
        bounds = [(s - t0, e - t0) for s, e in data.laps]
        labels = []
        for t, _ in samples:
            lab = "pre"
            for i, (ls, le) in enumerate(bounds, start=1):
                if ls <= t <= le:
                    lab = f"lap{i:02d}"
                    break
            labels.append(lab)
    return samples, labels


def load(path: str, args) -> tuple[list[tuple[float, float]], list[str] | None]:
    if path.lower().endswith(".fit"):
        return read_fit(path, args.dev_field)
    return read_csv(path, args.time_col, args.smo2_col), None


def synthetic(seed: int = 7) -> Iterator[tuple[float, float, str]]:
    """A 4 x (3 min work / 2 min rest) session with a known ground truth.

    Interval 1-2 are sustainable: fast on-kinetics into a genuine plateau.
    Interval 3-4 are over the sustainable point: the plateau never arrives and
    SmO2 keeps sliding. A correct model must call the first two STEADY once the
    plateau is reached, and keep the last two in CONTROL/OVER.

    The drift rates and the noise level are set to match what real Moxy data
    actually does — an earlier version of this generator was far too clean, and
    thresholds tuned against it were an order of magnitude too tight to survive
    contact with a real session.
    """
    rng = random.Random(seed)
    baseline = 68.0
    smo2 = baseline
    t = 0.0

    def emit(target: float, tau: float, duration: float, label: str):
        nonlocal smo2, t
        for _ in range(int(duration)):
            smo2 += (target - smo2) / tau
            noise = rng.gauss(0.0, 0.6)
            yield t, max(0.0, min(100.0, smo2 + noise)), label
            t += 1.0

    yield from emit(baseline, 30.0, 60, "rest")
    for i, (plateau, drift) in enumerate(
        [(42.0, 0.0), (40.0, 0.0), (38.0, -16.0), (36.0, -24.0)], start=1
    ):
        # Work: exponential fall to the plateau, plus a linear drift term for
        # the unsustainable intervals.
        for k in range(180):
            target = plateau + drift * (k / 180.0)
            smo2 += (target - smo2) / 18.0
            yield t, max(0.0, min(100.0, smo2 + rng.gauss(0.0, 0.6))), f"work{i}"
            t += 1.0
        # Recovery with reactive-hyperaemia overshoot above baseline.
        yield from emit(baseline + 6.0, 22.0, 120, f"rest{i}")


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def run(samples: Iterable[tuple[float, float]], k: Kinetics, rng: SessionRange):
    out = []
    for t, raw in samples:
        k.update(t, raw)
        if k.level is not None:
            rng.update(t, k.level)
        out.append((t, raw, k.level, k.slow_slope, k.state, k.sci(rng.range())))
    return out


def report(rows, labels: list[str] | None, k: Kinetics, rng: SessionRange) -> None:
    print(f"samples            {len(rows)}")
    print(f"alpha / beta       {k.alpha:.2f} / {k.beta:.2f}")
    print(f"steady window      {k.steady_window} s")
    print(f"theta stable/drift {k.theta_stable:.3f} / {k.theta_drift:.3f} %/s")
    if rng.lo is not None and rng.hi is not None:
        print(f"session range      {rng.lo:.1f} – {rng.hi:.1f} % ({rng.range():.1f} %)")

    # Residual: how tightly the smoothed level tracks the raw signal.
    resid = [(r[1] - r[2]) ** 2 for r in rows if r[2] is not None]
    if resid:
        print(f"rms residual       {math.sqrt(sum(resid) / len(resid)):.3f} %")

    counts: dict[int, int] = {}
    for r in rows:
        counts[r[4]] = counts.get(r[4], 0) + 1
    total = len(rows)
    print("\nstate distribution")
    for st in (STATE_UNKNOWN, STATE_REOXY, STATE_STEADY, STATE_ONKIN,
               STATE_CONTROL, STATE_OVERSHOOT):
        n = counts.get(st, 0)
        if n:
            print(f"  {STATE_NAMES[st]:<8} {n:5d}  {100 * n / total:5.1f} %")

    if labels:
        print("\nstate distribution per phase")
        per: dict[str, dict[int, int]] = {}
        for r, lab in zip(rows, labels):
            per.setdefault(lab, {})
            per[lab][r[4]] = per[lab].get(r[4], 0) + 1
        for lab in sorted(per, key=lambda s: (s.rstrip("0123456789"), s)):
            n = sum(per[lab].values())
            parts = [
                f"{STATE_NAMES[s]} {100 * c / n:.0f}%"
                for s, c in sorted(per[lab].items(), key=lambda kv: -kv[1])
            ]
            print(f"  {lab:<8} {'  '.join(parts)}")

    # Compressed timeline, one glyph per 5 s.
    print("\ntimeline (1 char = 5 s)")
    line = "".join(STATE_GLYPH[r[4]] for r in rows[::5])
    for i in range(0, len(line), 100):
        print(f"  {i * 5:5d}s {line[i:i + 100]}")
    print("  legend: ^ reoxy  = steady  ! on-kinetics  v control  V over  . unknown")


def lap_table(rows, labels: list[str]) -> None:
    """Kane's per-interval desaturation rate, computed the way the watch does."""
    order: list[str] = []
    groups: dict[str, list] = {}
    for r, lab in zip(rows, labels):
        if lab not in groups:
            groups[lab] = []
            order.append(lab)
        groups[lab].append(r)

    print("\n per-interval summary")
    print(f"  {'lap':<8} {'dur':>5} {'start':>6} {'end':>6} {'rate':>8} "
          f"{'onkin':>8} {'min':>6} {'max':>6}  verdict")
    for lab in order:
        g = [r for r in groups[lab] if r[2] is not None]
        if len(g) < 5:
            continue
        dur = g[-1][0] - g[0][0]
        if dur <= 0:
            continue
        start, end = g[0][2], g[-1][2]
        rate = (end - start) / dur
        vals = [r[2] for r in g]
        steady = sum(1 for r in g if r[4] == STATE_STEADY) / len(g)
        onkin = sum(1 for r in g if r[4] == STATE_ONKIN) / len(g)
        reoxy = sum(1 for r in g if r[4] == STATE_REOXY) / len(g)
        # A plateau that is actually reached is the signature of a sustainable
        # effort; an interval that never leaves the transient is not.
        if reoxy >= 0.5:
            verdict = f"recovery (reoxy {100 * reoxy:.0f}%)"
        elif steady >= 0.25:
            verdict = f"sustainable (steady {100 * steady:.0f}%)"
        elif onkin >= 0.5:
            verdict = f"never plateaued (on-kin {100 * onkin:.0f}%)"
        else:
            verdict = f"drifting (steady {100 * steady:.0f}%)"
        onkin_slopes = [r[3] for r in g if r[4] == STATE_ONKIN]
        peak = min(onkin_slopes) if onkin_slopes else 0.0
        print(f"  {lab:<8} {dur:5.0f} {start:6.1f} {end:6.1f} {rate:+8.3f} "
              f"{peak:+8.3f} {min(vals):6.1f} {max(vals):6.1f}  {verdict}")
    print("  rate  = (end - start) / duration, in %/s")
    print("  onkin = steepest slope during the on-transient, in %/s "
          "(tracks metabolic rate)")


def sweep(samples: list[tuple[float, float]], base: Kinetics) -> None:
    print(f"{'alpha':>6} {'beta':>6} {'rms':>8} {'lag':>8}  state mix")
    for alpha in (0.15, 0.20, 0.25, 0.30, 0.35, 0.45):
        for beta in (0.05, 0.10, 0.15, 0.20, 0.30):
            k = Kinetics(alpha, beta, base.theta_stable, base.theta_drift,
                         steady_window=base.steady_window)
            rows = run(samples, k, SessionRange())
            resid = [(r[1] - r[2]) ** 2 for r in rows if r[2] is not None]
            rms = math.sqrt(sum(resid) / len(resid)) if resid else float("nan")
            # Lag proxy: mean absolute smoothed-vs-raw offset during the fast
            # transitions, where over-smoothing hurts most.
            fast = [abs(r[1] - r[2]) for r in rows if r[2] is not None and abs(r[3]) > 0.2]
            lag = sum(fast) / len(fast) if fast else 0.0
            counts: dict[int, int] = {}
            for r in rows:
                counts[r[4]] = counts.get(r[4], 0) + 1
            mix = " ".join(
                f"{STATE_NAMES[s][:4]}{100 * counts.get(s, 0) // len(rows)}"
                for s in (STATE_REOXY, STATE_STEADY, STATE_ONKIN, STATE_CONTROL,
                          STATE_OVERSHOOT)
            )
            print(f"{alpha:6.2f} {beta:6.2f} {rms:8.3f} {lag:8.3f}  {mix}")
    print("\nrms = tracking error (lower = follows the signal), "
          "lag = error during fast transitions.")
    print("Pick the smallest alpha whose lag you can still live with: "
          "higher alpha reacts sooner but jitters more.")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("inputs", nargs="*", help=".fit activities and/or .csv exports")
    p.add_argument("--synthetic", action="store_true",
                   help="use a generated interval session instead of a CSV")
    p.add_argument("--time-col", default="time", help="time column name (seconds)")
    p.add_argument("--smo2-col", default="smo2", help="SmO2 column name (percent)")
    p.add_argument("--dev-field", default=None,
                   help="read SmO2 from this FIT developer field instead of the "
                        "native one (already-smoothed data)")
    p.add_argument("--alpha", type=float, default=0.30)
    p.add_argument("--beta", type=float, default=0.15)
    p.add_argument("--theta-stable", type=float, default=0.06)
    p.add_argument("--theta-drift", type=float, default=0.15)
    p.add_argument("--steady-window", type=int, default=60)
    p.add_argument("--sweep", action="store_true",
                   help="grid search alpha/beta instead of a single run")
    args = p.parse_args(argv)

    if args.synthetic:
        gen = list(synthetic())
        sources = [("synthetic", [(t, v) for t, v, _ in gen],
                    [lab for _, _, lab in gen])]
    elif args.inputs:
        sources = []
        for path in args.inputs:
            samples, labels = load(path, args)
            sources.append((os.path.basename(path), samples, labels))
    else:
        p.error("give one or more .fit/.csv files, or --synthetic")

    for i, (name, samples, labels) in enumerate(sources):
        if len(sources) > 1 or not args.synthetic:
            if i:
                print()
            print("=" * 70)
            print(name)
            print("=" * 70)

        base = Kinetics(args.alpha, args.beta, args.theta_stable, args.theta_drift,
                        steady_window=args.steady_window)
        if args.sweep:
            sweep(samples, base)
            continue

        rng = SessionRange()
        rows = run(samples, base, rng)
        report(rows, labels, base, rng)
        if labels:
            lap_table(rows, labels)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
