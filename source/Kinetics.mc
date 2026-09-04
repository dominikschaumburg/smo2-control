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
//   Holt trend (~5–15 s)   -> displayed rate, forecast, SCI
//   Regression slope (60 s)-> the steady / drift / overshoot classification
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

        if (_level == null) {
            // Cold start: seed the level, leave the trend at zero.
            _level = raw;
            _trend = 0.0;
            _lastMs = now;
            _state = STATE_UNKNOWN;
            _window.clear();
            _window.push(raw, now / 1000.0);
            return;
        }

        var dt = (now - _lastMs) / 1000.0;
        if (dt < DT_MIN) {
            return;                       // too soon, nothing new to learn
        }
        if (dt > DT_MAX) {
            // Long gap: resync the level, drop the stale trend rather than
            // extrapolating across the hole. The regression window assumes a
            // roughly even time grid, so it starts over too.
            _level = raw;
            _trend = 0.0;
            _lastMs = now;
            _state = STATE_UNKNOWN;
            _window.clear();
            _window.push(raw, now / 1000.0);
            return;
        }

        var prevLevel = _level as Float;
        // Forecast forward by the *measured* dt, then correct with the sample.
        var forecast = prevLevel + _trend * dt;
        var level = _alpha * raw + (1.0 - _alpha) * forecast;
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
            _state = STATE_ONKIN;
            return;
        }

        var st = classify(_slowSlope);

        // Rapid desaturation at the start of an interval is the on-transient,
        // not a verdict about sustainability. Both a sustainable and an
        // unsustainable interval begin with a steep fall; what separates them
        // is what happens *after* it. Judging the fall itself as "overshoot"
        // marks every hard interval red for its first minute.
        if (st == STATE_ONKIN) {
            if (_slowSlope < _peakTransient) {
                _peakTransient = _slowSlope;
            }
            _windowDirty = true;
        } else if (_windowDirty) {
            // The fall is over. Restart the fit so the plateau question is
            // answered from post-transient data only, and say ON-KIN until
            // there is enough of it to answer with.
            _windowDirty = false;
            _window.clear();
            _window.push(level, now / 1000.0);
            _state = STATE_ONKIN;
            return;
        }

        _state = st;
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
        _peakTransient = 0.0;
        _state = STATE_UNKNOWN;
    }

    //! Freeze the filter while the sensor is stale, so a frozen reading is not
    //! mistaken for a genuine "slope = 0" steady state.
    public function pause() as Void {
        _lastMs = System.getTimer();
        _state = STATE_UNKNOWN;
        // A dropout leaves a hole in the time grid; refitting across it would
        // invent a slope that never happened.
        _window.clear();
    }

    //! Drop all filter state (timer reset, sensor re-placed).
    public function reset() as Void {
        _level = null;
        _trend = 0.0;
        _slowSlope = 0.0;
        _peakTransient = 0.0;
        _windowDirty = false;
        _state = STATE_UNKNOWN;
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

    //! SmO2 Control Index: slope magnitude normalised by the session's own
    //! SmO2 range, so it is comparable across sessions and sensor placements.
    //! @param range Session SmO2 range in %
    public function getSCI(range as Float) as Float {
        if (_level == null || range < 1.0) {
            return 0.0;
        }
        var s = _slowSlope;
        if (s < 0.0) { s = -s; }
        return s / range;
    }
}
