//
// Kinetics.mc — two-timescale analysis of the SmO2 signal.
//
// Raw Moxy data at ~0.5–2 Hz is far too noisy to differentiate directly. Holt
// double-exponential smoothing gives us the level and an instantaneous trend
// from one O(1) recursion, so the displayed slope (%/s) and the h-second
// forecast both fall out of the same model.
//
// But the Holt trend alone cannot answer the question this field exists for.
// On real Moxy data it swings past 0.15 %/s on half of all samples even inside
// a rock-solid plateau — the signal genuinely moves that fast, so this is not a
// smoothing problem and no threshold on it separates anything. Slowing Holt
// down to compensate does not help either: a trend slow enough to resolve the
// drift never settles within an interval, because its infinite tail keeps
// carrying the on-transient forward.
//
// So there are two estimators on two timescales, which is what the kinetics
// actually demand:
//
//   Holt trend (~5–15 s)   -> forecast needle
//   Regression slope (60 s)-> the classification, and the displayed rate
//
// The regression window is a plain least-squares fit over the smoothed level.
// It costs one pass of ~60 multiply-adds per second, which is nothing, and it
// is dramatically more noise-resistant than any O(1) recursion at this
// timescale.
//
// 60 s is measured, not guessed. Across five real threshold sessions a shorter
// window leaves the plateau band so loose (+/-0.08 %/s at 45 s) that genuine
// drift disappears inside it; a longer one dilutes the on-transient into the
// recovery that preceded it and stops detecting it at all. Validate any change
// with tools/kinetics_replay.py against real .fit files, not just --synthetic.
//
// Both estimators carry their slope in %/s rather than %/update, because
// compute() is not guaranteed to fire at exactly 1 Hz and the Moxy's own update
// rate drifts. Every recursion therefore uses the measured dt.
//
// Three defences against outliers, at three different points, because they
// catch three different things:
//
//   1. A 3-sample MEDIAN before the smoother. A Moxy's characteristic fault is
//      an isolated sample that jumps and comes straight back; an average
//      carries a third of that jump into the level, a median of three ignores
//      it completely. Costs one sample of lag, which against a 60 s window is
//      nothing.
//   2. Short DROPOUTS keep the fit. A single invalid or ambient-light reading
//      used to clear the whole regression window, so one bad second cost the
//      full window plus the 20 s refill: about 80 s of "not decided yet" for a
//      one-second fault. The window timestamps its samples and rescales by the
//      real span, so a hole of a few seconds costs accuracy, not validity.
//   3. A DWELL on the verdict. A new state has to hold for a few consecutive
//      updates before it is shown. Hysteresis already widens the band you are
//      in; this adds time to it, which is what catches a slope that steps over
//      a threshold and back.
//
// All three are deliberately outside the classifier: the thresholds keep their
// measured meaning and the chart's own colouring, which must describe a static
// shape rather than a live opinion, stays untouched by any of it.
//

import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! Rolling least-squares slope over a fixed-length window of smoothed values.
class SlopeWindow {
    private var _buf as Array<Float>;
    private var _t as Array<Float>;      // seconds, for the real time span
    private var _size as Number;
    private var _head as Number = 0;
    private var _count as Number = 0;

    public function initialize(windowSec as Number) {
        _size = (windowSec < 5) ? 5 : windowSec;
        _buf = new Array<Float>[_size];
        _t = new Array<Float>[_size];
    }

    public function clear() as Void {
        _head = 0;
        _count = 0;
    }

    public function push(value as Float, tSec as Float) as Void {
        _buf[_head] = value;
        _t[_head] = tSec;
        _head = (_head + 1) % _size;
        if (_count < _size) { _count++; }
    }

    public function isReady() as Boolean {
        // Below about a third of the window the fit is too loose to trust.
        return _count >= _size / 3;
    }

    //! Least-squares slope in %/s, or 0.0 while the window is too empty.
    public function slope() as Float {
        var n = _count;
        if (n < 3) { return 0.0; }

        var oldest = (_count < _size) ? 0 : _head;
        // Fit against the sample index, then rescale by the window's real
        // duration so a jittery sample rate does not bias the slope.
        var sy = 0.0;
        var sxy = 0.0;
        for (var i = 0; i < n; i++) {
            var y = _buf[(oldest + i) % _size];
            sy += y;
            sxy += i * y;
        }
        var nf = n.toFloat();
        var sx = nf * (nf - 1.0) / 2.0;
        var sxx = (nf - 1.0) * nf * (2.0 * nf - 1.0) / 6.0;
        var den = nf * sxx - sx * sx;
        if (den == 0.0) { return 0.0; }
        var perSample = (nf * sxy - sx * sy) / den;

        var span = _t[(oldest + n - 1) % _size] - _t[oldest];
        if (span <= 0.0) { return perSample; }
        return perSample * (nf - 1.0) / span;
    }
}

//! Four-state classification of the SmO2 slope. Drives the colour coding.
enum SmO2State {
    STATE_UNKNOWN  = 0,   // no valid data
    STATE_REOXY    = 1,   // rising: recovery / too easy
    STATE_STEADY   = 2,   // flat: supply matches demand, sustainable
    STATE_CONTROL  = 3,   // slow decline: hard but controlled
    STATE_OVERSHOOT= 4,   // slow decline continuing: past the sustainable point
    STATE_ONKIN    = 5    // rapid desaturation: the on-transient
}

class Kinetics {
    private var _alpha as Float;
    private var _beta as Float;
    private var _thetaStable as Float;   // %/s
    private var _thetaDrift as Float;    // %/s
    private var _predictHorizon as Number;
    private var _steadyWindowSec as Number = 0;

    private var _level as Float? = null;      // L_t
    private var _trend as Float = 0.0;        // T_t in %/s, fast timescale
    private var _lastMs as Number = 0;
    private var _state as SmO2State = STATE_UNKNOWN;

    private var _window as SlopeWindow;       // slow timescale, drives _state
    private var _slowSlope as Float = 0.0;

    // On-transient tracking. The steady-state verdict must not be computed from
    // data that includes the initial fall, so the window is restarted once the
    // transient is over and _windowDirty says whether that is still pending.
    private var _windowDirty as Boolean = false;
    private var _peakTransient as Float = 0.0;

    // Hysteresis band around the thresholds, so the colour doesn't flicker
    // when the slope sits exactly on a boundary.
    private const HYSTERESIS = 0.15;   // ±15 % of the threshold

    // Ignore absurd dt values (paused activity, watch sleep) — a 40 s gap would
    // otherwise produce a meaningless slope.
    private const DT_MIN = 0.2;
    private const DT_MAX = 5.0;

    // How long a hole in the data may be before the fit is abandoned rather
    // than continued across it. Eight seconds is three past the sensor's own
    // stale timeout, so anything the sensor still calls TRACKING is always
    // survivable, and a 8 s hole leaves the 60 s window 87 % full.
    private const GAP_MAX_MS = 8000;

    // Consecutive updates a new verdict must hold before it is shown.
    //
    // Measured over three real sessions, counting state runs shorter than 5 s
    // as flicker: 28 / 14 / 26 of them with no dwell, 13 / 10 / 13 at three,
    // 8 / 5 / 6 at four. Four is tempting and is not taken. It costs the
    // short recovery laps: in one session a 59 s recovery drops from 72 % to
    // 50 % REOXY, which lands exactly on the documented lower bound, because
    // every re-entry into a state pays the dwell again and a short lap has
    // few seconds to spare. Three takes half the flicker for a couple of
    // points of REOXY.
    private const STATE_DWELL = 3;

    // Median prefilter. Three is the shortest window with a majority, so it
    // rejects one bad sample in three and adds one sample of lag.
    private const MEDIAN_N = 3;
    private var _med as Array<Float> = new Array<Float>[MEDIAN_N];
    private var _medCount as Number = 0;
    private var _medHead as Number = 0;

    // First tick of the current run of missing data, 0 when data is flowing.
    private var _staleSinceMs as Number = 0;

    // Candidate verdict waiting out its dwell.
    private var _candidate as SmO2State = STATE_UNKNOWN;
    private var _candidateN as Number = 0;

    // Consecutive updates the raw classification has said ON-KIN.
    private var _onkinN as Number = 0;

    public function initialize(alpha as Float, beta as Float,
                               thetaStable as Float, thetaDrift as Float,
                               predictHorizon as Number, steadyWindowSec as Number) {
        _alpha = alpha;
        _beta = beta;
        _thetaStable = thetaStable;
        _thetaDrift = thetaDrift;
        _predictHorizon = predictHorizon;
        _steadyWindowSec = steadyWindowSec;
        _window = new SlopeWindow(steadyWindowSec);
    }

    //! Apply changed app settings without losing the current filter state.
    public function setParams(alpha as Float, beta as Float,
                              thetaStable as Float, thetaDrift as Float,
                              predictHorizon as Number, steadyWindowSec as Number) as Void {
        _alpha = alpha;
        _beta = beta;
        _thetaStable = thetaStable;
        _thetaDrift = thetaDrift;
        _predictHorizon = predictHorizon;
        // Only reallocate when the window length actually changed; otherwise a
        // settings sync mid-interval would throw away the fit.
        if (steadyWindowSec != _steadyWindowSec) {
            _steadyWindowSec = steadyWindowSec;
            _window = new SlopeWindow(steadyWindowSec);
        }
    }

    //! Feed one valid sample. Call at most once per compute() tick.
    //! @param raw Valid SmO2 reading in %
    public function update(raw as Float) as Void {
        var now = System.getTimer();
        var value = median(raw);
        _staleSinceMs = 0;

        if (_level == null) {
            // Cold start: seed the level, leave the trend at zero.
            _level = value;
            _trend = 0.0;
            _lastMs = now;
            force(STATE_UNKNOWN);
            _window.clear();
            _window.push(value, now / 1000.0);
            return;
        }

        var dt = (now - _lastMs) / 1000.0;
        if (dt < DT_MIN) {
            return;                       // too soon, nothing new to learn
        }
        if (dt > DT_MAX) {
            // A hole in the data. Resync the level and drop the fast trend
            // rather than extrapolating Holt across it, but keep the
            // regression window unless the hole is long: the window carries
            // its own timestamps and rescales by the real span, so a few
            // missing seconds cost accuracy where starting over costs the
            // whole minute of evidence.
            _level = value;
            _trend = 0.0;
            _lastMs = now;
            if (dt * 1000.0 > GAP_MAX_MS) {
                force(STATE_UNKNOWN);
                _window.clear();
            }
            _window.push(value, now / 1000.0);
            return;
        }

        var prevLevel = _level as Float;
        // Forecast forward by the *measured* dt, then correct with the sample.
        var forecast = prevLevel + _trend * dt;
        var level = _alpha * value + (1.0 - _alpha) * forecast;
        var slope = (level - prevLevel) / dt;
        _trend = _beta * slope + (1.0 - _beta) * _trend;

        _level = level;
        _lastMs = now;

        // Everything below is decided from the regression slope, never from
        // _trend. On real Moxy data the fast Holt trend swings past 0.15 %/s on
        // half of all samples even inside a rock-solid plateau — the signal
        // genuinely moves that fast, so it is not a smoothing problem and no
        // threshold on it can separate anything.
        _window.push(level, now / 1000.0);
        _slowSlope = _window.slope();

        if (!_window.isReady()) {
            // Just after a restart we honestly do not know yet.
            force(STATE_ONKIN);
            return;
        }

        var st = classify(_slowSlope);

        // Rapid desaturation at the start of an interval is the on-transient,
        // not a verdict about sustainability. Both a sustainable and an
        // unsustainable interval begin with a steep fall; what separates them
        // is what happens *after* it. Judging the fall itself as "overshoot"
        // marks every hard interval red for its first minute.
        //
        // This runs on the raw classification and keeps its own counter,
        // deliberately not on the settled state. Driving it from the settled
        // state deadlocks: the dwell holds ON-KIN for four ticks after the
        // fall has ended, those ticks re-arm the restart, the restart forces
        // ON-KIN again, and the field never leaves the transient. Measured as
        // 100 % ON-KIN across every synthetic interval.
        if (st == STATE_ONKIN) {
            if (_slowSlope < _peakTransient) {
                _peakTransient = _slowSlope;
            }
            _onkinN++;
            // Only a sustained steep fall counts as a transient worth
            // refitting from. A single tick is an outlier, and the restart is
            // the most expensive thing in the model: it costs the window plus
            // its refill.
            if (_onkinN >= STATE_DWELL) {
                _windowDirty = true;
            }
        } else {
            _onkinN = 0;
            if (_windowDirty) {
                // The fall is over. Restart the fit so the plateau question is
                // answered from post-transient data only, and say ON-KIN until
                // there is enough of it to answer with.
                _windowDirty = false;
                _window.clear();
                _window.push(level, now / 1000.0);
                force(STATE_ONKIN);
                return;
            }
        }

        _state = settle(st);
    }

    //! Median of the last MEDIAN_N raw readings. An isolated spike is a
    //! minority of three and disappears; a genuine step survives with one
    //! sample of delay.
    private function median(raw as Float) as Float {
        _med[_medHead] = raw;
        _medHead = (_medHead + 1) % MEDIAN_N;
        if (_medCount < MEDIAN_N) { _medCount++; }
        if (_medCount < MEDIAN_N) {
            return raw;                   // not enough yet to outvote anything
        }
        // Three elements: the median is the one that is neither the largest
        // nor the smallest, which is cheaper to write out than to sort.
        var a = _med[0];
        var b = _med[1];
        var c = _med[2];
        if (a > b) { var t = a; a = b; b = t; }
        if (b > c) { var t = b; b = c; c = t; }
        if (a > b) { var t = a; a = b; b = t; }
        return b;
    }

    //! Apply the dwell: return the verdict that should be shown, given the
    //! freshly classified one. A change has to be repeated STATE_DWELL times
    //! in a row before it takes effect.
    private function settle(st as SmO2State) as SmO2State {
        if (st == _state) {
            _candidateN = 0;
            return _state;
        }
        if (st == _candidate) {
            _candidateN++;
        } else {
            _candidate = st;
            _candidateN = 1;
        }
        if (_candidateN >= STATE_DWELL) {
            _candidateN = 0;
            return st;
        }
        return _state;
    }

    //! Set the state immediately, bypassing the dwell. For the events the
    //! model knows about rather than infers: a restart, a lap press, a gap.
    //! Waiting out a dwell on those would report a state that is known to be
    //! over.
    private function force(st as SmO2State) as Void {
        _state = st;
        _candidate = st;
        _candidateN = 0;
    }

    //! Slope steep enough to be an on-transient rather than a steady-state
    //! drift. Derived from thetaDrift rather than being its own setting, so
    //! tuning the drift threshold scales this with it.
    //!
    //! Measured across five threshold sessions: with a 60 s window the plateau
    //! slope stays inside +/-0.06 %/s for its middle 80 %, while the
    //! on-transient runs past -0.23 %/s. 2x thetaDrift lands between.
    private function onKinThreshold() as Float {
        return _thetaDrift * 2.0;
    }

    //! Steepest fast slope seen during the last transient, in %/s. Negative.
    //! The steepness of the on-kinetics correlates with metabolic rate, so this
    //! is the per-interval intensity marker worth recording.
    public function getPeakTransient() as Float {
        return _peakTransient;
    }

    //! Called at an interval boundary: a lap press means the load just changed,
    //! so the old fit describes a workload that no longer applies.
    public function onStepChange() as Void {
        _window.clear();
        _windowDirty = false;
        _onkinN = 0;
        _peakTransient = 0.0;
        force(STATE_UNKNOWN);
    }

    //! Freeze the filter while there is no valid reading, so a frozen value is
    //! not mistaken for a genuine "slope = 0" steady state.
    //!
    //! The last verdict and the regression window are held for GAP_MAX_MS.
    //! Invalid and ambient-light readings are usually one sample long, and
    //! clearing a 60 s fit for one of them cost the window plus its 20 s
    //! refill: about 80 s of "not decided yet" bought by a single bad second.
    //! Past the tolerance the fit really is unsound and is dropped.
    public function pause() as Void {
        var now = System.getTimer();
        if (_staleSinceMs == 0) {
            _staleSinceMs = now;
        }
        // Keep _lastMs current, so the sample that ends the gap is not also
        // treated as a long-dt event by update(); the window's own timestamps
        // already carry the real span.
        _lastMs = now;
        if (now - _staleSinceMs > GAP_MAX_MS) {
            force(STATE_UNKNOWN);
            _window.clear();
        }
    }

    //! Drop all filter state (timer reset, sensor re-placed).
    public function reset() as Void {
        _level = null;
        _trend = 0.0;
        _slowSlope = 0.0;
        _peakTransient = 0.0;
        _windowDirty = false;
        _onkinN = 0;
        _staleSinceMs = 0;
        _medCount = 0;
        _medHead = 0;
        force(STATE_UNKNOWN);
        _window.clear();
    }

    //! Classify the slope into one of the four states, with hysteresis applied
    //! against the state we are currently in.
    private function classify(slope as Float) as SmO2State {
        var stable = _thetaStable;
        var drift = _thetaDrift;
        var onKin = onKinThreshold();

        // Widen the band we are already inside; makes leaving a state harder
        // than staying in it.
        if (_state == STATE_STEADY) {
            stable = stable * (1.0 + HYSTERESIS);
        } else if (_state == STATE_CONTROL) {
            stable = stable * (1.0 - HYSTERESIS);
            drift = drift * (1.0 + HYSTERESIS);
        } else if (_state == STATE_OVERSHOOT) {
            drift = drift * (1.0 - HYSTERESIS);
            onKin = onKin * (1.0 + HYSTERESIS);
        } else if (_state == STATE_ONKIN) {
            onKin = onKin * (1.0 - HYSTERESIS);
        }

        if (slope > stable) { return STATE_REOXY; }
        if (slope >= -stable) { return STATE_STEADY; }
        if (slope >= -drift) { return STATE_CONTROL; }
        if (slope >= -onKin) { return STATE_OVERSHOOT; }
        return STATE_ONKIN;
    }

    public function getLevel() as Float? {
        return _level;
    }

    //! Fast Holt trend in %/s. Reacts within seconds, so it drives the
    //! short-horizon forecast — but it is too noisy to classify steady state.
    public function getTrend() as Float {
        return _trend;
    }

    //! Regression slope over the steady window, in %/s. This is the rate the
    //! state colour is based on, so it is also the rate worth displaying:
    //! a number that disagreed with the colour would just confuse.
    public function getSlowSlope() as Float {
        return _slowSlope;
    }

    public function getState() as SmO2State {
        return _state;
    }

    //! Classify a slope with no hysteresis and no reference to the live state.
    //! The chart uses this to colour a finished stretch of curve: hysteresis
    //! exists to stop the *live* verdict flickering, and applying it to a
    //! static shape would make a segment's colour depend on what came before
    //! it rather than on what it is.
    public function stateForSlope(slope as Float) as SmO2State {
        if (slope > _thetaStable) { return STATE_REOXY; }
        if (slope >= -_thetaStable) { return STATE_STEADY; }
        if (slope >= -_thetaDrift) { return STATE_CONTROL; }
        if (slope >= -onKinThreshold()) { return STATE_OVERSHOOT; }
        return STATE_ONKIN;
    }

    public function hasData() as Boolean {
        return _level != null;
    }

    //! Forecast SmO2 in `predictHorizon` seconds, or null when disabled.
    public function getPrediction() as Float? {
        if (_level == null || _predictHorizon <= 0) {
            return null;
        }
        var p = (_level as Float) + _trend * _predictHorizon;
        if (p < 0.0) { p = 0.0; }
        if (p > 100.0) { p = 100.0; }
        return p;
    }
}
