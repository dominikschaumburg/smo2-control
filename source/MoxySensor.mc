//
// MoxySensor.mc — ANT+ Muscle Oxygen link via Ant.GenericChannel.
//
// SmO2/THb never made it into the native Activity.Info sensor API, so the data
// field has to own the ANT channel itself. Consequence for the user: the Moxy
// must NOT also be paired natively in the watch's sensor list — one sensor can
// only hold one channel, and whoever grabs it first blocks the other.
//
// Channel constants (device type 31, period 8192, RF 57) are taken from the
// official Connect IQ MoxyField sample.
//
// Reopening after a lost or never-found sensor is deliberately SLOW. A watch
// has one 2.4 GHz radio and ANT shares it with BLE; streaming music to
// headphones is the heaviest and most latency-sensitive thing that radio does,
// and a searching ANT channel keeps its receiver on almost continuously.
//
// The first version reopened the instant the channel closed, so a Moxy that
// was switched off, asleep, out of range or already claimed by the watch's own
// sensor list left this field searching for the entire activity. That is the
// worst possible neighbour for BLE audio, and it showed up as headphone
// dropouts that did not happen without the field. The backoff below turns a
// permanent search into 25 seconds in every 85 once it settles, without ever
// giving up: the sensor may be switched on halfway through a ride and has to
// be found when it is. Simulated over ten minutes with no sensor present it is
// 42 % of the time searching against 100 % before.
//

import Toybox.Ant;
import Toybox.Lang;
import Toybox.System;

//! ANT+ Muscle Oxygen Data Page
const MO2_PAGE_DATA = 1;

//! Link state of the sensor, surfaced to the view.
enum SensorState {
    SENSOR_SEARCHING = 0,   // channel open, no broadcast yet
    SENSOR_TRACKING  = 1,   // fresh data arriving
    SENSOR_STALE     = 2,   // paired but eventCount frozen
    SENSOR_CLOSED    = 3    // channel closed / never opened
}

//! Seconds without a new event count before the reading is considered stale.
const STALE_TIMEOUT_MS = 5000;

//! Reopen backoff after the search times out: doubling from 2 s to a 60 s
//! ceiling. Six attempts land inside the first two minutes, which covers the
//! ordinary case of starting the activity before the sensor is awake, and
//! only a genuinely absent sensor ever reaches the ceiling. The ceiling is a
//! ceiling and not a give-up on purpose, so switching the Moxy on mid-ride
//! still works.
const REOPEN_MIN_MS = 2000;
const REOPEN_MAX_MS = 60000;

class MoxySensor extends Ant.GenericChannel {
    private const DEVICE_TYPE = 31;
    private const PERIOD = 8192;

    // Profile-defined invalid markers, checked on the *raw* fields before scaling.
    private const THB_AMBIENT = 0xFFE;
    private const THB_INVALID = 0xFFF;
    private const SMO2_AMBIENT = 0x3FE;
    private const SMO2_INVALID = 0x3FF;

    private var _chanAssign as ChannelAssignment;
    private var _deviceCfg as DeviceConfig;

    private var _open as Boolean = false;
    private var _searching as Boolean = true;
    private var _eventCount as Number = -1;
    private var _lastEventMs as Number = 0;

    // Latest decoded sample. null means "no valid value" — never 0.
    private var _smo2 as Float? = null;
    private var _thb as Float? = null;
    private var _pairedDeviceNumber as Number = 0;

    // Deferred reopen. Timed by subtraction from _closedAtMs rather than
    // against an absolute deadline, because System.getTimer() wraps.
    private var _reopenPending as Boolean = false;
    private var _closedAtMs as Number = 0;
    private var _backoffMs as Number = $.REOPEN_MIN_MS;

    //! @param deviceNumber ANT device number, 0 = wildcard search
    public function initialize(deviceNumber as Number) {
        _chanAssign = new Ant.ChannelAssignment(Ant.CHANNEL_TYPE_RX_NOT_TX, Ant.NETWORK_PLUS);
        GenericChannel.initialize(method(:onMessage), _chanAssign);

        _deviceCfg = new Ant.DeviceConfig({
            :deviceNumber             => deviceNumber,
            :deviceType               => DEVICE_TYPE,
            :transmissionType         => 0,
            :messagePeriod            => PERIOD,
            :radioFrequency           => 57,
            :searchTimeoutLowPriority => 10,   // stay in low-priority search
            :searchThreshold          => 0
        });
        GenericChannel.setDeviceConfig(_deviceCfg);
    }

    public function open() as Boolean {
        _open = GenericChannel.open();
        _searching = true;
        _reopenPending = false;
        _eventCount = -1;
        _lastEventMs = System.getTimer();
        return _open;
    }

    //! Called once per compute() tick. Performs a reopen that has come due.
    //!
    //! Reopening here rather than inside onMessage() is the point: the ANT
    //! callback should decode and return, and a channel reopened from it
    //! happens at whatever rate the radio produces events. Once per second is
    //! precise enough for a backoff measured in seconds.
    public function tick() as Void {
        if (!_reopenPending) {
            return;
        }
        if (System.getTimer() - _closedAtMs < _backoffMs) {
            return;
        }

        // Grow the wait for the attempt after this one, before making it. An
        // attempt that finds nothing and an attempt the radio refuses cost
        // the same, so they back off the same way.
        _backoffMs = _backoffMs * 2;
        if (_backoffMs > $.REOPEN_MAX_MS) {
            _backoffMs = $.REOPEN_MAX_MS;
        }

        if (!open()) {
            // Refused, most likely because something else holds the sensor:
            // the watch's own sensor list, or another field. Keep trying on
            // the same schedule rather than never again, because whatever
            // holds it may let go. The old code gave up here silently.
            _reopenPending = true;
            _closedAtMs = System.getTimer();
        }
    }

    public function closeSensor() as Void {
        if (_open) {
            GenericChannel.close();
            _open = false;
        }
        _reopenPending = false;
        _smo2 = null;
        _thb = null;
    }

    //! ANT callback. Runs off the render loop — it only decodes and stores.
    //! Deliberately no Ui.requestUpdate() here: compute() polls at ~1 Hz.
    public function onMessage(msg as Message) as Void {
        // getPayload() allocates — call it exactly once per message.
        var payload = msg.getPayload();

        if (Ant.MSG_ID_BROADCAST_DATA == msg.messageId) {
            if ($.MO2_PAGE_DATA == (payload[0].toNumber() & 0xFF)) {
                if (_searching) {
                    _searching = false;
                    _deviceCfg = GenericChannel.getDeviceConfig();
                    _pairedDeviceNumber = _deviceCfg.deviceNumber;
                    // Found it: the next dropout starts its own backoff from
                    // the bottom rather than inheriting this one's ceiling.
                    _backoffMs = $.REOPEN_MIN_MS;
                }
                parse(payload);
            }
        } else if (Ant.MSG_ID_CHANNEL_RESPONSE_EVENT == msg.messageId) {
            if (Ant.MSG_ID_RF_EVENT == (payload[0] & 0xFF)) {
                var code = payload[1] & 0xFF;
                if (Ant.MSG_CODE_EVENT_CHANNEL_CLOSED == code) {
                    // Search timed out or the sensor went away. Schedule the
                    // reopen instead of doing it here; see the header.
                    _smo2 = null;
                    _thb = null;
                    _open = false;
                    _reopenPending = true;
                    _closedAtMs = System.getTimer();
                } else if (Ant.MSG_CODE_EVENT_RX_FAIL_GO_TO_SEARCH == code) {
                    _searching = true;
                    _smo2 = null;
                    _thb = null;
                }
            }
        }
    }

    //! Decode Muscle Oxygen Data Page 1.
    //! Invalid/ambient codes yield null rather than a misleading 0 %.
    private function parse(payload as Array<Number>) as Void {
        var count = payload[1] & 0xFF;
        if (count != _eventCount) {
            _eventCount = count;
            _lastEventMs = System.getTimer();
        }

        var rawThb = (payload[4] & 0xFF) | ((payload[5] & 0x0F) << 8);
        _thb = (rawThb >= THB_AMBIENT) ? null : rawThb / 100.0;

        var rawSmo2 = ((payload[6] & 0xFF) >> 6) | ((payload[7] & 0xFF) << 2);
        _smo2 = (rawSmo2 >= SMO2_AMBIENT) ? null : rawSmo2 / 10.0;
    }

    //! Current link state, including stale detection.
    public function getState() as SensorState {
        if (!_open) {
            // A pending reopen still counts as searching. From the athlete's
            // side the field is looking for the sensor; it is only declining
            // to hold the radio open while it waits.
            return _reopenPending ? SENSOR_SEARCHING : SENSOR_CLOSED;
        }
        if (_searching || _eventCount < 0) { return SENSOR_SEARCHING; }
        if (System.getTimer() - _lastEventMs > $.STALE_TIMEOUT_MS) { return SENSOR_STALE; }
        return SENSOR_TRACKING;
    }

    //! Latest valid SmO2 in %, or null when invalid/stale/unpaired.
    public function getSmO2() as Float? {
        return (getState() == SENSOR_TRACKING) ? _smo2 : null;
    }

    //! Latest valid total haemoglobin in g/dl, or null.
    public function getTHb() as Float? {
        return (getState() == SENSOR_TRACKING) ? _thb : null;
    }

    public function getDeviceNumber() as Number {
        return _pairedDeviceNumber;
    }
}
