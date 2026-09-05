//
// SmO2FitContributor.mc — writes the derived metrics into the running activity.
//
// Record fields carry the real-time signal, lap fields carry the per-interval
// summary so the post-session analysis in Garmin Connect comes for free.
// setData() is only called when a value actually changed, which keeps smart
// recording from inflating the FIT file.
//
// The Control Index is a LAP field, in two forms. It used to be a record field
// computed as |slope| / session range, which was a mistake twice over: it
// changed every second, so it never answered a question anyone asks, and its
// denominator was the relaxing session range, so the same effort scored
// differently depending on what had happened earlier in the session. What the
// index is meant to measure is the amplitude of one interval's desaturation,
// which is a property of the interval and can only be known when the interval
// ends.
//

import Toybox.FitContributor;
import Toybox.Lang;

class SmO2FitContributor {
    enum FieldId {
        FIELD_SMO2       = 0,
        FIELD_TREND      = 1,
        FIELD_STATE      = 3,
        FIELD_THB        = 4,
        FIELD_LAP_RATE   = 5,
        FIELD_LAP_MIN    = 6,
        FIELD_LAP_MAX    = 7,
        FIELD_LAP_ONKIN  = 9,
        FIELD_SESS_AVG   = 8,
        FIELD_LAP_SCI    = 10,
        FIELD_LAP_SCI_R  = 11
    }

    private var _smo2Field as Field;
    private var _trendField as Field;
    private var _stateField as Field;
    private var _thbField as Field;
    private var _lapRateField as Field;
    private var _lapMinField as Field;
    private var _lapMaxField as Field;
    private var _lapOnKinField as Field;
    private var _lapSciField as Field;
    private var _lapSciRatioField as Field;
    private var _sessAvgField as Field;

    // Last written values, so we can skip redundant setData() calls.
    private var _lastSmo2 as Float = -1.0;
    private var _lastTrend as Float = -99.0;
    private var _lastState as Number = -1;
    private var _lastThb as Float = -1.0;

    public function initialize(df as SmO2ControlView) {
        _smo2Field = df.createField("smo2", FIELD_SMO2, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });
        _trendField = df.createField("smo2Trend", FIELD_TREND, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%/s" });
        _stateField = df.createField("smo2State", FIELD_STATE, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "" });
        _thbField = df.createField("thb", FIELD_THB, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "g/dl" });

        _lapRateField = df.createField("lapDesatRate", FIELD_LAP_RATE, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "%/s" });
        _lapMinField = df.createField("lapSmo2Min", FIELD_LAP_MIN, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "%" });
        _lapMaxField = df.createField("lapSmo2Max", FIELD_LAP_MAX, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "%" });

        _lapOnKinField = df.createField("lapOnKinRate", FIELD_LAP_ONKIN, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "%/s" });

        // Two units for one measurement: the drop in percentage points, and
        // the same drop as a fraction of the level it started from. Which of
        // the two tracks lactate better across step lengths is an open
        // question, so both are recorded and the answer can come from data.
        _lapSciField = df.createField("lapSciDrop", FIELD_LAP_SCI, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "%" });
        _lapSciRatioField = df.createField("lapSciRatio", FIELD_LAP_SCI_R, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "" });

        _sessAvgField = df.createField("avgSmo2", FIELD_SESS_AVG, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "%" });

        _smo2Field.setData(0.0);
        _trendField.setData(0.0);
        _stateField.setData(0);
        _thbField.setData(0.0);
    }

    //! Called once per compute() tick with the current derived values.
    public function compute(smo2 as Float?, trend as Float,
                            state as Number, thb as Float?) as Void {
        if (smo2 != null && (smo2 as Float) != _lastSmo2) {
            _lastSmo2 = smo2 as Float;
            _smo2Field.setData(_lastSmo2);
        }
        if (trend != _lastTrend) {
            _lastTrend = trend;
            _trendField.setData(trend);
        }
        if (state != _lastState) {
            _lastState = state;
            _stateField.setData(state);
        }
        if (thb != null && (thb as Float) != _lastThb) {
            _lastThb = thb as Float;
            _thbField.setData(_lastThb);
        }
    }

    //! Write the closing statistics of the lap that just ended.
    public function onLap(stats as Dictionary<Symbol, Float>?) as Void {
        if (stats == null) {
            return;
        }
        _lapRateField.setData(stats[:rate] as Float);
        _lapMinField.setData(stats[:min] as Float);
        _lapMaxField.setData(stats[:max] as Float);
        _lapOnKinField.setData(stats[:onKin] as Float);
        _lapSciField.setData(stats[:sciDrop] as Float);
        _lapSciRatioField.setData(stats[:sciRatio] as Float);
    }

    public function setSessionAverage(avg as Float?) as Void {
        if (avg != null) {
            _sessAvgField.setData(avg as Float);
        }
    }
}
