//
// SmO2ControlView.mc — the data field itself.
//
// The message to the athlete is not "SmO2 = 34 %". It is "falling / holding /
// still drifting / recovering", and how fast. Everything below serves that.
//
// Three layout tiers are picked once in onLayout() from the rendered size, so
// the same field is useful full-screen and as one cell of a four-up layout.
//

import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

class SmO2ControlView extends WatchUi.DataField {

    enum Tier {
        TIER_COMPACT = 0,
        TIER_MEDIUM  = 1,
        TIER_FULL    = 2
    }

    // A chart only earns its pixels above these dimensions.
    private const FULL_MIN_W = 200;
    private const FULL_MIN_H = 150;
    private const MEDIUM_MIN_W = 120;
    private const MEDIUM_MIN_H = 70;

    private const PAD = 4;

    // Rolling window used to decide whether the external load is steady.
    private const LOAD_WINDOW = 30;
    private const LOAD_STEADY_CV = 0.04;   // 4 % coefficient of variation

    private var _sensor as MoxySensor?;
    private var _kinetics as Kinetics;
    private var _calib as SessionCalibration;
    private var _chart as ChartRenderer;
    private var _fit as SmO2FitContributor?;

    // Settings
    private var _chartWindowSec as Number = 90;
    private var _yAxisMode as Number = 0;
    private var _showPace as Boolean = true;
    private var _recordFit as Boolean = true;

    // Layout cache
    private var _tier as Tier = TIER_COMPACT;
    private var _w as Number = 0;
    private var _h as Number = 0;
    private var _valueFont as FontDefinition = Graphics.FONT_NUMBER_MEDIUM;
    private var _labelFont as FontDefinition = Graphics.FONT_XTINY;
    private var _chartX as Number = 0;
    private var _chartY as Number = 0;
    private var _chartW as Number = 0;
    private var _chartH as Number = 0;

    // Latest derived values, produced in compute() and only read in onUpdate().
    private var _dispValue as Float? = null;
    private var _dispState as Number = STATE_UNKNOWN;
    private var _dispTrend as Float = 0.0;
    private var _dispSci as Float = 0.0;
    private var _dispPrediction as Float? = null;
    private var _sensorState as Number = SENSOR_CLOSED;
    private var _decoupled as Boolean = false;
    private var _paceText as String = "--:--";

    // External load window for decoupling detection.
    private var _load as Array<Float>;
    private var _loadHead as Number = 0;
    private var _loadCount as Number = 0;

    private var _timerRunning as Boolean = false;

    public function initialize(sensor as MoxySensor?) {
        DataField.initialize();
        _sensor = sensor;

        var s = readSettings();
        _chartWindowSec = s[:chartWindowSec] as Number;
        _yAxisMode = s[:yAxisMode] as Number;
        _showPace = s[:showPace] as Boolean;
        _recordFit = s[:recordFit] as Boolean;
        Palette.colorBlind = s[:colorBlind] as Boolean;

        _kinetics = new Kinetics(
            s[:alpha] as Float, s[:beta] as Float,
            s[:thetaStable] as Float, s[:thetaDrift] as Float,
            s[:predictHorizon] as Number, s[:steadyWindowSec] as Number);
        _calib = new SessionCalibration(s[:baselineSec] as Number);
        _chart = new ChartRenderer(_chartWindowSec);
        _load = new Array<Float>[LOAD_WINDOW];

        if (_recordFit) {
            _fit = new SmO2FitContributor(self);
        }
    }

    //! Read all app properties into one dictionary, converting the integer-coded
    //! float settings back into floats.
    private function readSettings() as Dictionary<Symbol, Object> {
        return {
            :alpha          => numProp("smoothingAlpha100", 30) / 100.0,
            :beta           => numProp("smoothingBeta100", 15) / 100.0,
            :thetaStable    => numProp("thetaStable1000", 20) / 1000.0,
            :thetaDrift     => numProp("thetaDrift1000", 50) / 1000.0,
            :steadyWindowSec=> numProp("steadyWindowSec", 45),
            :predictHorizon => numProp("predictHorizon", 15),
            :chartWindowSec => numProp("chartWindowSec", 90),
            :yAxisMode      => numProp("yAxisMode", 0),
            :baselineSec    => numProp("baselineSec", 60),
            :colorBlind     => boolProp("colorBlind", false),
            :showPace       => boolProp("showPace", true),
            :recordFit      => boolProp("recordFit", true)
        };
    }

    private function numProp(key as String, fallback as Number) as Number {
        var v = Application.Properties.getValue(key);
        return (v instanceof Number) ? v : fallback;
    }

    private function boolProp(key as String, fallback as Boolean) as Boolean {
        var v = Application.Properties.getValue(key);
        return (v instanceof Boolean) ? v : fallback;
    }

    //! Re-read settings live. The filter state survives; the chart is only
    //! reallocated when the window length actually changed.
    public function onSettingsChanged() as Void {
        var s = readSettings();
        _yAxisMode = s[:yAxisMode] as Number;
        _showPace = s[:showPace] as Boolean;
        Palette.colorBlind = s[:colorBlind] as Boolean;
        _kinetics.setParams(
            s[:alpha] as Float, s[:beta] as Float,
            s[:thetaStable] as Float, s[:thetaDrift] as Float,
            s[:predictHorizon] as Number, s[:steadyWindowSec] as Number);

        var win = s[:chartWindowSec] as Number;
        if (win != _chartWindowSec) {
            _chartWindowSec = win;
            _chart = new ChartRenderer(win);
        }
    }

    //! Pick the layout tier and cache every derived geometry value. Doing this
    //! per frame would be wasted work — the size never changes at runtime.
    public function onLayout(dc as Dc) as Void {
        _w = dc.getWidth();
        _h = dc.getHeight();

        if (_w >= FULL_MIN_W && _h >= FULL_MIN_H) {
            _tier = TIER_FULL;
        } else if (_w >= MEDIUM_MIN_W && _h >= MEDIUM_MIN_H) {
            _tier = TIER_MEDIUM;
        } else {
            _tier = TIER_COMPACT;
        }

        if (_tier == TIER_FULL) {
            _valueFont = Graphics.FONT_NUMBER_MEDIUM;
            _labelFont = Graphics.FONT_XTINY;
            var top = PAD + Graphics.getFontAscent(_valueFont) + Graphics.getFontAscent(_labelFont);
            _chartX = PAD;
            _chartY = top;
            _chartW = _w - 2 * PAD;
            _chartH = _h - top - PAD - (_showPace ? Graphics.getFontAscent(_labelFont) : 0);
            if (_chartH < 20) { _chartH = 20; }
        } else if (_tier == TIER_MEDIUM) {
            _valueFont = Graphics.FONT_NUMBER_MILD;
            _labelFont = Graphics.FONT_XTINY;
            // Value on the left, mini sparkline on the right.
            _chartW = _w / 2 - PAD;
            _chartX = _w / 2;
            _chartY = PAD;
            _chartH = _h - 2 * PAD;
        } else {
            _valueFont = Graphics.FONT_NUMBER_MILD;
            _labelFont = Graphics.FONT_XTINY;
            _chartW = 0;
            _chartH = 0;
        }
    }

    //! Runs at ~1 Hz. All sensor reading, filtering and FIT writing happens
    //! here; onUpdate() only paints what this produced.
    public function compute(info as Activity.Info) as Void {
        var sensor = _sensor;
        if (sensor == null) {
            _sensorState = SENSOR_CLOSED;
            return;
        }

        _sensorState = sensor.getState();
        var raw = sensor.getSmO2();

        if (raw == null) {
            // Stale or invalid: freeze the filter rather than inventing a
            // slope of zero out of a frozen reading.
            _kinetics.pause();
            _dispState = STATE_UNKNOWN;
            _chart.push(null, STATE_UNKNOWN);
        } else {
            _kinetics.update(raw as Float);
            var level = _kinetics.getLevel();
            if (level != null) {
                _calib.update(level as Float);
                _dispValue = level;
                _dispTrend = _kinetics.getSlowSlope();
                _dispState = _kinetics.getState();
                _dispSci = _kinetics.getSCI(_calib.getRange());
                _dispPrediction = _kinetics.getPrediction();
                _chart.push(level, _dispState);
            }
        }

        updateLoad(info);

        var fit = _fit;
        if (fit != null) {
            fit.compute(_dispValue, _dispTrend, _dispSci, _dispState, sensor.getTHb());
            fit.setSessionAverage(_calib.getSessionAverage());
        }
    }

    //! Track the external load (power if available, otherwise speed) so we can
    //! flag decoupling: load flat while SmO2 keeps sliding is the early sign of
    //! efficiency loss, and it is invisible in either signal on its own.
    private function updateLoad(info as Activity.Info) as Void {
        var load = null as Float?;
        var power = info.currentPower;
        var speed = info.currentSpeed;

        if (power != null && (power as Number) > 0) {
            load = (power as Number).toFloat();
        } else if (speed != null && (speed as Float) > 0.3) {
            load = speed as Float;
        }

        _paceText = formatPace(speed, power);

        if (load == null) {
            _loadCount = 0;
            _decoupled = false;
            return;
        }

        _load[_loadHead] = load as Float;
        _loadHead = (_loadHead + 1) % LOAD_WINDOW;
        if (_loadCount < LOAD_WINDOW) { _loadCount++; }

        _decoupled = _loadCount >= LOAD_WINDOW
                     && isLoadSteady()
                     && (_dispState == STATE_CONTROL || _dispState == STATE_OVERSHOOT);
    }

    //! Coefficient of variation of the load window below LOAD_STEADY_CV.
    private function isLoadSteady() as Boolean {
        var sum = 0.0;
        for (var i = 0; i < _loadCount; i++) { sum += _load[i]; }
        var mean = sum / _loadCount;
        if (mean <= 0.0) { return false; }

        var sq = 0.0;
        for (var i = 0; i < _loadCount; i++) {
            var d = _load[i] - mean;
            sq += d * d;
        }
        return Math.sqrt(sq / _loadCount) / mean < LOAD_STEADY_CV;
    }

    private function formatPace(speed as Float?, power as Number?) as String {
        if (power != null && (power as Number) > 0) {
            return (power as Number).format("%d") + "W";
        }
        if (speed == null || (speed as Float) < 0.3) {
            return "--:--";
        }
        var secPerKm = (1000.0 / (speed as Float)).toNumber();
        if (secPerKm > 3599) { return "--:--"; }
        return (secPerKm / 60).format("%d") + ":" + (secPerKm % 60).format("%02d");
    }

    public function onUpdate(dc as Dc) as Void {
        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_WHITE) ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;

        if (_tier == TIER_COMPACT) {
            drawCompact(dc, fg, bg);
        } else if (_tier == TIER_MEDIUM) {
            drawMedium(dc, fg, bg);
        } else {
            drawFull(dc, fg, bg);
        }
    }

    //! Compact tier: no chart. The state is carried entirely by the background
    //! colour, so it reads at a glance from a four-up layout.
    private function drawCompact(dc as Dc, fg as Number, bg as Number) as Void {
        var stateColor = Palette.forState(_dispState);
        var haveState = _dispState != STATE_UNKNOWN;

        dc.setColor(Graphics.COLOR_TRANSPARENT, haveState ? stateColor : bg);
        dc.clear();

        var textColor = haveState ? Graphics.COLOR_BLACK : fg;
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);

        var text = valueText();
        dc.drawText(_w / 2, _h / 2, _valueFont, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (haveState) {
            dc.drawText(_w - PAD, _h / 2, _labelFont, Palette.arrowForState(_dispState),
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    //! Medium tier: value plus a mini sparkline, no numeric decoration.
    private function drawMedium(dc as Dc, fg as Number, bg as Number) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        var stateColor = (_dispState == STATE_UNKNOWN) ? fg : Palette.forState(_dispState);
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w / 4, _h / 2, _valueFont, valueText(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w / 4, _h - PAD, _labelFont, Palette.arrowForState(_dispState),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        _chart.draw(dc, _chartX, _chartY, _chartW, _chartH,
            _yAxisMode, _calib.getMin(), _calib.getMax(), null);
    }

    //! Full tier: the whole story — value, state, SCI, coloured sparkline with
    //! lap markers and calibration bands, and the external load underneath.
    private function drawFull(dc as Dc, fg as Number, bg as Number) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        var stateColor = (_dispState == STATE_UNKNOWN) ? fg : Palette.forState(_dispState);

        // Big value, left.
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(PAD, PAD, _valueFont, valueText(), Graphics.TEXT_JUSTIFY_LEFT);

        // State label + trend, right.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var lineH = Graphics.getFontAscent(_labelFont);
        dc.drawText(_w - PAD, PAD, _labelFont, statusText(), Graphics.TEXT_JUSTIFY_RIGHT);
        dc.drawText(_w - PAD, PAD + lineH, _labelFont, trendText(), Graphics.TEXT_JUSTIFY_RIGHT);
        dc.drawText(_w - PAD, PAD + 2 * lineH, _labelFont,
            "SCI " + _dispSci.format("%.3f"), Graphics.TEXT_JUSTIFY_RIGHT);

        _chart.draw(dc, _chartX, _chartY, _chartW, _chartH,
            _yAxisMode, _calib.getMin(), _calib.getMax(), _dispPrediction);

        if (_showPace) {
            var y = _chartY + _chartH;
            dc.setColor(_decoupled ? Palette.forState(STATE_OVERSHOOT) : fg,
                Graphics.COLOR_TRANSPARENT);
            var loadLine = _paceText;
            if (_decoupled) {
                loadLine += "  DECOUPLING";
            }
            dc.drawText(PAD, y, _labelFont, loadLine, Graphics.TEXT_JUSTIFY_LEFT);

            var range = _calib.getMin();
            if (range != null && _calib.getMax() != null) {
                dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
                dc.drawText(_w - PAD, y, _labelFont,
                    (_calib.getMin() as Float).format("%.0f") + "-" +
                    (_calib.getMax() as Float).format("%.0f") + "%",
                    Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }
    }

    private function valueText() as String {
        if (_sensorState == SENSOR_CLOSED) { return "---"; }
        if (_dispValue == null) { return "--"; }
        return (_dispValue as Float).format("%.1f");
    }

    private function statusText() as String {
        switch (_sensorState) {
            case SENSOR_CLOSED:    return "NO ANT";
            case SENSOR_SEARCHING: return "SEARCH";
            case SENSOR_STALE:     return "STALE";
        }
        return Palette.labelForState(_dispState);
    }

    private function trendText() as String {
        if (_dispState == STATE_UNKNOWN) { return "--"; }
        var sign = (_dispTrend >= 0.0) ? "+" : "";
        return sign + _dispTrend.format("%.3f") + "%/s";
    }

    public function onTimerStart() as Void {
        _timerRunning = true;
    }

    public function onTimerStop() as Void {
        _timerRunning = false;
    }

    public function onTimerPause() as Void {
        _timerRunning = false;
    }

    public function onTimerResume() as Void {
        _timerRunning = true;
    }

    //! Lap: close the interval statistics and mark the chart. The first lap
    //! also anchors the session calibration, a double press re-calibrates.
    public function onTimerLap() as Void {
        var stats = _calib.onLap(_kinetics.getLevel(), _kinetics.getPeakTransient());
        // A lap press marks a load change: the old fit describes a workload
        // that no longer applies.
        _kinetics.onStepChange();
        var fit = _fit;
        if (fit != null) {
            fit.onLap(stats);
        }
        _chart.markLap();
    }

    public function onTimerReset() as Void {
        _kinetics.reset();
        _calib.onTimerReset();
        _chart.clear();
        _dispValue = null;
        _dispState = STATE_UNKNOWN;
        _dispTrend = 0.0;
        _dispSci = 0.0;
        _dispPrediction = null;
        _loadCount = 0;
        _loadHead = 0;
        _decoupled = false;
    }
}
