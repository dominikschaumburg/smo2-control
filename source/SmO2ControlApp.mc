//
// SmO2ControlApp.mc — owns the ANT channel for the lifetime of the app.
//
// Acquiring the channel can fail when something else on the watch already holds
// it — most commonly the Moxy being paired natively in the watch's sensor list.
// In that case we run without a sensor and the field says so, rather than
// crashing out of the activity.
//

import Toybox.Ant;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class SmO2ControlApp extends Application.AppBase {

    private var _sensor as MoxySensor?;
    private var _view as SmO2ControlView?;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        var deviceNumber = 0;
        var configured = Application.Properties.getValue("moxyDeviceNumber");
        if (configured instanceof Number) {
            deviceNumber = configured;
        }

        try {
            _sensor = new MoxySensor(deviceNumber);
            (_sensor as MoxySensor).open();
        } catch (e instanceof Ant.UnableToAcquireChannelException) {
            System.println("ANT channel unavailable: " + e.getErrorMessage());
            _sensor = null;
        }
    }

    public function onStop(state as Dictionary?) as Void {
        var sensor = _sensor;
        if (sensor != null) {
            sensor.closeSensor();
        }
    }

    public function onSettingsChanged() as Void {
        var view = _view;
        if (view != null) {
            view.onSettingsChanged();
        }
        WatchUi.requestUpdate();
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new $.SmO2ControlView(_sensor);
        _view = view;
        return [view];
    }
}
