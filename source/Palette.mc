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

    //! Which vocabulary the state labels use. Zone names are the default: an
    //! athlete already thinks in the three-zone model, and a label that maps
    //! onto it is acted on faster than one that names the measurement.
    var zoneLabels as Boolean = true;

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
    //!
    //! The zone vocabulary maps the kinetics onto the three-zone (moderate /
    //! heavy / severe) model. The mapping is by behaviour, not by absolute
    //! intensity, and that is the honest reading of what is measured:
    //!
    //!   SmO2 recovering under load  -> supply exceeds demand      -> Zone 1
    //!   SmO2 holding a plateau      -> a sustainable steady state -> Zone 2
    //!   SmO2 drifting slowly down   -> at the upper boundary      -> Zone 2+
    //!   SmO2 still falling          -> no steady state exists     -> Zone 3
    //!
    //! Zone 1 and Zone 2 both plateau, so the field cannot tell an easy run
    //! from a threshold run by kinetics alone — what it can tell is whether
    //! the current effort has settled, which is the question being asked.
    //! ONSET is the on-transient and belongs to no zone.
    function labelForState(state as Number) as String {
        if (zoneLabels) {
            switch (state) {
                case STATE_REOXY:     return "ZONE 1";
                case STATE_STEADY:    return "ZONE 2";
                case STATE_ONKIN:     return "ONSET";
                case STATE_CONTROL:   return "ZONE 2+";
                case STATE_OVERSHOOT: return "ZONE 3";
            }
            return "--";
        }
        switch (state) {
            case STATE_REOXY:     return "REOXY";
            case STATE_STEADY:    return "STEADY";
            case STATE_ONKIN:     return "ON-KIN";
            case STATE_CONTROL:   return "CONTROL";
            case STATE_OVERSHOOT: return "OVER";
        }
        return "--";
    }

    //! Widest label the current vocabulary can produce. Used to reserve space
    //! once in onLayout() rather than reflowing when the state changes.
    function widestLabel() as String {
        return zoneLabels ? "ZONE 2+" : "CONTROL";
    }

}
