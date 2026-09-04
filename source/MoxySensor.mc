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
        _eventCount = -1;
        _lastEventMs = System.getTimer();
        return _open;
    }

    public function closeSensor() as Void {
        if (_open) {
            GenericChannel.close();
            _open = false;
        }
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
                }
                parse(payload);
            }
        } else if (Ant.MSG_ID_CHANNEL_RESPONSE_EVENT == msg.messageId) {
            if (Ant.MSG_ID_RF_EVENT == (payload[0] & 0xFF)) {
                var code = payload[1] & 0xFF;
                if (Ant.MSG_CODE_EVENT_CHANNEL_CLOSED == code) {
                    // Search timed out or the sensor went away — reopen.
                    _smo2 = null;
                    _thb = null;
                    open();
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
        if (!_open) { return SENSOR_CLOSED; }
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
