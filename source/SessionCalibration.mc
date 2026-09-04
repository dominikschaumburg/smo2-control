//
// SessionCalibration.mc — session-internal normalisation of the SmO2 signal.
//
// Absolute SmO2 is not comparable between sessions: it depends on sensor site,
// adipose tissue thickness, strap pressure, skin perfusion and day form. Within
// a single session it is very informative. So everything the field displays is
// referenced to a window that is calibrated live, not to a fixed 0–100 % scale.
//
// Three layers:
//   1. Baseline    — median of the first `baselineSec` seconds ("reference top")
//   2. Session min/max — tracked from smoothed values, slowly relaxing so a
//                        single artefact cannot distort the range for good
//   3. Lap calibration — the first lap is treated as a reference interval whose
//                        start/end anchor the working band
//

import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

class SessionCalibration {
    // Baseline collection is capped; longer windows are sub-sampled.
    private const BASELINE_MAX_SAMPLES = 120;

    // Extremes relax toward the current level at this rate (%/s) once they are
    // more than RELAX_DEADBAND away from it.
    private const RELAX_RATE = 0.02;
    private const RELAX_DEADBAND = 3.0;

    // A range narrower than this is not meaningful for normalisation.
    private const MIN_RANGE = 5.0;

    private var _baselineSec as Number;
    private var _baselineBuf as Array<Float>;
    private var _baselineCount as Number = 0;
    private var _baselineNextAt as Number = 0;   // elapsed seconds of next sample
    private var _baselineStride as Number = 1;
    private var _baseline as Float? = null;
    private var _elapsed as Number = 0;          // seconds of valid data seen

    private var _min as Float? = null;
    private var _max as Float? = null;
    private var _lastRelaxMs as Number = 0;

    // Lap 1 acts as the calibration interval.
    private var _lapIndex as Number = 0;
    private var _calibStart as Float? = null;
    private var _calibEnd as Float? = null;

    // Per-lap statistics for the FIT lap fields.
    private var _lapStart as Float? = null;
    private var _lapMin as Float? = null;
    private var _lapMax as Float? = null;
    private var _lapStartMs as Number = 0;

    // Session average.
    private var _sum as Float = 0.0;
    private var _n as Number = 0;

    public function initialize(baselineSec as Number) {
        _baselineSec = baselineSec;
        var cap = baselineSec;
        if (cap > BASELINE_MAX_SAMPLES) {
            _baselineStride = (baselineSec / BASELINE_MAX_SAMPLES) + 1;
            cap = BASELINE_MAX_SAMPLES;
        }
        if (cap < 1) { cap = 1; }
        _baselineBuf = new Array<Float>[cap];
        _lastRelaxMs = System.getTimer();
        _lapStartMs = _lastRelaxMs;
    }

    //! Feed one smoothed SmO2 value. Raw values are never passed in here — a
    //! sensor spike must not be able to define the session range.
    //! @param timerRunning false while the activity is paused; the session
    //!        average must not absorb ten minutes of standing around, but the
    //!        baseline and range still track (that is what warm-up is for).
    public function update(level as Float, timerRunning as Boolean) as Void {
        _elapsed++;
        if (timerRunning) {
            _sum += level;
            _n++;
        }

        collectBaseline(level);
        updateExtremes(level);
        updateLapStats(level);
    }

    private function collectBaseline(level as Float) as Void {
        if (_baseline != null || _baselineSec <= 0) {
            return;
        }
        if (_elapsed >= _baselineNextAt && _baselineCount < _baselineBuf.size()) {
            _baselineBuf[_baselineCount] = level;
            _baselineCount++;
            _baselineNextAt = _elapsed + _baselineStride;
        }
        if (_elapsed >= _baselineSec && _baselineCount > 0) {
            _baseline = median(_baselineBuf, _baselineCount);
            _baselineBuf = new Array<Float>[1];   // release the buffer
        }
    }

    private function updateExtremes(level as Float) as Void {
        if (_min == null || level < (_min as Float)) { _min = level; }
        if (_max == null || level > (_max as Float)) { _max = level; }

        var now = System.getTimer();
        var dt = (now - _lastRelaxMs) / 1000.0;
        if (dt <= 0.0 || dt > 10.0) {
            _lastRelaxMs = now;
            return;
        }
        _lastRelaxMs = now;

        var step = RELAX_RATE * dt;
        var lo = _min as Float;
        var hi = _max as Float;
        if (level - lo > RELAX_DEADBAND) { lo += step; }
        if (hi - level > RELAX_DEADBAND) { hi -= step; }
        // Never let relaxation collapse the range past the current value.
        if (lo > level) { lo = level; }
        if (hi < level) { hi = level; }
        _min = lo;
        _max = hi;
    }

    private function updateLapStats(level as Float) as Void {
        if (_lapStart == null) { _lapStart = level; }
        if (_lapMin == null || level < (_lapMin as Float)) { _lapMin = level; }
        if (_lapMax == null || level > (_lapMax as Float)) { _lapMax = level; }
    }

    //! Lap button pressed. Closes the current lap and returns its statistics,
    //! or null when the lap held no valid data.
    //! @param onKin steepest on-transient slope seen during the lap, %/s
    //! @return { :rate, :onKin => %/s, :min, :max, :start, :end => % }
    public function onLap(level as Float?, onKin as Float) as Dictionary<Symbol, Float>? {
        var result = null as Dictionary<Symbol, Float>?;
        var now = System.getTimer();
        var lapSec = (now - _lapStartMs) / 1000.0;

        if (_lapStart != null && level != null && lapSec > 1.0) {
            var start = _lapStart as Float;
            // Kane's per-interval desaturation rate: (end − start) / lap time.
            result = {
                :rate  => ((level as Float) - start) / lapSec,
                :onKin => onKin,
                :min   => _lapMin as Float,
                :max   => _lapMax as Float,
                :start => start,
                :end   => level as Float
            };
        }

        // The first lap doubles as the calibration interval: its start and end
        // anchor the working band for the rest of the session.
        if (_lapIndex == 0 && _lapStart != null && level != null) {
            _calibStart = _lapStart;
            _calibEnd = level;
        }

        // A second lap press within 2 s means "re-calibrate": drop the session
        // range (used after re-seating the sensor).
        if (lapSec < 2.0) {
            resetRange(level);
        }

        _lapIndex++;
        _lapStart = level;
        _lapMin = level;
        _lapMax = level;
        _lapStartMs = now;
        return result;
    }

    //! Discard the session extremes and the baseline, keeping the lap counter.
    public function resetRange(level as Float?) as Void {
        _min = level;
        _max = level;
        _baseline = null;
        _baselineCount = 0;
        _baselineNextAt = 0;
        _elapsed = 0;
        var cap = _baselineSec > BASELINE_MAX_SAMPLES ? BASELINE_MAX_SAMPLES : _baselineSec;
        if (cap < 1) { cap = 1; }
        _baselineBuf = new Array<Float>[cap];
    }

    private function median(buf as Array<Float>, count as Number) as Float {
        // Insertion sort on a copy — count is at most 120 and this runs once.
        var a = new Array<Float>[count];
        for (var i = 0; i < count; i++) { a[i] = buf[i]; }
        for (var i = 1; i < count; i++) {
            var v = a[i];
            var j = i - 1;
            while (j >= 0 && a[j] > v) {
                a[j + 1] = a[j];
                j--;
            }
            a[j + 1] = v;
        }
        return (count % 2 == 1) ? a[count / 2] : (a[count / 2 - 1] + a[count / 2]) / 2.0;
    }

    public function getBaseline() as Float? { return _baseline; }
    public function getMin() as Float? { return _min; }
    public function getMax() as Float? { return _max; }

    //! Extremes of the current lap only. Unlike the session range these are
    //! not relaxed back towards the middle — a lap is short enough that its
    //! true extremes stay relevant for its whole length.
    public function getLapMin() as Float? { return _lapMin; }
    public function getLapMax() as Float? { return _lapMax; }
    public function getLapIndex() as Number { return _lapIndex; }
    public function getCalibLow() as Float? { return _calibEnd; }
    public function getCalibHigh() as Float? { return _calibStart; }

    //! Session SmO2 range, floored so SCI cannot explode early in a session.
    public function getRange() as Float {
        if (_min == null || _max == null) { return MIN_RANGE; }
        var r = (_max as Float) - (_min as Float);
        return (r < MIN_RANGE) ? MIN_RANGE : r;
    }

    public function getSessionAverage() as Float? {
        return (_n > 0) ? _sum / _n : null;
    }

    public function onTimerReset() as Void {
        resetRange(null);
        _lapIndex = 0;
        _calibStart = null;
        _calibEnd = null;
        _lapStart = null;
        _lapMin = null;
        _lapMax = null;
        _lapStartMs = System.getTimer();
        _sum = 0.0;
        _n = 0;
    }
}
