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
import Toybox.System;
import Toybox.WatchUi;

class SmO2ControlView extends WatchUi.DataField {

    enum Tier {
        TIER_COMPACT = 0,
        TIER_MEDIUM  = 1,
        TIER_FULL    = 2
    }

    //! Which number the chart-less tiers put next to the traffic light.
    enum SmallMetric {
        METRIC_SMO2 = 0,
        METRIC_RATE = 1,
        METRIC_THB  = 2,
        METRIC_SCI  = 3
    }

    enum RateUnit {
        RATE_PER_SEC = 0,
        RATE_PER_MIN = 1
    }

    //! Whose extremes the session y-axis and the MIN/MAX labels report.
    enum RangeScope {
        SCOPE_SESSION = 0,
        SCOPE_LAP     = 1
    }

    //! The second line of a chart-less tier, under the number.
    enum SmallSecond {
        SECOND_NONE  = 0,
        SECOND_LABEL = 1,
        SECOND_RATE  = 2
    }

    // A chart only earns its pixels above these dimensions. 180 x 110 is the
    // smallest usable rectangle any device gives a full-screen field (the
    // fenix 7S, at 184 x 150), so the chart never disappears from the layout
    // it was designed for.
    private const FULL_MIN_W = 180;
    private const FULL_MIN_H = 110;
    private const MEDIUM_MIN_W = 120;
    private const MEDIUM_MIN_H = 70;

    // ...and it is additionally restricted to the full-screen and half-screen
    // field, per cent of the screen. Size alone is not the right test: the
    // middle strip of a three-up layout is 454 x 158 on an FR970, wider than
    // a fenix 7S full screen, but it is not where anyone goes looking for a
    // trend. 45 % of the height clears a half (50 %) and excludes a third.
    private const FULL_MIN_H_PCT = 45;
    private const FULL_MIN_W_PCT = 90;

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
    private var _smallMetric as Number = METRIC_SMO2;
    private var _rateUnit as Number = RATE_PER_SEC;
    private var _rangeScope as Number = SCOPE_SESSION;
    private var _smallSecond as Number = SECOND_RATE;
    private var _stateIcons as Boolean = true;

    // Layout cache
    private var _tier as Tier = TIER_COMPACT;
    private var _w as Number = 0;
    private var _h as Number = 0;

    // Usable rectangle. Identical to the full dc on rectangular screens; inset
    // to the inscribed rectangle when a round screen is filled edge to edge.
    private var _ux as Number = 0;
    private var _uy as Number = 0;
    private var _uw as Number = 0;
    private var _uh as Number = 0;
    private var _valueFont as FontDefinition = Graphics.FONT_NUMBER_MEDIUM;
    private var _labelFont as FontDefinition = Graphics.FONT_XTINY;
    private var _chartX as Number = 0;
    private var _chartY as Number = 0;
    private var _chartW as Number = 0;
    private var _chartH as Number = 0;

    // Traffic light geometry for the chart-less tiers, and the text column
    // left of it. Both are resolved in onLayout() so no frame has to measure.
    private var _dotR as Number = 0;
    private var _dotX as Number = 0;
    private var _dotY as Number = 0;
    private var _dotGap as Number = 0;
    private var _showUnit as Boolean = false;
    private var _blockTop as Number = 0;
    private var _secondY as Number = 0;
    private var _headH as Number = 0;

    // Latest derived values, produced in compute() and only read in onUpdate().
    private var _dispValue as Float? = null;
    private var _dispState as Number = STATE_UNKNOWN;
    private var _dispTrend as Float = 0.0;
    private var _dispSci as Float = 0.0;
    private var _dispPrediction as Float? = null;
    private var _dispThb as Float? = null;
    private var _sensorState as Number = SENSOR_CLOSED;
    private var _decoupled as Boolean = false;
    private var _paceText as String = "--:--";

    // External load window for decoupling detection.
    private var _load as Array<Float>;
    private var _loadHead as Number = 0;
    private var _loadCount as Number = 0;

    private var _timerRunning as Boolean = false;

    // Set when a settings change invalidated the cached geometry.
    private var _relayout as Boolean = true;

    // Which external load signal this sport uses. Resolved once, the first time
    // the activity profile is readable.
    private var _usePower as Boolean = false;
    private var _sportResolved as Boolean = false;

    public function initialize(sensor as MoxySensor?) {
        DataField.initialize();
        _sensor = sensor;

        var s = readSettings();
        _chartWindowSec = s[:chartWindowSec] as Number;
        _yAxisMode = s[:yAxisMode] as Number;
        _showPace = s[:showPace] as Boolean;
        _recordFit = s[:recordFit] as Boolean;
        _smallMetric = s[:smallMetric] as Number;
        _rateUnit = s[:rateUnit] as Number;
        _rangeScope = s[:rangeScope] as Number;
        _smallSecond = s[:smallSecond] as Number;
        _stateIcons = s[:stateIcons] as Boolean;
        Palette.colorBlind = s[:colorBlind] as Boolean;
        Palette.zoneLabels = s[:zoneLabels] as Boolean;

        _kinetics = new Kinetics(
            s[:alpha] as Float, s[:beta] as Float,
            s[:thetaStable] as Float, s[:thetaDrift] as Float,
            s[:predictHorizon] as Number, s[:steadyWindowSec] as Number);
        _calib = new SessionCalibration(s[:baselineSec] as Number);
        _chart = new ChartRenderer(_chartWindowSec, s[:steadyWindowSec] as Number);
        _chart.setClassifier(_kinetics.method(:stateForSlope));
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
            :thetaStable    => numProp("thetaStable1000", 60) / 1000.0,
            :thetaDrift     => numProp("thetaDrift1000", 150) / 1000.0,
            :steadyWindowSec=> numProp("steadyWindowSec", 60),
            :predictHorizon => numProp("predictHorizon", 15),
            :chartWindowSec => numProp("chartWindowSec", 90),
            :yAxisMode      => numProp("yAxisMode", 0),
            :baselineSec    => numProp("baselineSec", 60),
            :colorBlind     => boolProp("colorBlind", false),
            :showPace       => boolProp("showPace", true),
            :recordFit      => boolProp("recordFit", true),
            :smallMetric    => numProp("smallMetric", 0),
            :rateUnit       => numProp("rateUnit", 0),
            :rangeScope     => numProp("rangeScope", 0),
            :smallSecond    => numProp("smallSecond", 2),
            :stateIcons     => boolProp("stateIcons", true),
            :zoneLabels     => boolProp("zoneLabels", true)
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
        _smallMetric = s[:smallMetric] as Number;
        _rateUnit = s[:rateUnit] as Number;
        _rangeScope = s[:rangeScope] as Number;
        _smallSecond = s[:smallSecond] as Number;
        _stateIcons = s[:stateIcons] as Boolean;
        Palette.colorBlind = s[:colorBlind] as Boolean;
        Palette.zoneLabels = s[:zoneLabels] as Boolean;
        _kinetics.setParams(
            s[:alpha] as Float, s[:beta] as Float,
            s[:thetaStable] as Float, s[:thetaDrift] as Float,
            s[:predictHorizon] as Number, s[:steadyWindowSec] as Number);

        var win = s[:chartWindowSec] as Number;
        if (win != _chartWindowSec) {
            _chartWindowSec = win;
            _chart = new ChartRenderer(win, s[:steadyWindowSec] as Number);
            _chart.setClassifier(_kinetics.method(:stateForSlope));
        } else {
            _chart.setStateLag(s[:steadyWindowSec] as Number);
        }
        _relayout = true;
    }

    //! Pick the layout tier and cache every derived geometry value. Doing this
    //! per frame would be wasted work — the size never changes at runtime.
    public function onLayout(dc as Dc) as Void {
        _w = dc.getWidth();
        _h = dc.getHeight();
        computeUsableRect();
        layoutTier(dc);
        _relayout = false;
    }

    //! Geometry for the chosen tier. Split out of onLayout() because a
    //! settings change can alter what has to fit — a longer state vocabulary,
    //! a different metric — and the sizes are derived from the text.
    private function layoutTier(dc as Dc) as Void {

        // Decide the tier from the usable rectangle, not the raw context. On a
        // round watch a 225 x 225 quadrant only puts 161 x 155 on the glass,
        // and handing that the full chart layout crams a header, a footer, an
        // axis and 90 samples into a strip barely 80 px tall.
        var screen = System.getDeviceSettings();
        var ownsScreen = _h * 100 >= screen.screenHeight * FULL_MIN_H_PCT
                         && _w * 100 >= screen.screenWidth * FULL_MIN_W_PCT;
        if (ownsScreen && _uw >= FULL_MIN_W && _uh >= FULL_MIN_H) {
            _tier = TIER_FULL;
        } else if (_uw >= MEDIUM_MIN_W && _uh >= MEDIUM_MIN_H) {
            _tier = TIER_MEDIUM;
        } else {
            _tier = TIER_COMPACT;
        }

        if (_tier == TIER_FULL) {
            _labelFont = Graphics.FONT_XTINY;
            _chart.setAxisFont(_labelFont);
            _chart.setShowAxis(true);
            // The chart is the point of this tier, so it gets everything that
            // is not one header row and one footer row. The header carries the
            // value and the state; the footer carries the rate, which is the
            // metric the colour is actually derived from.
            //
            // The value shares its row with the state dot and label, so it may
            // only have what those leave over — sizing it blind would let it
            // run underneath "ZONE 2+" on any device narrower than the FR970.
            // Capped in height as well as width: the chart is the subject of
            // this tier, so the header is not allowed to eat more than a third
            // of it however much room the width would allow.
            // Half the label height: the light matches the cap height of the
            // word beside it, and is big enough to hold a glyph on every
            // device that reaches this tier.
            var labelH = Graphics.getFontAscent(_labelFont);
            _dotR = labelH / 2;
            if (_dotR < 3) { _dotR = 3; }
            var stateW = dc.getTextWidthInPixels(Palette.widestLabel(), _labelFont)
                         + 2 * _dotR + PAD;
            _valueFont = largestNumberFont(dc, _uw - stateW - 3 * PAD, _uh / 3);
            // The header is as tall as the taller of the two things in it. On
            // a narrow device the value font degrades below the label font,
            // and sizing the row off the value alone pushed the state label
            // off the top of the usable rectangle.
            var headH = Graphics.getFontAscent(_valueFont);
            if (headH < labelH) { headH = labelH; }
            _headH = headH;

            _chartX = _ux + PAD;
            _chartY = _uy + PAD + headH + PAD;
            _chartW = _uw - 2 * PAD;
            _chartH = _uy + _uh - PAD - labelH - PAD - _chartY;
            if (_chartH < 20) { _chartH = 20; }
        } else {
            // No chart below the half-screen sizes. A sparkline squeezed into
            // a quarter of a round watch is decoration: too few pixels per
            // sample to read a slope off, and it costs the space the number
            // and the traffic light need to stay legible in motion.
            _chartW = 0;
            _chartH = 0;
            _labelFont = Graphics.FONT_XTINY;

            // Traffic light and number are one horizontal group, centred in
            // the cell: light first, number after it. Reading order runs
            // left to right, so the verdict should arrive before the value it
            // qualifies — and a disc pinned to the right edge left the two
            // looking like unrelated tenants of the same box.
            //
            // The disc is exactly as tall as the digits. Anything else and the
            // pair reads as two elements at two scales rather than as one.
            var capH = Graphics.getFontAscent(_labelFont);
            _showUnit = _smallSecond != SECOND_NONE
                        && _uh >= 3 * capH
                        && _tier == TIER_MEDIUM;
            var contentH = _showUnit ? _uh - capH - PAD : _uh;
            _valueFont = largestGaugeFont(dc, _uw - 2 * PAD, contentH - 2 * PAD);
            _dotR = Graphics.getFontAscent(_valueFont) / 2;
            _dotGap = gaugeGap(_dotR);
            // Centre the block as a whole rather than centring the number
            // and hanging the second line off the bottom edge — that left a
            // gap under the number and none under the caption.
            var vAsc = Graphics.getFontAscent(_valueFont);
            var blockH = _showUnit ? vAsc + PAD + capH : vAsc;
            _blockTop = _uy + (_uh - blockH) / 2;
            _dotY = _blockTop + vAsc / 2;
            _secondY = _blockTop + vAsc + PAD;
        }
    }

    //! Clear air between the light and the digits, proportional to the disc so
    //! it holds at every field size.
    private function gaugeGap(r as Number) as Number {
        var g = r / 2;
        return (g < 3) ? 3 : g;
    }

    //! Largest font for which the light-plus-number group still fits the
    //! width. The disc is sized from the font, so the two constraints are
    //! circular and have to be resolved together rather than in sequence.
    private function largestGaugeFont(dc as Dc, availW as Number,
                                      availH as Number) as FontDefinition {
        var candidates = [
            Graphics.FONT_NUMBER_MEDIUM,
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM,
            Graphics.FONT_SMALL
        ];
        var sample = metricSample();
        for (var i = 0; i < candidates.size(); i++) {
            var f = candidates[i];
            var asc = Graphics.getFontAscent(f);
            var w = asc + gaugeGap(asc / 2) + dc.getTextWidthInPixels(sample, f);
            if (w <= availW && asc <= availH) {
                return f;
            }
        }
        return Graphics.FONT_XTINY;
    }

    //! Widest number font whose worst-case text fits the given width and
    //! height. The sample comes from the metric on show: "88.8" for SmO2,
    //! but "-88.8" once a signed rate can appear.
    private function largestNumberFont(dc as Dc, avail as Number,
                                       maxHeight as Number) as FontDefinition {
        var sample = metricSample();
        var candidates = [
            Graphics.FONT_NUMBER_MEDIUM,
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM,
            Graphics.FONT_SMALL
        ];
        for (var i = 0; i < candidates.size(); i++) {
            var f = candidates[i];
            if (dc.getTextWidthInPixels(sample, f) <= avail
                && Graphics.getFontAscent(f) <= maxHeight) {
                return f;
            }
        }
        return Graphics.FONT_XTINY;
    }

    //! Work out the area that is actually on the glass.
    //!
    //! A data field on a round watch gets a rectangular device context, but the
    //! corners of that rectangle are not part of the display. Laying out
    //! against the full rectangle puts content where it can never be seen. On a
    //! 454 px round screen: a full-screen field's row at y = 431 is only
    //! visible between x = 127 and x = 327, and the top half-screen field is
    //! barely 85 px wide along its own top edge.
    //!
    //! getObscurityFlags() says which edges sit against the screen boundary,
    //! and Garmin's layouts always place a field either flush to an edge or
    //! centred. That is enough to recover the field's origin in screen
    //! coordinates, and from there the circle in field coordinates.
    private function computeUsableRect() as Void {
        _ux = 0;
        _uy = 0;
        _uw = _w;
        _uh = _h;

        var settings = System.getDeviceSettings();
        if (settings.screenShape != System.SCREEN_SHAPE_ROUND) {
            return;
        }

        var flags = getObscurityFlags();
        var screenW = settings.screenWidth;
        var screenH = settings.screenHeight;

        // Where this field sits on the screen, inferred from which of its edges
        // are against the boundary.
        var originX = (screenW - _w) / 2;
        if (flags & OBSCURE_LEFT) {
            originX = 0;
        } else if (flags & OBSCURE_RIGHT) {
            originX = screenW - _w;
        }
        var originY = (screenH - _h) / 2;
        if (flags & OBSCURE_TOP) {
            originY = 0;
        } else if (flags & OBSCURE_BOTTOM) {
            originY = screenH - _h;
        }

        // Circle, expressed in this field's own coordinates.
        var cx = screenW / 2.0 - originX;
        var cy = screenH / 2.0 - originY;
        var r = screenW / 2.0;

        fitRectToCircle(cx, cy, r);
    }

    //! Largest usable axis-aligned rectangle inside both the field and the
    //! circle. Trimming height buys width, so the two are traded off against
    //! each other: a coarse search over top and bottom insets, scored by area.
    //!
    //! Landscape candidates win over portrait ones of the same area. Every
    //! tier lays out horizontally — value beside labels, above a wide
    //! sparkline — so raw area is the wrong thing to maximise on its own: on a
    //! full round screen it picks a 294 x 342 rectangle that leaves the value
    //! and the state labels overlapping, where 376 x 254 suits the content.
    //!
    //! Runs once in onLayout(), never per frame.
    private function fitRectToCircle(cx as Float, cy as Float, r as Float) as Void {
        var step = _h / 16;
        if (step < 1) { step = 1; }

        // A pixel of slack. Without it the corners land exactly on the circle
        // and integer truncation pushes them a fraction outside — verified
        // against all 50 data field rectangles the FR970 defines.
        var rEff = r - 1.0;

        var bestArea = -1;
        var bestLandscape = false;
        for (var top = 0; top <= _h / 2; top += step) {
            for (var bottom = 0; bottom <= _h / 2; bottom += step) {
                var y1 = top;
                var y2 = _h - bottom;
                if (y2 - y1 < _h / 4) {
                    continue;         // too squashed to be worth the width
                }
                // The binding constraint is whichever edge is further from the
                // circle's centre line.
                var dy = (y1 - cy).abs();
                var d2 = (y2 - cy).abs();
                if (d2 > dy) { dy = d2; }
                if (dy >= rEff) {
                    continue;         // that edge is off the glass entirely
                }

                // Round inwards on both sides, so the result is a rectangle
                // that fits rather than one that merely nearly fits.
                var halfW = Math.sqrt(rEff * rEff - dy * dy);
                var x1 = Math.ceil(cx - halfW).toNumber();
                var x2 = Math.floor(cx + halfW).toNumber();
                if (x1 < 0) { x1 = 0; }
                if (x2 > _w) { x2 = _w; }
                var width = x2 - x1;
                if (width <= 0) {
                    continue;
                }

                var height = y2 - y1;
                var area = width * height;
                var landscape = width >= height;
                // A landscape candidate always beats a portrait one; among
                // equals, take the larger.
                var better = landscape && !bestLandscape;
                if (landscape == bestLandscape) {
                    better = area > bestArea;
                }
                if (better) {
                    bestArea = area;
                    bestLandscape = landscape;
                    _ux = x1;
                    _uy = y1;
                    _uw = width;
                    _uh = height;
                }
            }
        }

        if (bestArea < 0) {
            // Nothing fits; fall back to the raw rectangle rather than to
            // nothing at all.
            _ux = 0;
            _uy = 0;
            _uw = _w;
            _uh = _h;
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
                _calib.update(level as Float, _timerRunning);
                _dispValue = level;
                _dispTrend = _kinetics.getSlowSlope();
                _dispState = _kinetics.getState();
                _dispSci = _kinetics.getSCI(_calib.getRange());
                _dispPrediction = _kinetics.getPrediction();
                _chart.push(level, _dispState);
            }
        }

        _dispThb = sensor.getTHb();
        updateLoad(info);

        var fit = _fit;
        if (fit != null) {
            fit.compute(_dispValue, _dispTrend, _dispSci, _dispState, _dispThb);
            fit.setSessionAverage(_calib.getSessionAverage());
        }
    }

    //! Track the external load so we can flag decoupling: load flat while SmO2
    //! keeps sliding is the early sign of efficiency loss, and it is invisible
    //! in either signal on its own.
    //!
    //! Which signal counts as "the load" depends on the sport. On the bike that
    //! is power. Running by watts is a minority taste and running power from a
    //! watch is noisy, so there the load — and the display — is pace.
    private function updateLoad(info as Activity.Info) as Void {
        resolveSport();

        var load = null as Float?;
        var power = info.currentPower;
        var speed = info.currentSpeed;

        if (_usePower && power != null && (power as Number) > 0) {
            load = (power as Number).toFloat();
        } else if (speed != null && (speed as Float) > 0.3) {
            load = speed as Float;
        }

        _paceText = formatLoad(speed, power);

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

    //! Cache whether this sport is measured in watts. The activity profile is
    //! not always readable at construction time, so this resolves lazily and
    //! then stops asking.
    private function resolveSport() as Void {
        if (_sportResolved) {
            return;
        }
        var profile = Activity.getProfileInfo();
        if (profile == null) {
            return;
        }
        _usePower = (profile.sport == Activity.SPORT_CYCLING);
        _sportResolved = true;
    }

    //! Power on the bike, pace everywhere else — in the units the watch is set
    //! to, so a statute user is not handed min/km.
    private function formatLoad(speed as Float?, power as Number?) as String {
        if (_usePower) {
            if (power != null && (power as Number) > 0) {
                return (power as Number).format("%d") + "W";
            }
            return "--W";
        }
        if (speed == null || (speed as Float) < 0.3) {
            return "--:--";
        }
        var perUnit = (System.getDeviceSettings().paceUnits == System.UNIT_STATUTE)
            ? 1609.344 : 1000.0;
        var sec = (perUnit / (speed as Float)).toNumber();
        if (sec > 3599) { return "--:--"; }
        return (sec / 60).format("%d") + ":" + (sec % 60).format("%02d");
    }

    public function onUpdate(dc as Dc) as Void {
        if (_relayout) {
            // A settings change can alter what has to fit. onLayout() is not
            // called again for that, so the geometry is refreshed here, once.
            layoutTier(dc);
            _relayout = false;
        }

        var bg = getBackgroundColor();
        var fg = (bg == Graphics.COLOR_WHITE) ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;

        if (_tier == TIER_FULL) {
            drawFull(dc, fg, bg);
        } else {
            drawGauge(dc, fg, bg);
        }
    }

    //! Every tier below half-screen: one number and a traffic light.
    //!
    //! The light is the point. A coloured disc is recognised pre-attentively,
    //! which a word is not, and it survives being glanced at from a moving
    //! wrist at any size the layout allows. The number beside it is whichever
    //! metric the athlete chose; the colour never changes meaning with it.
    private function drawGauge(dc as Dc, fg as Number, bg as Number) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        var known = _dispState != STATE_UNKNOWN && _sensorState == SENSOR_TRACKING;
        var text = metricText();
        var textW = dc.getTextWidthInPixels(text, _valueFont);
        var groupW = 2 * _dotR + _dotGap + textW;
        var x0 = _ux + (_uw - groupW) / 2;

        // An unlit light still has to read as a light rather than as nothing,
        // or a dropout looks like a layout bug.
        if (known) {
            dc.setColor(Palette.forState(_dispState), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x0 + _dotR, _dotY, _dotR);
            if (_stateIcons) {
                // Knocked out of the disc in the background colour, so the
                // glyph reads as a hole in the light rather than as a second
                // object sitting on top of it.
                StateIcon.draw(dc, x0 + _dotR, _dotY, _dotR, _dispState, bg);
            }
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawCircle(x0 + _dotR, _dotY, _dotR - 1);
            dc.setPenWidth(1);
        }

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x0 + 2 * _dotR + _dotGap, _dotY, _valueFont, text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        if (_showUnit) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_ux + _uw / 2, _secondY, _labelFont, secondText(),
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! Full tier: the chart is the subject. One metric above it, one below.
    //!
    //! The session range used to be printed in the footer; it is the y axis
    //! now, which is where a range belongs. SCI is gone from the display
    //! entirely — dimensionless and hard to read in motion, and the rate says
    //! the same thing in units you can act on. It is still written to the FIT.
    private function drawFull(dc as Dc, fg as Number, bg as Number) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        var stateColor = (_dispState == STATE_UNKNOWN) ? fg : Palette.forState(_dispState);
        var left = _ux + PAD;
        var right = _ux + _uw - PAD;
        var lineH = Graphics.getFontAscent(_labelFont);

        // Header: the value, and what it is doing. Both are centred on the
        // row rather than hung off its top, so they share a baseline whatever
        // the two fonts turn out to be.
        var headMid = _uy + PAD + _headH / 2;
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, headMid, _valueFont, valueText(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // The state as a light plus its name. The word alone made the chart
        // the only colour-carrying element on the screen, so the header and
        // the trace disagreed about how loudly they were saying the same
        // thing; the dot is what the chart-less tiers show, which keeps one
        // visual vocabulary across every size of the field.
        var text = statusText();
        if (_dispState != STATE_UNKNOWN && _sensorState == SENSOR_TRACKING) {
            var tw = dc.getTextWidthInPixels(text, _labelFont);
            var dotCx = right - tw - PAD - _dotR;
            dc.fillCircle(dotCx, headMid, _dotR);
            if (_stateIcons) {
                StateIcon.draw(dc, dotCx, headMid, _dotR, _dispState, bg);
            }
        }
        dc.drawText(right, headMid, _labelFont, text,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        _chart.setBounds(_yAxisMode, rangeMin(), rangeMax());
        _chart.draw(dc, _chartX, _chartY, _chartW, _chartH, _dispPrediction, fg);

        // Footer: the rate the verdict rests on, and the external load beside
        // it when there is one. Decoupling turns the load red, because that is
        // the moment it stops being background information.
        var footY = _uy + _uh - PAD - lineH;
        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, footY, _labelFont, trendText(), Graphics.TEXT_JUSTIFY_LEFT);

        if (_showPace) {
            dc.setColor(_decoupled ? Palette.forState(STATE_OVERSHOOT) : fg,
                Graphics.COLOR_TRANSPARENT);
            var loadLine = _paceText;
            if (_decoupled) {
                loadLine += " DECOUP";
            }
            dc.drawText(right, footY, _labelFont, loadLine, Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }

    //! Which extremes the session scaling and the MIN/MAX labels report.
    //! Session-wide answers "where is this sitting in my whole range today";
    //! lap-wide answers "what has this interval done", which is the more
    //! useful frame during structured work and the less useful one on a
    //! steady ride, so it is a setting rather than a decision.
    private function rangeMin() as Float? {
        return (_rangeScope == SCOPE_LAP) ? _calib.getLapMin() : _calib.getMin();
    }

    private function rangeMax() as Float? {
        return (_rangeScope == SCOPE_LAP) ? _calib.getLapMax() : _calib.getMax();
    }

    //! Worst-case string for the metric on show, for font sizing. The full
    //! tier always shows SmO2 whatever the small tiers are set to.
    private function metricSample() as String {
        if (_tier == TIER_FULL) { return "88.8"; }
        switch (_smallMetric) {
            case METRIC_RATE: return (_rateUnit == RATE_PER_MIN) ? "-88.8" : "-8.88";
            case METRIC_THB:  return "88.88";
            case METRIC_SCI:  return "8.88";
        }
        return "88.8";
    }

    //! The chosen metric as text, without its unit.
    private function metricText() as String {
        if (_sensorState == SENSOR_CLOSED) { return "---"; }
        switch (_smallMetric) {
            case METRIC_RATE:
                if (_dispState == STATE_UNKNOWN) { return "--"; }
                return rateValue().format((_rateUnit == RATE_PER_MIN) ? "%.1f" : "%.2f");
            case METRIC_THB:
                var thb = _dispThb;
                return (thb == null) ? "--" : (thb as Float).format("%.2f");
            case METRIC_SCI:
                if (_dispState == STATE_UNKNOWN) { return "--"; }
                return _dispSci.format("%.2f");
        }
        return valueText();
    }

    //! The second line. The rate is the default because it is the more
    //! informative number: it is what the state classification is computed
    //! from, so it is the one that moves before the colour does. Showing it
    //! under a level that is already the rate would say the same thing twice,
    //! so that case falls back to naming the metric.
    private function secondText() as String {
        if (_smallSecond == SECOND_RATE && _smallMetric != METRIC_RATE) {
            return trendText();
        }
        return metricUnit();
    }

    private function metricUnit() as String {
        switch (_smallMetric) {
            case METRIC_RATE: return rateUnitText();
            case METRIC_THB:  return "THb";
            case METRIC_SCI:  return "SCI";
        }
        return "SmO2";
    }

    //! The rate in the configured unit. %/s is the natural unit of the
    //! regression, but at a plateau it reads -0.01 and every interesting
    //! digit is past the decimal point; %/min moves the numbers into a range
    //! that can be compared at a glance.
    private function rateValue() as Float {
        return (_rateUnit == RATE_PER_MIN) ? _dispTrend * 60.0 : _dispTrend;
    }

    private function rateUnitText() as String {
        return (_rateUnit == RATE_PER_MIN) ? "%/min" : "%/s";
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
        var v = rateValue();
        var sign = (v >= 0.0) ? "+" : "";
        var digits = (_rateUnit == RATE_PER_MIN) ? "%.1f" : "%.3f";
        return sign + v.format(digits) + rateUnitText();
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
        _dispThb = null;
        _loadCount = 0;
        _loadHead = 0;
        _decoupled = false;
    }
}
