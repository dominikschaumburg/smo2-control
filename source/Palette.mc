//
// Palette.mc — state colours, in a normal and a colour-blind safe variant.
//
// The default scheme is the intuitive traffic-light mapping. The colour-blind
// variant swaps the red/green axis for a blue/magenta axis, which stays
// distinguishable under deuteranopia and protanopia.
//

import Toybox.Graphics;
import Toybox.Lang;

module Palette {

    var colorBlind as Boolean = false;

    //! Colour for a kinetic state, used for both the sparkline segments and
    //! the compact-tier background.
    function forState(state as Number) as Number {
        if (colorBlind) {
            switch (state) {
                case STATE_REOXY:     return 0x00AAFF;   // cyan
                case STATE_STEADY:    return 0xFFFFFF;   // white
                case STATE_ONKIN:     return 0x7B5CFF;   // violet
                case STATE_CONTROL:   return 0xFFAA00;   // amber
                case STATE_OVERSHOOT: return 0xFF00AA;   // magenta
            }
            return Graphics.COLOR_DK_GRAY;
        }
        switch (state) {
            case STATE_REOXY:     return 0x00AAFF;       // blue
            case STATE_STEADY:    return 0x00C853;       // green
            case STATE_ONKIN:     return 0xFF8A00;       // orange, transient
            case STATE_CONTROL:   return 0xFFD600;       // yellow
            case STATE_OVERSHOOT: return 0xFF3B30;       // red
        }
        return Graphics.COLOR_DK_GRAY;
    }

    //! Short label for the state, for tiers that have room for text.
    function labelForState(state as Number) as String {
        switch (state) {
            case STATE_REOXY:     return "REOXY";
            case STATE_STEADY:    return "STEADY";
            case STATE_ONKIN:     return "ON-KIN";
            case STATE_CONTROL:   return "CONTROL";
            case STATE_OVERSHOOT: return "OVER";
        }
        return "--";
    }

    //! Trend arrow, chosen from the slope relative to the steady threshold.
    function arrowForState(state as Number) as String {
        switch (state) {
            case STATE_REOXY:     return "^";
            case STATE_STEADY:    return "=";
            case STATE_ONKIN:     return "vv";
            case STATE_CONTROL:   return "v";
            case STATE_OVERSHOOT: return "vvv";
        }
        return "-";
    }
}
