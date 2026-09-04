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

    // Worst-case load string, for sizing its row. "DEC" rather than
    // "DECOUPLING": the row is sized once for the widest thing it can ever
    // hold, and spelling the word out costs the pace two font steps for a
    // flag that the colour already carries.
    private const LOAD_SAMPLE = "88:88 DEC";

    // Widest caption in the cell grid under the chart.
    private const CELL_CAPTION_SAMPLE = "PACE";

    // Font ladders, widest first, shared by every "largest that fits" search.
    private const NUMBER_FONTS = [
        Graphics.FONT_NUMBER_THAI_HOT,
        Graphics.FONT_NUMBER_HOT,
        Graphics.FONT_NUMBER_MEDIUM,
        Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE,
        Graphics.FONT_MEDIUM,
        Graphics.FONT_SMALL,
        Graphics.FONT_XTINY
    ];
    private const TEXT_FONTS = [
        Graphics.FONT_LARGE,
        Graphics.FONT_MEDIUM,
        Graphics.FONT_SMALL,
        Graphics.FONT_XTINY
    ];

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

    // The field's circle in its own coordinates; _cr <= 0 on a rectangular
    // screen, where there is nothing outside the usable rectangle to use.
    private var _cx as Float = 0.0;
    private var _cy as Float = 0.0;
    private var _cr as Float = 0.0;

    // Stacked layout: a centred row in the glass above the usable rectangle
    // and another below it, which lets the value have the full width.
    private var _stacked as Boolean = false;
    private var _stateFont as FontDefinition? = null;
    private var _rateFont as FontDefinition = Graphics.FONT_XTINY;
    private var _loadFont as FontDefinition? = null;

    // The grid of cells under the chart: MIN, MAX and the external load, each
    // a small grey caption over a legible number.
    private var _cellFont as FontDefinition = Graphics.FONT_XTINY;
    private var _capFont as FontDefinition = Graphics.FONT_XTINY;
    private var _cellY as Number = 0;
    private var _cellX as Number = 0;
    private var _cellW as Number = 0;
    private var _cells as Number = 0;
    private var _rateW as Number = 0;
    private var _paceInCells as Boolean = true;
    private var _showRange as Boolean = false;
    private var _stateY as Number = 0;
    private var _valueY as Number = 0;
    private var _rateY as Number = 0;
    private var _loadY as Number = 0;

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
        Palette.plainLabels = s[:plainLabels] as Boolean;

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
            :plainLabels    => boolProp("plainLabels", true)
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
        Palette.plainLabels = s[:plainLabels] as Boolean;
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
            _chart.setShowAxis(true);
            _stacked = layoutEdges(dc) || layoutThirds(dc) || layoutTwoRow(dc);
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

    //! Rectangular full-screen field: metric rows pinned to the top and
    //! bottom edges, chart taking everything between them.
    //!
    //! The rule is to pack away from whatever the binding constraint is. On a
    //! round screen that is the chord, so the rows go inwards and the tips are
    //! written off (see layoutThirds). A rectangle has no chord, so there is
    //! nothing to write off and the rows belong on the edges.
    //!
    //! Splitting a rectangle into thirds instead was the first attempt and is
    //! wrong on a bike computer for a reason that is plain in a screenshot: an
    //! Edge 1040 is 282 x 470, so a third is 156 px tall while two rows of
    //! text need about 100. The chart got a 148 px band in a 470 px screen and
    //! roughly 90 px at the bottom was simply black. Here the rows take what
    //! they need and the chart takes the remainder, which on the same device
    //! is 279 px instead of 148.
    //!
    //! Height caps are fractions of the field rather than of a band, so a tall
    //! screen does not produce absurd text. On every current Edge they do not
    //! even bind: the device's largest number font is shorter than the cap, so
    //! the text is as large as the device offers and the chart gets the rest.
    private function layoutEdges(dc as Dc) as Boolean {
        if (_cr > 0.0) {
            return false;                  // round: layoutThirds owns this
        }
        var screen = System.getDeviceSettings();
        if (_h * 10 < screen.screenHeight * 9 || _w * 10 < screen.screenWidth * 9) {
            return false;
        }

        var availW = _w - 2 * PAD;
        var valueFont = fitByWidth(dc, NUMBER_FONTS, metricSample(), availW,
            _h / 5);
        var stateFont = fitByWidth(dc, TEXT_FONTS, Palette.widestLabel(),
            availW - Graphics.getFontAscent(Graphics.FONT_LARGE) - PAD, _h / 10);
        if (valueFont == null || stateFont == null) {
            return false;
        }
        var valueAsc = Graphics.getFontAscent(valueFont as FontDefinition);
        var stateAsc = Graphics.getFontAscent(stateFont as FontDefinition);

        // Same proportion rule as the round layout: the rate string is three
        // times as long as the value, so at equal heights it reads as the
        // headline, and SmO2 is the headline.
        var rateFont = fitByWidth(dc, TEXT_FONTS, "-8.888%/s", availW,
            valueAsc * 3 / 4);
        if (rateFont == null) {
            return false;
        }
        var rateAsc = Graphics.getFontAscent(rateFont as FontDefinition);

        var cellH = planCells(dc, _h - PAD, _h / 8, _showPace ? 3 : 2, false);
        if (cellH == 0) {
            return false;
        }
        _paceInCells = _showPace;

        var topH = 3 * PAD + stateAsc + valueAsc;
        // Three pads, not two: at two the rate's baseline and the caption
        // row's top edge land on the same pixel.
        var botH = 3 * PAD + rateAsc + cellH;
        var chartH = _h - topH - botH - 2 * PAD;
        if (chartH < FULL_MIN_H) {
            return false;
        }

        _stateFont = stateFont;
        _valueFont = valueFont as FontDefinition;
        _rateFont = rateFont as FontDefinition;
        _dotR = stateAsc / 2;

        _stateY = PAD;
        _valueY = 2 * PAD + stateAsc;
        _rateY = _h - botH + PAD;

        _chartX = PAD;
        _chartY = topH + PAD;
        _chartW = availW;
        _chartH = chartH;
        return true;
    }

    //! Lay out the cell grid under the chart: MIN, MAX, and the external
    //! load when there is a column for it. Each cell is a small grey caption
    //! over the number, which is narrower than putting them on one line and
    //! reads like a dashboard rather than like a sentence.
    //!
    //! `anchor` is the row's top edge when `fromTop`, otherwise its bottom.
    //! The chord is re-measured for every candidate font, because the row's
    //! height depends on the font and the chord depends on the height. The
    //! first version measured down to the bottom of the screen instead, which
    //! is a chord of 73 px on an FR970 and rejected every arrangement.
    //!
    //! Sets _cells, _cellW, _cellX, _capFont and _cellFont, and returns the
    //! row height. Returns 0 if nothing fits, which is the signal to try a
    //! different arrangement.
    private function planCells(dc as Dc, anchor as Number, maxAsc as Number,
                               nCells as Number, fromTop as Boolean) as Number {
        _capFont = Graphics.FONT_XTINY;
        var capAsc = Graphics.getFontAscent(_capFont);
        var capW = dc.getTextWidthInPixels(CELL_CAPTION_SAMPLE, _capFont);
        var sample = (nCells > 2) ? "88:88" : "88.8";

        for (var i = 0; i < TEXT_FONTS.size(); i++) {
            var f = TEXT_FONTS[i];
            var asc = Graphics.getFontAscent(f);
            if (asc > maxAsc || asc < capAsc) {
                continue;
            }
            var rowH = capAsc + asc;
            var top = fromTop ? anchor : anchor - rowH;
            if (top < PAD || top + rowH > _h - PAD) {
                continue;
            }
            var avail = chordAt(top, top + rowH) - 2 * PAD;
            if (avail <= 0) {
                continue;
            }
            var cw = avail / nCells;
            var inner = cw - 2 * PAD;
            if (capW > inner || dc.getTextWidthInPixels(sample, f) > inner) {
                continue;
            }
            _cells = nCells;
            _cellFont = f;
            _cellW = cw;
            _cellX = _cx.toNumber() - avail / 2;
            _cellY = top;
            return rowH;
        }
        return 0;
    }

    //! Largest font from `ladder` whose sample fits a width and a height.    //! Largest font from `ladder` whose sample fits a width and a height.
    //! No chord involved, so this is only for rectangular screens.
    private function fitByWidth(dc as Dc, ladder as Array<FontDefinition>,
                                sample as String, availW as Number,
                                maxAsc as Number) as FontDefinition? {
        for (var i = 0; i < ladder.size(); i++) {
            var f = ladder[i];
            if (Graphics.getFontAscent(f) <= maxAsc
                && dc.getTextWidthInPixels(sample, f) <= availW) {
                return f;
            }
        }
        return null;
    }

    //! Thirds grid: metrics in the top third, the chart in the middle third,
    //! metrics in the bottom third.
    //!
    //! This ignores the inscribed rectangle and lays out against the whole
    //! field, which is the point. The rectangle exists so that *one* block of
    //! content is guaranteed to be on the glass; a row of text needs only the
    //! chord at its own height, and near the middle of a round screen that
    //! chord is the full width. Working row by row is what lets the value be
    //! 105 px tall on an FR970 instead of 78, and it puts the chart in the
    //! widest part of the display rather than inset from it.
    //!
    //! Rows are packed against the *inner* edge of their third and grow
    //! outwards from there. Filling each third from its outer edge was tried
    //! first and fails on a round screen for an obvious reason once you see
    //! it: at y = 4 on a 454 px circle the glass is 73 px wide, so the row
    //! that got the top of the top third could not hold a single word. Packing
    //! inwards also puts the largest element nearest the middle, which is
    //! where the chord is widest, so the two constraints agree.
    //!
    //! Returns false if any row cannot be fitted, which hands over to the
    //! two-row layout.
    private function layoutThirds(dc as Dc) as Boolean {
        // Only for a field that *is* the screen. The grid measures against
        // the field's own height, and for anything smaller that height is not
        // where the glass is: a 240 x 140 strip on a vivoactive 3 put its top
        // row above the top of the circle.
        var screen = System.getDeviceSettings();
        if (_h * 10 < screen.screenHeight * 9 || _w * 10 < screen.screenWidth * 9) {
            return false;
        }

        var band = _h / 3;
        if (band < 6 * PAD) {
            return false;
        }
        // The two rows in a third are searched as a pair, largest first, and
        // the first combination that fits wins.
        //
        // Sizing them one at a time does not work on a round screen. The
        // value would take the largest font it can, which pushes the row above
        // it into the tip of the circle: on an FR970 a 97 px value leaves its
        // label a 167 px chord, and "DRIFTING" plus a light needs 180. Giving
        // up one font step on the value buys the label two, which is the
        // better trade and not one a greedy search can find.
        var minLine = Graphics.getFontAscent(Graphics.FONT_XTINY);
        var cap = band - 3 * PAD - minLine;

        // --- top third: label above, number below, packed upwards -------
        var valueFont = null as FontDefinition?;
        var stateFont = null as FontDefinition?;
        var valueTop = 0;
        for (var i = 0; i < NUMBER_FONTS.size() && valueFont == null; i++) {
            var vf = NUMBER_FONTS[i];
            var vAsc = Graphics.getFontAscent(vf);
            if (vAsc > cap
                || !fitsChord(dc, vf, metricSample(), band - PAD - vAsc,
                              band - PAD, false)) {
                continue;
            }
            var top = band - PAD - vAsc;
            var sf = rowFontUp(dc, TEXT_FONTS, Palette.widestLabel(),
                top - PAD, top - 2 * PAD, true);
            if (sf != null) {
                valueFont = vf;
                stateFont = sf;
                valueTop = top;
            }
        }
        if (valueFont == null || stateFont == null) {
            return false;
        }
        var stateAsc = Graphics.getFontAscent(stateFont as FontDefinition);
        var valueAsc = Graphics.getFontAscent(valueFont as FontDefinition);

        // --- bottom third: rate above load, packed downwards ------------
        //
        // The rate is capped against the value rather than the band. The rate
        // string is three times as long as the value, so at equal cap heights
        // it takes three times the ink and reads as the headline. SmO2 is the
        // headline; three quarters keeps that order without making the rate
        // small.
        var rateCap = valueAsc * 3 / 4;
        if (rateCap > cap) { rateCap = cap; }
        var rateTop = 2 * band + PAD;
        var rateFont = null as FontDefinition?;
        var capAsc = Graphics.getFontAscent(Graphics.FONT_XTINY);
        var rateSample = _showPace ? "-8.888%/s 88:88" : "-8.888%/s";
        for (var i = 0; i < TEXT_FONTS.size() && rateFont == null; i++) {
            var rf = TEXT_FONTS[i];
            var rAsc = Graphics.getFontAscent(rf);
            if (rAsc > rateCap
                || !fitsChord(dc, rf, rateSample, rateTop, rateTop + rAsc,
                              false)) {
                continue;
            }
            // The cell grid goes under the rate. Its chord is measured over
            // the whole two-line cell, so a font that only fits the caption
            // line is rejected.
            //
            // Only two cells here: MIN and MAX. A round screen has room for
            // exactly two rows in an outer third, and at three cells the
            // bottom row is 83 px of chord per cell and the numbers come out
            // at the same size they were in the gutter, which was the
            // complaint. The pace shares the rate's row instead, which is
            // wide enough for both because it sits nearer the middle.
            var cTop = rateTop + rAsc + PAD;
            if (planCells(dc, cTop, _h - PAD - cTop - capAsc, 2, true) > 0) {
                rateFont = rf;
                _rateW = chordAt(rateTop, rateTop + rAsc) - 2 * PAD;
                _paceInCells = false;
            }
        }
        if (rateFont == null) {
            return false;
        }

        // The chart takes the middle third whole, at the chord its own edges
        // allow. Both edges are the same distance from the centre line when
        // the field is the screen, so one measurement covers it.
        var chartTop = band + PAD;
        var chartBottom = 2 * band - PAD;
        // Four pads of margin either side rather than one. The axis labels
        // live at the left edge of the chart rectangle and at its vertical
        // extremes, which is the one place the chord is tightest, and at one
        // pad they sit close enough to the bezel to read as clipped.
        var chordW = chordAt(chartTop, chartBottom) - 8 * PAD;
        if (chordW < FULL_MIN_W) {
            return false;
        }

        _stateFont = stateFont;
        _valueFont = valueFont as FontDefinition;
        _rateFont = rateFont as FontDefinition;
        _dotR = stateAsc / 2;

        _stateY = valueTop - PAD - stateAsc;
        _valueY = valueTop;
        _rateY = rateTop;

        _chartX = _cx.toNumber() - chordW / 2;
        _chartY = chartTop;
        _chartW = chordW;
        _chartH = chartBottom - chartTop;
        return true;
    }

    //! Fallback: one header row and one footer row inside the usable
    //! rectangle, value beside state and rate beside load. Used where a third
    //! of the height cannot hold two rows, which is every field that is not
    //! the full screen.
    //!
    //! Always succeeds, so it is the end of the chain.
    private function layoutTwoRow(dc as Dc) as Boolean {
        var labelH = Graphics.getFontAscent(_labelFont);
        _stateFont = _labelFont;
        _rateFont = _labelFont;
        _loadFont = _labelFont;
        _dotR = labelH / 2;
        if (_dotR < 3) { _dotR = 3; }

        var stateW = dc.getTextWidthInPixels(Palette.widestLabel(), _labelFont)
                     + 2 * _dotR + PAD;
        _valueFont = largestNumberFont(dc, _uw - stateW - 3 * PAD, _uh / 3);
        // The header is as tall as the taller of the two things in it, or the
        // state label sits above the top edge wherever the value font
        // degrades below the label font.
        var vh = Graphics.getFontAscent(_valueFont);
        _headH = (vh > labelH) ? vh : labelH;

        _stateY = _uy + PAD;
        _valueY = _uy + PAD;
        _rateY = _uy + _uh - PAD - labelH;
        _loadY = _rateY;

        // The scale used to be printed in a gutter inside the chart. It is a
        // cell grid under the chart now, and this layout has no room for one,
        // so the range goes in the middle of the footer as "41-71" when the
        // rate and the load leave space for it. Without it a short chart has
        // no vertical scale at all.
        var footW = dc.getTextWidthInPixels("-8.888%/s", _labelFont)
                    + dc.getTextWidthInPixels(LOAD_SAMPLE, _labelFont)
                    + dc.getTextWidthInPixels("88-88", _labelFont)
                    + 4 * PAD;
        _showRange = footW <= _uw - 2 * PAD;
        _chartX = _ux + PAD;
        _chartY = _uy + PAD + _headH + PAD;
        _chartW = _uw - 2 * PAD;
        _chartH = _rateY - PAD - _chartY;
        if (_chartH < 20) { _chartH = 20; }
        return false;
    }

    //! Largest font from `ladder` for a row whose *bottom* edge is fixed at
    //! `bottom`, measured against the chord of glass that row would occupy.
    private function rowFontUp(dc as Dc, ladder as Array<FontDefinition>,
                               sample as String, bottom as Number,
                               maxAsc as Number,
                               withDot as Boolean) as FontDefinition? {
        for (var i = 0; i < ladder.size(); i++) {
            var f = ladder[i];
            var asc = Graphics.getFontAscent(f);
            if (asc > maxAsc || bottom - asc < 0) {
                continue;
            }
            if (fitsChord(dc, f, sample, bottom - asc, bottom, withDot)) {
                return f;
            }
        }
        return null;
    }

    //! The same for a row whose *top* edge is fixed.
    private function rowFontDown(dc as Dc, ladder as Array<FontDefinition>,
                                 sample as String, top as Number,
                                 maxAsc as Number) as FontDefinition? {
        for (var i = 0; i < ladder.size(); i++) {
            var f = ladder[i];
            var asc = Graphics.getFontAscent(f);
            if (asc > maxAsc || top + asc > _h) {
                continue;
            }
            if (fitsChord(dc, f, sample, top, top + asc, false)) {
                return f;
            }
        }
        return null;
    }

    //! Does `sample` in `font` fit the glass available between two y values?
    //! `withDot` reserves room for the state light, whose diameter tracks the
    //! font, so the width needed depends on the candidate being tested.
    private function fitsChord(dc as Dc, font as FontDefinition,
                               sample as String, yTop as Number,
                               yBot as Number, withDot as Boolean) as Boolean {
        var need = dc.getTextWidthInPixels(sample, font) + 2 * PAD;
        if (withDot) {
            need += Graphics.getFontAscent(font) + PAD;
        }
        return need <= chordAt(yTop, yBot);
    }

    //! Clear air between the light and the digits    //! Clear air between the light and the digits, proportional to the disc so
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
        var sample = metricSample();
        for (var i = 0; i < NUMBER_FONTS.size(); i++) {
            var f = NUMBER_FONTS[i];
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
        // Defaults for a rectangular screen: a centre to lay out against,
        // and _cr = 0 as the signal that there is no circle to measure.
        _cx = _w / 2.0;
        _cy = _h / 2.0;
        _cr = 0.0;

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

        // Circle, expressed in this field's own coordinates. Kept, because
        // the layout also wants to know how wide the glass is *outside* the
        // inscribed rectangle.
        _cx = screenW / 2.0 - originX;
        _cy = screenH / 2.0 - originY;
        _cr = screenW / 2.0;

        fitRectToCircle(_cx, _cy, _cr);
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

    //! Width of glass available to a full-width band between two y values.
    //!
    //! The inscribed rectangle deliberately throws away the top and bottom
    //! caps of the circle, and on a full-screen round field those caps are
    //! 60-odd pixels tall and still 200 px wide in the middle. That is more
    //! than enough for one centred line of text, and using it is what lets
    //! the value inside the rectangle have the whole width to itself.
    //!
    //! Returns the full field width on a rectangular screen, where there is
    //! no circle to measure, and 0 when the band lies off the glass entirely.
    //! Those two cases have to be told apart: conflating them as "0 means all
    //! of it" put the bottom row off the display on the Venu 3, whose
    //! full-screen field sits at x = -6, y = 5 rather than at the origin, so
    //! the circle is not centred on the field and a band that is fine on an
    //! FR970 is past the edge there.
    private function chordAt(yTop as Number, yBot as Number) as Number {
        if (_cr <= 0.0) {
            return _w;
        }
        // The binding edge is whichever is further from the centre line.
        var d1 = (yTop - _cy).abs();
        var d2 = (yBot - _cy).abs();
        var dy = (d1 > d2) ? d1 : d2;
        var rEff = _cr - 1.0;
        if (dy >= rEff) {
            return 0;
        }
        var wide = (2.0 * Math.sqrt(rEff * rEff - dy * dy)).toNumber();
        return (wide > _w) ? _w : wide;
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

    //! Full tier: the chart is the subject, with one metric above and one
    //! below it, or two of each when the screen shape allows.
    //!
    //! The session range used to be printed in the footer; it is the y axis
    //! now, which is where a range belongs. SCI is gone from the display
    //! entirely: dimensionless and hard to read in motion, and the rate says
    //! the same thing in units you can act on. It is still written to the FIT.
    private function drawFull(dc as Dc, fg as Number, bg as Number) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        var stateColor = (_dispState == STATE_UNKNOWN) ? fg : Palette.forState(_dispState);
        var stateFont = (_stateFont == null) ? _labelFont : _stateFont as FontDefinition;

        _chart.setBounds(_yAxisMode, rangeMin(), rangeMax());
        _chart.draw(dc, _chartX, _chartY, _chartW, _chartH, _dispPrediction, fg);

        var state = statusText();
        var rate = trendText();

        if (_stacked) {
            // Centred rows framing the chart, plus the cell grid under it.
            var mid = _cx.toNumber();
            drawStateRow(dc, stateColor, bg, mid,
                _stateY + Graphics.getFontAscent(stateFont) / 2, state,
                stateFont, Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mid, _valueY, _valueFont, valueText(),
                Graphics.TEXT_JUSTIFY_CENTER);

            if (_paceInCells) {
                dc.drawText(mid, _rateY, _rateFont, rate,
                    Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                // Rate and load share the row, one against each end of the
                // chord. This is the round layout: the row sits near the
                // middle of the circle and is wide enough for both, which
                // frees the row below it for MIN and MAX at a legible size.
                var l = mid - _rateW / 2;
                var r = mid + _rateW / 2;
                dc.drawText(l, _rateY, _rateFont, rate,
                    Graphics.TEXT_JUSTIFY_LEFT);
                if (_showPace) {
                    dc.setColor(_decoupled ? Palette.forState(STATE_OVERSHOOT) : fg,
                        Graphics.COLOR_TRANSPARENT);
                    dc.drawText(r, _rateY, _rateFont, _paceText,
                        Graphics.TEXT_JUSTIFY_RIGHT);
                }
            }

            drawCells(dc, fg);
            return;
        }

        var loadFont = _labelFont;
        var load = _paceText;
        if (_decoupled) {
            load += " DEC";
        }
        var loadColor = _decoupled ? Palette.forState(STATE_OVERSHOOT) : fg;

        // Two rows: value beside state, rate beside load.
        var left = _ux + PAD;
        var right = _ux + _uw - PAD;
        var headMid = _valueY + _headH / 2;

        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, headMid, _valueFont, valueText(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawStateRow(dc, stateColor, bg, right, headMid, state, stateFont,
            Graphics.TEXT_JUSTIFY_RIGHT);

        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, _rateY, _rateFont, rate, Graphics.TEXT_JUSTIFY_LEFT);

        if (_showRange) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_ux + _uw / 2, _rateY, _labelFont, rangeText(),
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        if (_showPace) {
            dc.setColor(loadColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(right, _loadY, loadFont, load, Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }

    //! The chart's vertical range as one short string, for the layout that
    //! has no room for the cell grid.
    private function rangeText() as String {
        var lo = rangeMin();
        var hi = rangeMax();
        if (lo == null || hi == null) {
            return "--";
        }
        return (lo as Float).format("%d") + "-" + (hi as Float).format("%d");
    }

    //! The cell grid under the chart: MIN, MAX and the external load, each a
    //! grey caption over the number.
    //!
    //! MIN and MAX define the vertical scale of the chart, so they used to be
    //! printed in a gutter cut out of its left edge, in the axis font. That
    //! made the two numbers the whole chart is measured against the smallest
    //! text in the field, which on an Edge is 11 px. Here they are the same
    //! size as every other metric, and the chart gets the gutter back.
    private function drawCells(dc as Dc, fg as Number) as Void {
        var capAsc = Graphics.getFontAscent(_capFont);
        var lo = rangeMin();
        var hi = rangeMax();

        for (var i = 0; i < _cells; i++) {
            var cx = _cellX + i * _cellW + _cellW / 2;
            var caption = "MIN";
            var text = (lo == null) ? "--" : (lo as Float).format("%d");
            var color = fg;
            if (i == 1) {
                caption = "MAX";
                text = (hi == null) ? "--" : (hi as Float).format("%d");
            } else if (i == 2) {
                caption = _usePower ? "PWR" : "PACE";
                text = _paceText;
                if (_decoupled) {
                    // The cell is sized once for its widest caption, so the
                    // flag cannot be a word here. Red is the flag.
                    color = Palette.forState(STATE_OVERSHOOT);
                }
            }

            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, _cellY, _capFont, caption,
                Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, _cellY + capAsc, _cellFont, text,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    //! The state light and its name, as one unit, anchored either centred on
    //! `x` or with its right edge there. The light is the same disc the
    //! chart-less tiers show, which keeps one visual vocabulary across every
    //! size of the field.
    private function drawStateRow(dc as Dc, color as Number, bg as Number,
                                  x as Number, midY as Number, text as String,
                                  font as FontDefinition,
                                  align as Number) as Void {
        var tw = dc.getTextWidthInPixels(text, font);
        var lit = _dispState != STATE_UNKNOWN && _sensorState == SENSOR_TRACKING;
        var groupW = lit ? 2 * _dotR + PAD + tw : tw;
        var x0 = (align == Graphics.TEXT_JUSTIFY_CENTER) ? x - groupW / 2 : x - groupW;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (lit) {
            dc.fillCircle(x0 + _dotR, midY, _dotR);
            if (_stateIcons) {
                StateIcon.draw(dc, x0 + _dotR, midY, _dotR, _dispState, bg);
            }
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        }
        dc.drawText(x0 + groupW - tw, midY, font, text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
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
