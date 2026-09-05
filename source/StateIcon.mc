//
// StateIcon.mc — the glyph inside the traffic light.
//
// Colour alone is a single channel, and about one man in twelve cannot read
// the one this field uses most. A shape inside the disc says the same thing
// through a second channel, so the light stays legible with no colour at all —
// which also means it stays legible in bright sun, through a wet screen, and
// on the greyscale MIP displays where the palette collapses anyway.
//
// The glyphs are strokes, not filled symbols, because a stroke keeps its
// identity when it is twelve pixels across and a filled symbol turns into a
// blob. They read as a family: how many chevrons, and which way up.
//
//   Zone 1   ^     recovering
//   Zone 2   —     holding
//   Zone 2+  v     drifting down
//   Zone 3   v v   still falling      (two chevrons, stacked)
//   Onset    — v   falling away from a level it just held
//
// Connect IQ has no round line caps. Drawing a filled circle at every vertex
// of the polyline gives the same result: round caps at the ends and round
// joins at the corners, at the cost of one fillCircle per point. That is what
// keeps these from looking like a debug overlay.
//
// Two details decide whether that actually reads as round on the glass, and
// both were wrong at first:
//
//   * the cap radius has to round UP. A pen of width w covers w/2 either side
//     of the line, and integer division downwards leaves the disc buried
//     inside the stroke it is meant to cap — visibly square tips, worst at
//     the small sizes where w is 2 or 3 and the error is half the stroke.
//   * the rasteriser has to be told to antialias. Without it a 12 px disc and
//     a diagonal chevron are drawn as stair steps, so there is nothing to
//     round off. smooth() turns it on where the device supports it, which is
//     everything from the fenix 5 onwards.
//

import Toybox.Graphics;
import Toybox.Lang;

module StateIcon {

    //! Below this radius a glyph is mush; the disc carries the meaning alone.
    const MIN_RADIUS = 7;

    //! Antialiasing, where the device has it. The light is the one place in
    //! the field that is all curves and diagonals, so it is the one place
    //! worth the pixels — and it is scoped rather than left on, because the
    //! chart's area fill relies on adjacent quads sharing a hard edge.
    function smooth(dc as Graphics.Dc, on as Boolean) as Void {
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(on);
        }
    }

    //! Draw the glyph for `state` centred on (cx, cy), sized to a disc of
    //! radius r, in `color`. Does nothing if the disc is too small to hold it.
    function draw(dc as Graphics.Dc, cx as Number, cy as Number, r as Number,
                  state as Number, color as Number) as Void {
        if (r < MIN_RADIUS) {
            return;
        }

        // Stroke weight against disc size. A third of the radius is heavy
        // enough to survive a MIP panel and light enough that a chevron still
        // has a visible notch at 7 px.
        var w = r / 3;
        if (w < 2) { w = 2; }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(w);

        // Everything is laid out in a unit box and scaled by the radius, so
        // one set of proportions serves every field size.
        // Rounded, not truncated. At the small radii truncation costs a whole
        // pixel of rise, and a chevron whose apex travels one pixel is a
        // straight line with a bump in it.
        var half = (r * 0.44 + 0.5).toNumber();   // half-width of a chevron
        var rise = (r * 0.26 + 0.5).toNumber();   // how far the apex travels
        if (half < 2) { half = 2; }
        if (rise < 1) { rise = 1; }

        switch (state) {
            case STATE_REOXY:
                chevron(dc, cx, cy, half, -rise, w);
                break;

            case STATE_STEADY:
                stroke(dc, cx - half, cy, cx + half, cy, w);
                break;

            case STATE_CONTROL:
                chevron(dc, cx, cy, half, rise, w);
                break;

            case STATE_OVERSHOOT:
                // Two chevrons, one above the other. Both elements have to
                // live inside the same disc as the single-element glyphs, so
                // they are drawn smaller and lighter — at full size the top
                // one runs out through the edge of the circle and the glyph
                // reads as damaged rather than as emphatic.
                chevron(dc, cx, cy - pairGap(w), pairHalf(half), pairRise(rise),
                    pairPen(w));
                chevron(dc, cx, cy + pairGap(w), pairHalf(half), pairRise(rise),
                    pairPen(w));
                break;

            case STATE_ONKIN:
                // A bar with a chevron falling away from it: the level it was
                // holding, and the drop off it. One straight element keeps it
                // apart from the double chevron at a glance.
                var sep = pairGap(w);
                var ph = pairHalf(half);
                stroke(dc, cx - ph, cy - sep, cx + ph, cy - sep, pairPen(w));
                chevron(dc, cx, cy + sep, ph, pairRise(rise), pairPen(w));
                break;
        }

        dc.setPenWidth(1);
    }

    // Proportions for the two-element glyphs. Kept as one place so the pair
    // stays inside the disc at every radius.
    function pairPen(w as Number) as Number {
        var p = w * 3 / 4;
        return (p < 2) ? 2 : p;
    }

    function pairHalf(half as Number) as Number {
        var h = half * 85 / 100;
        return (h < 2) ? 2 : h;
    }

    function pairRise(rise as Number) as Number {
        var r = rise * 7 / 10;
        return (r < 1) ? 1 : r;
    }

    function pairGap(w as Number) as Number {
        var g = w;
        return (g < 2) ? 2 : g;
    }

    //! One straight stroke with round caps.
    function stroke(dc as Graphics.Dc, x1 as Number, y1 as Number,
                    x2 as Number, y2 as Number, w as Number) as Void {
        dc.drawLine(x1, y1, x2, y2);
        cap(dc, x1, y1, w);
        cap(dc, x2, y2, w);
    }

    //! A chevron centred on (cx, cy). Positive `rise` points the apex down.
    function chevron(dc as Graphics.Dc, cx as Number, cy as Number,
                     half as Number, rise as Number, w as Number) as Void {
        var x1 = cx - half;
        var x2 = cx + half;
        var yEnd = cy - rise;
        var yTip = cy + rise;
        dc.drawLine(x1, yEnd, cx, yTip);
        dc.drawLine(cx, yTip, x2, yEnd);
        cap(dc, x1, yEnd, w);
        cap(dc, cx, yTip, w);        // the join, rounded like the caps
        cap(dc, x2, yEnd, w);
    }

    //! A round cap or join: a disc of the stroke's own diameter. The radius
    //! rounds up — see the header — and never below 1, or the thinnest
    //! strokes lose their caps altogether and end in a corner.
    function cap(dc as Graphics.Dc, x as Number, y as Number, w as Number) as Void {
        var r = (w + 1) / 2;
        if (r < 1) { r = 1; }
        dc.fillCircle(x, y, r);
    }
}
