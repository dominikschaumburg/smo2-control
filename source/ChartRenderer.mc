//
// ChartRenderer.mc — fixed-size ring buffer plus the sparkline that draws it.
//
// The buffer is allocated once and never grows: allocating inside onUpdate()
// on a data field is the fastest route to a GC pause mid-interval.
//
// Y scaling defaults to the session range rather than 0–100 %, because in
// practice a Moxy lives between roughly 20 and 80 % — spending half the pixels
// on values that never occur throws away exactly the resolution that matters.
//
// It deliberately does NOT rescale to the visible window. Auto-zooming the last
// 90 s would make a dead-flat plateau fill the chart with what looks like wild
// oscillation, destroying the one reading the field exists to convey. A stable
// scale means flat looks flat.
//
// The area under the trace is filled with a darkened state colour. That is what
// makes the chart readable at a glance and in motion: a thin line has to be
// found, a filled shape is simply seen.
//
// Segment colours are computed here, from a window CENTRED on each segment,
// rather than taken from the live verdict. That is not a detail. A trailing
// regression over [t-60, t] estimates the slope at the centre of that window,
// t-30; painting it at t puts the colour thirty seconds to the right of the
// shape it describes. Measured on a real interval, the trace was still green
// while dropping at -0.785 %/s and still orange once the plateau had arrived.
//
// Near the live edge no centred window exists yet, so it shrinks symmetrically
// — the standard way to handle an endpoint. The newest samples are therefore
// judged from less evidence and may change colour as more arrives, which is
// honest: that is when the evidence turns up. What must never happen is a
// falling line painted green, and it no longer can.
//

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

class ChartRenderer {
    public enum YAxisMode {
        Y_WINDOW  = 0,   // follows what is on screen, with a floor
        Y_SESSION = 1,   // the whole session's range
        Y_20_80   = 2,
        Y_0_100   = 3
    }

    private const NO_DATA = -1.0;
    private const AUTO_PADDING = 3.0;    // % of headroom above/below the range

    // Floor on the visible span. This is the whole safeguard of window mode:
    // without it a dead-flat plateau is zoomed until its own noise fills the
    // chart and looks like violent oscillation. Measured across five sessions,
    // a 90 s window spans a median of 4.8 points inside a plateau and 22.5
    // through an on-transient, so 25 keeps a plateau to a fifth of the height
    // while a real desaturation still fills the frame. A floor of 12 was tried
    // first and was not nearly enough.
    private const WINDOW_MIN_SPAN = 25.0;
    private const SESSION_MIN_SPAN = 10.0;

    private var _val as Array<Float>;
    private var _st as Array<Number>;
    private var _lap as Array<Boolean>;
    private var _size as Number;
    private var _head as Number = 0;     // next write position
    private var _count as Number = 0;

    private var _pendingLap as Boolean = false;

    // Half the steady window, in samples: how far back a settled state belongs.
    private var _stateLag as Number = 0;

    // Set by the view rather than passed to draw(): Monkey C caps a method at
    // nine arguments and the signature was over it.
    private var _axisFont as Graphics.FontDefinition = Graphics.FONT_XTINY;
    private var _showAxis as Boolean = true;
    private var _yMode as Number = 0;
    private var _sessMin as Float? = null;
    private var _sessMax as Float? = null;

    // Kinetics.stateForSlope, injected so the chart does not own the
    // thresholds. Slots are one compute() tick apart, so a slope per slot is
    // already a slope per second to within the tick jitter.
    private var _classify as (Method(slope as Float) as Number)? = null;

    // Below this many samples a fit says nothing; leave the colour alone.
    private const MIN_FIT = 7;

    //! @param windowSec chart span in seconds
    //! @param steadyWindowSec regression window the states come from
    public function initialize(windowSec as Number, steadyWindowSec as Number) {
        _size = (windowSec < 10) ? 10 : windowSec;
        setStateLag(steadyWindowSec);
        _val = new Array<Float>[_size];
        _st = new Array<Number>[_size];
        _lap = new Array<Boolean>[_size];
        clear();
    }

    public function clear() as Void {
        for (var i = 0; i < _size; i++) {
            _val[i] = NO_DATA;
            _st[i] = STATE_UNKNOWN;
            _lap[i] = false;
        }
        _head = 0;
        _count = 0;
        _pendingLap = false;
    }

    //! The regression window this field's states come from. Half of it is the
    //! lag between a state and the moment it actually describes.
    public function setStateLag(steadyWindowSec as Number) as Void {
        _stateLag = steadyWindowSec / 2;
        if (_stateLag >= _size) { _stateLag = _size - 1; }
        if (_stateLag < 0) { _stateLag = 0; }
    }

    //! Push one sample. Pass null to record a gap (stale sensor), which keeps
    //! the time axis honest instead of drawing a straight line across a dropout.
    public function push(value as Float?, state as Number) as Void {
        _val[_head] = (value == null) ? NO_DATA : value as Float;
        _st[_head] = state;            // provisional, until the window catches up
        _lap[_head] = _pendingLap;
        _pendingLap = false;

        _head = (_head + 1) % _size;
        if (_count < _size) { _count++; }

        recolourTail();
    }

    //! Recompute the colour of every slot whose centred window is still
    //! growing, i.e. the newest _stateLag samples. Costs about 30 short fits
    //! per second, which is nothing, and it is the only place colours are set.
    private function recolourTail() as Void {
        if (_classify == null || _stateLag <= 0) {
            return;
        }
        var from = _count - 1 - _stateLag;
        if (from < 0) { from = 0; }
        for (var pos = from; pos < _count; pos++) {
            var st = centredState(pos);
            if (st != STATE_UNKNOWN) {
                var oldest = (_count < _size) ? 0 : _head;
                _st[(oldest + pos) % _size] = st;
            }
        }
    }

    //! Slope over the widest window centred on `pos` that the buffer holds,
    //! classified. Returns STATE_UNKNOWN when there is too little to say.
    private function centredState(pos as Number) as Number {
        var reach = _stateLag;
        if (pos < reach) { reach = pos; }
        if (_count - 1 - pos < reach) { reach = _count - 1 - pos; }
        var n = 2 * reach + 1;
        if (n < MIN_FIT) {
            return STATE_UNKNOWN;
        }

        var oldest = (_count < _size) ? 0 : _head;
        var sy = 0.0;
        var sxy = 0.0;
        var used = 0;
        for (var i = 0; i < n; i++) {
            var v = _val[(oldest + pos - reach + i) % _size];
            if (v == NO_DATA) {
                return STATE_UNKNOWN;      // a gap makes the fit meaningless
            }
            sy += v;
            sxy += i * v;
            used++;
        }
        var nf = used.toFloat();
        var sx = nf * (nf - 1.0) / 2.0;
        var sxx = (nf - 1.0) * nf * (2.0 * nf - 1.0) / 6.0;
        var den = nf * sxx - sx * sx;
        if (den == 0.0) {
            return STATE_UNKNOWN;
        }
        var cb = _classify as Method(slope as Float) as Number;
        return cb.invoke((nf * sxy - sx * sy) / den) as Number;
    }

    //! Mark the next pushed sample as a lap boundary.
    public function markLap() as Void {
        _pendingLap = true;
    }

    public function getCount() as Number { return _count; }

    public function setAxisFont(font as Graphics.FontDefinition) as Void {
        _axisFont = font;
    }

    public function setClassifier(cb as Method(slope as Float) as Number) as Void {
        _classify = cb;
    }

    //! Axis labels only earn their gutter when the plot is wide enough to
    //! spare it. In a quarter-screen field they would cost a third of the
    //! width to say what the header already says.
    public function setShowAxis(show as Boolean) as Void {
        _showAxis = show;
    }

    //! Y scaling inputs, refreshed each frame before draw().
    public function setBounds(yMode as Number, sessMin as Float?,
                              sessMax as Float?) as Void {
        _yMode = yMode;
        _sessMin = sessMin;
        _sessMax = sessMax;
    }

    //! Draw the chart into the given rectangle, with axis labels.
    //! @param prediction forecast value, marked with a needle, or null
    public function draw(dc as Graphics.Dc, x as Number, y as Number,
                         w as Number, h as Number,
                         prediction as Float?, fg as Number) as Void {
        var yMode = _yMode;
        var sessMin = _sessMin;
        var sessMax = _sessMax;
        var axisFont = _axisFont;
        if (_count < 2) {
            return;
        }

        var lo = 0.0;
        var hi = 100.0;
        if (yMode == Y_20_80) {
            lo = 20.0;
            hi = 80.0;
        } else if (yMode == Y_SESSION) {
            var b = padded(sessMin, sessMax, SESSION_MIN_SPAN);
            lo = b[0];
            hi = b[1];
        } else if (yMode == Y_WINDOW) {
            var wb = windowBounds();
            var b2 = padded(wb[0], wb[1], WINDOW_MIN_SPAN);
            lo = b2[0];
            hi = b2[1];
        }
        var span = hi - lo;
        if (span < 1.0) { span = 1.0; }

        // Reserve a gutter for the axis labels; the plot uses what is left.
        var ah = Graphics.getFontAscent(axisFont);
        var axisW = 0;
        // MIN and MAX are named, not left as two bare numbers: which end of
        // the axis is which is obvious on a chart you are staring at and not
        // at all obvious on one you glance at mid-interval.
        // Stacking the word over its number needs four line heights plus
        // clearance; laying them side by side instead costs a third more
        // gutter, and the gutter is width taken straight off the plot.
        var stackLabels = h >= 9 * ah / 2;
        var nameLabels = true;
        if (_showAxis) {
            // Measure what is actually drawn. Adding the word and the number
            // separately leaves out the space between them, and the label
            // then overhangs the gutter to the left — off the usable
            // rectangle entirely on eight of the SDK's devices.
            var numW = dc.getTextWidthInPixels("88", axisFont);
            var wordW = dc.getTextWidthInPixels("MAX", axisFont);
            if (stackLabels) {
                axisW = ((numW > wordW) ? numW : wordW) + 4;
            } else {
                axisW = dc.getTextWidthInPixels("MAX 88", axisFont) + 4;
                if (axisW > w / 4) {
                    // Short and wide: side by side, the words cost a third of
                    // the plot. The numbers are the data and the words are
                    // only a convenience, so the convenience goes first.
                    nameLabels = false;
                    axisW = numW + 4;
                }
            }
        }
        var px0 = x + axisW;
        var pw = w - axisW;
        if (pw < 20) {
            px0 = x;
            pw = w;
            axisW = 0;
        }

        var oldest = (_count < _size) ? 0 : _head;
        var stepX = pw.toFloat() / (_size - 1);
        var baseY = y + h;

        // Axis: bounds top and bottom, plus a midline for reference.
        var mid = (lo + hi) / 2.0;
        dc.setPenWidth(1);
        if (axisW > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(px0, y, px0 + pw, y);
            dc.drawLine(px0, baseY, px0 + pw, baseY);
            var midY = toY(mid, lo, span, y, h);
            dc.drawLine(px0, midY, px0 + pw, midY);

            var lx = px0 - 3;
            if (stackLabels) {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(lx, y, axisFont, "MAX", Graphics.TEXT_JUSTIFY_RIGHT);
                dc.drawText(lx, baseY - 2 * ah, axisFont, "MIN",
                    Graphics.TEXT_JUSTIFY_RIGHT);
                dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
                dc.drawText(lx, y + ah, axisFont, hi.format("%d"),
                    Graphics.TEXT_JUSTIFY_RIGHT);
                dc.drawText(lx, baseY - ah, axisFont, lo.format("%d"),
                    Graphics.TEXT_JUSTIFY_RIGHT);
            } else {
                // Too short to stack: word and number share a line, or the
                // number goes alone where the words will not fit.
                var top = nameLabels ? "MAX " + hi.format("%d") : hi.format("%d");
                var bot = nameLabels ? "MIN " + lo.format("%d") : lo.format("%d");
                dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
                dc.drawText(lx, y, axisFont, top, Graphics.TEXT_JUSTIFY_RIGHT);
                dc.drawText(lx, baseY - ah, axisFont, bot,
                    Graphics.TEXT_JUSTIFY_RIGHT);
            }
        }

        // Lap markers, under everything else.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < _count; i++) {
            var idx = (oldest + i) % _size;
            if (_lap[idx]) {
                var lx = px0 + (i * stepX).toNumber();
                dc.drawLine(lx, y, lx, baseY);
            }
        }

        // Filled area: the quad under each segment, in a darkened state
        // colour. It has to be the area under the *segment*, not a column at
        // the sample — a column sits one sample to the right of the line it
        // belongs to, and the fill visibly changes colour before the line does.
        for (var i = 1; i < _count; i++) {
            var idx = (oldest + i) % _size;
            var prevIdx = (oldest + i - 1) % _size;
            var v = _val[idx];
            var pv = _val[prevIdx];
            if (v == NO_DATA || pv == NO_DATA) {
                continue;
            }
            var xa = px0 + ((i - 1) * stepX).toNumber();
            // One pixel of overlap: adjacent quads share an edge, and on a
            // device that antialiases the seam would show as a hairline. The
            // next quad is drawn after this one, so the boundary stays put.
            var xb = px0 + (i * stepX).toNumber() + 1;
            var ya = toY(pv, lo, span, y, h);
            var yb = toY(v, lo, span, y, h);
            dc.setColor(dim(Palette.forState(_st[idx])), Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon([[xa, ya], [xb, yb], [xb, baseY], [xa, baseY]]);
        }

        // The trace itself, one coloured segment per sample pair.
        dc.setPenWidth(3);
        var prevX = 0;
        var prevY = 0;
        var havePrev = false;
        for (var i = 0; i < _count; i++) {
            var idx = (oldest + i) % _size;
            var v = _val[idx];
            if (v == NO_DATA) {
                havePrev = false;
                continue;
            }
            var cx = px0 + (i * stepX).toNumber();
            var cy = toY(v, lo, span, y, h);
            if (havePrev) {
                dc.setColor(Palette.forState(_st[idx]), Graphics.COLOR_TRANSPARENT);
                dc.drawLine(prevX, prevY, cx, cy);
            }
            prevX = cx;
            prevY = cy;
            havePrev = true;
        }

        // Forecast: a needle at the right-hand edge, pointing in at the level
        // the trend is heading to. It reads the way a dashboard pointer does,
        // which is the whole idea: a mark on the outside of the scale saying
        // where the value is going, not a data point of its own. It replaced
        // a small grey dot that sat inside the trace and read as a stray
        // sample.
        if (prediction != null && havePrev) {
            var tri = h / 8;
            if (tri < 7) { tri = 7; }
            if (tri > 20) { tri = 20; }
            var ex = px0 + pw;
            // The apex reaches into the plot; the base sits on the edge.
            var py = toY(prediction as Float, lo, span, y, h);
            var halfB = (tri * 3 / 5);
            if (py < y + halfB) { py = y + halfB; }
            if (py > baseY - halfB) { py = baseY - halfB; }

            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            dc.drawLine(prevX, prevY, ex - tri, py);

            dc.setColor(Palette.forState(newestState()), Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon([[ex, py - halfB], [ex, py + halfB], [ex - tri, py]]);
        }

        dc.setPenWidth(1);
    }

    //! Newest slot that carries a verdict. The very last samples can still be
    //! STATE_UNKNOWN — a gap, or too little either side for a centred fit —
    //! and a grey forecast marker reads as a rendering fault rather than as a
    //! projection of the trend the rest of the chart is showing.
    private function newestState() as Number {
        var oldest = (_count < _size) ? 0 : _head;
        for (var i = _count - 1; i >= 0; i--) {
            var st = _st[(oldest + i) % _size];
            if (st != STATE_UNKNOWN) { return st; }
        }
        return STATE_UNKNOWN;
    }

    //! Darken a colour to about a third, for the area fill. Done by arithmetic
    //! rather than alpha blending, which is not available on every target.
    private function dim(color as Number) as Number {
        var r = ((color >> 16) & 0xFF) * 34 / 100;
        var g = ((color >> 8) & 0xFF) * 34 / 100;
        var b = (color & 0xFF) * 34 / 100;
        return (r << 16) | (g << 8) | b;
    }

    //! Min and max of what is currently in the ring buffer.
    private function windowBounds() as Array<Float?> {
        var lo = null as Float?;
        var hi = null as Float?;
        for (var i = 0; i < _count; i++) {
            var v = _val[i];
            if (v == NO_DATA) { continue; }
            if (lo == null || v < (lo as Float)) { lo = v; }
            if (hi == null || v > (hi as Float)) { hi = v; }
        }
        return [lo, hi];
    }

    //! Pad a range and widen it to at least minSpan, clamped to 0..100.
    private function padded(lo0 as Float?, hi0 as Float?,
                            minSpan as Float) as Array<Float> {
        if (lo0 == null || hi0 == null) {
            return [20.0, 80.0];
        }
        var lo = (lo0 as Float) - AUTO_PADDING;
        var hi = (hi0 as Float) + AUTO_PADDING;
        if (hi - lo < minSpan) {
            var mid = (hi + lo) / 2.0;
            lo = mid - minSpan / 2.0;
            hi = mid + minSpan / 2.0;
        }
        if (lo < 0.0) { lo = 0.0; }
        if (hi > 100.0) { hi = 100.0; }
        return [lo, hi];
    }

    private function toY(v as Float, lo as Float, span as Float,
                         y as Number, h as Number) as Number {
        var f = (v - lo) / span;
        if (f < 0.0) { f = 0.0; }
        if (f > 1.0) { f = 1.0; }
        return y + h - (f * h).toNumber();
    }
}
