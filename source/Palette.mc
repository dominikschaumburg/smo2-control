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

    //! Which vocabulary the state labels use. Plain behaviour words are the
    //! default: they name what was actually measured, in language that needs
    //! no glossary.
    //!
    //! Zone numbers were tried here and removed. Two reasons, and either is
    //! enough. The watch already owns the word "zone" for its own five heart
    //! rate and seven power zones, so this field saying ZONE 2 beside a heart
    //! rate field saying Zone 4 is worse than saying nothing. And the deeper
    //! problem: a zone is a statement about intensity, while this field
    //! measures a slope. A plateau occurs below LT1 and at threshold alike,
    //! so no mapping from slope to zone number can be correct. Zones need the
    //! athlete's own oxygenation breakpoints, which the field does not have.
    var plainLabels as Boolean = true;

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
    //!   RECOVER   SmO2 rising: supply exceeds demand
    //!   HOLDING   a plateau: a sustainable steady state
    //!   DRIFTING  a slow decline: demanding, still controlled
    //!   FALLING   the decline continues: no steady state exists here
    //!   ONSET     the on-transient at the start of an effort
    //!
    //! The kinetic terms are the alternative, for readers who want the names
    //! the literature uses.
    function labelForState(state as Number) as String {
        if (plainLabels) {
            switch (state) {
                case STATE_REOXY:     return "RECOVER";
                case STATE_STEADY:    return "HOLDING";
                case STATE_ONKIN:     return "ONSET";
                case STATE_CONTROL:   return "DRIFTING";
                case STATE_OVERSHOOT: return "FALLING";
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
        return plainLabels ? "DRIFTING" : "CONTROL";
    }

}
