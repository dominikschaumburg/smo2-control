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

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

class ChartRenderer {
    public enum YAxisMode {
        Y_AUTO  = 0,
        Y_20_80 = 1,
        Y_0_100 = 2
    }

    private const NO_DATA = -1.0;
    private const AUTO_PADDING = 3.0;    // % of headroom above/below the range
    private const AUTO_MIN_SPAN = 10.0;  // never zoom in tighter than this

    private var _val as Array<Float>;
    private var _st as Array<Number>;
    private var _lap as Array<Boolean>;
    private var _size as Number;
    private var _head as Number = 0;     // next write position
    private var _count as Number = 0;

    private var _pendingLap as Boolean = false;

    public function initialize(windowSec as Number) {
        _size = (windowSec < 10) ? 10 : windowSec;
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

    //! Push one sample. Pass null to record a gap (stale sensor), which keeps
    //! the time axis honest instead of drawing a straight line across a dropout.
    public function push(value as Float?, state as Number) as Void {
        _val[_head] = (value == null) ? NO_DATA : value as Float;
        _st[_head] = state;
        _lap[_head] = _pendingLap;
        _pendingLap = false;
        _head = (_head + 1) % _size;
        if (_count < _size) { _count++; }
    }

    //! Mark the next pushed sample as a lap boundary.
    public function markLap() as Void {
        _pendingLap = true;
    }

    public function getCount() as Number { return _count; }

    //! Draw the sparkline into the given rectangle.
    //! @param prediction forecast value, drawn as a ghost marker, or null
    public function draw(dc as Graphics.Dc, x as Number, y as Number,
                         w as Number, h as Number,
                         yMode as Number, sessMin as Float?, sessMax as Float?,
                         prediction as Float?) as Void {
        if (_count < 2) {
            return;
        }

        var lo = 0.0;
        var hi = 100.0;
        if (yMode == Y_20_80) {
            lo = 20.0;
            hi = 80.0;
        } else if (yMode == Y_AUTO) {
            var bounds = autoBounds(sessMin, sessMax);
            lo = bounds[0];
            hi = bounds[1];
        }
        var span = hi - lo;
        if (span < 1.0) { span = 1.0; }

        // Oldest sample first, so the newest ends up at the right edge.
        var oldest = (_count < _size) ? 0 : _head;
        var stepX = w.toFloat() / (_size - 1);

        // Session min/max reference bands.
        if (yMode == Y_AUTO && sessMin != null && sessMax != null) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            var yMinPx = toY(sessMin as Float, lo, span, y, h);
            var yMaxPx = toY(sessMax as Float, lo, span, y, h);
            dc.drawLine(x, yMinPx, x + w, yMinPx);
            dc.drawLine(x, yMaxPx, x + w, yMaxPx);
        }

        // Lap markers first, so the trace draws on top of them.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < _count; i++) {
            var idx = (oldest + i) % _size;
            if (_lap[idx]) {
                var lx = x + (i * stepX).toNumber();
                dc.drawLine(lx, y, lx, y + h);
            }
        }

        // The trace, one coloured segment per sample pair.
        dc.setPenWidth(2);
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
            var px = x + (i * stepX).toNumber();
            var py = toY(v, lo, span, y, h);
            if (havePrev) {
                dc.setColor(Palette.forState(_st[idx]), Graphics.COLOR_TRANSPARENT);
                dc.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
            havePrev = true;
        }

        // Forecast marker at the right edge.
        if (prediction != null && havePrev) {
            var py = toY(prediction as Float, lo, span, y, h);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(1);
            dc.drawLine(prevX, prevY, x + w, py);
            dc.fillCircle(x + w - 1, py, 2);
        }

        dc.setPenWidth(1);
    }

    //! Auto y bounds: the session range with padding, widened to AUTO_MIN_SPAN.
    private function autoBounds(sessMin as Float?, sessMax as Float?) as Array<Float> {
        if (sessMin == null || sessMax == null) {
            return [20.0, 80.0];
        }
        var lo = (sessMin as Float) - AUTO_PADDING;
        var hi = (sessMax as Float) + AUTO_PADDING;
        var span = hi - lo;
        if (span < AUTO_MIN_SPAN) {
            var mid = (hi + lo) / 2.0;
            lo = mid - AUTO_MIN_SPAN / 2.0;
            hi = mid + AUTO_MIN_SPAN / 2.0;
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
