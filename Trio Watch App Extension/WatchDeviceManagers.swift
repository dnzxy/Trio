import G6SensorKit
import G7SensorKit
import LoopKit

// The CGMs the watch can read itself, built from the phone's exported configuration (as LoopKit/Loop#2545's
// WatchDeviceManagers). The one place the watch names a device kit: a further CGM needs a kit that builds for watchOS
// and implements `DeviceConfigurationSharing`, an entry in `watchCGMManagersByIdentifier` and a `WatchReadableCGM`
// extension below.

/// What the watch shows and does with a CGM it reads itself.
protocol WatchReadableCGM: CGMManager & DeviceConfigurationSharing {
    /// Posted when anything below changes.
    static var statusDidChange: Notification.Name { get }
    /// Shown in place of the minutes under the glucose bubble: why the link brings no readings (a code, a search).
    var watchLinkStateText: String? { get }
    /// Shown in place of the minutes under the glucose bubble: the sensor's own state (warmup, expired).
    var watchSensorStateText: String? { get }
    /// The sensor itself needs a look: the yellow triangle in the glucose bubble.
    var watchHasSensorProblem: Bool { get }
    /// A pairing that watchOS only lets through with Trio on the screen (its Bluetooth pairing request shows only
    /// then), as for a sensor the phone has just paired.
    var watchNeedsAppInFront: Bool { get }
    /// A wake that is not the sensor's own: its acquisition re-checks itself.
    func recheckAcquisition()
}

/// Keyed by each manager's `pluginIdentifier`, which is what its export carries. Stated, as Trio's device catalog
/// does: LoopKit exposes it only per instance.
let watchCGMManagersByIdentifier: [String: any WatchReadableCGM.Type] = [
    "G6SensorKit": G6CGMManager.self,
    "G7CGMManager": G7CGMManager.self
]

/// A CGM manager built from another controller's export and this watch's saved `localState`.
func watchCGMManager(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> (any WatchReadableCGM)? {
    watchCGMManagersByIdentifier[configuration.managerIdentifier]?.init(adopting: configuration, localState: localState)
}

/// A CGM manager restored from its saved `managerIdentifier` and `state`.
func watchCGMManager(rawValue: [String: Any]) -> (any WatchReadableCGM)? {
    guard let identifier = rawValue["managerIdentifier"] as? String,
          let rawState = rawValue["state"] as? CGMManager.RawStateValue else { return nil }
    return watchCGMManagersByIdentifier[identifier]?.init(rawState: rawState)
}

extension G7CGMManager: WatchReadableCGM {
    var watchLinkStateText: String? {
        if needsCodeForSensor != nil { return String(localized: "Sensor code needed") }
        if isSearchingForSensor { return String(localized: "Pairing the sensor: keep Trio open") }
        return nil
    }

    var watchSensorStateText: String? {
        switch lifecycleState {
        case .warmup: return String(localized: "Sensor warmup")
        case .failed: return String(localized: "Sensor failed")
        case .gracePeriod: return String(localized: "Sensor grace period")
        case .expired: return String(localized: "Sensor expired")
        default: return nil
        }
    }

    /// Searching is for a sensor the watch has never connected to: a new one.
    var watchNeedsAppInFront: Bool { isSearchingForSensor }

    var watchHasSensorProblem: Bool {
        switch lifecycleState {
        case .expired,
             .failed,
             .gracePeriod,
             .warmup: return true
        default: return false
        }
    }
}

extension G6CGMManager: WatchReadableCGM {
    var watchLinkStateText: String? {
        switch connectionPhase {
        case .awaitingPairing: return String(localized: "Pairing the transmitter: keep Trio open")
        case .searching where !isPaired: return String(localized: "Searching for the transmitter")
        default: return nil
        }
    }

    var watchSensorStateText: String? {
        if state.isTransmitterExpired { return String(localized: "Transmitter expired") }
        if state.isSensorFailed { return String(localized: "Sensor failed") }
        guard state.sensorStartDate != nil else { return nil }
        if state.isInWarmup { return String(localized: "Sensor warmup") }
        if let expiration = state.sensorExpirationDate, expiration <= Date() { return String(localized: "Sensor expired") }
        return nil
    }

    /// A bond request waits on watchOS's pairing prompt, which shows only with Trio on the screen.
    var watchNeedsAppInFront: Bool { connectionPhase == .awaitingPairing }

    var watchHasSensorProblem: Bool { watchSensorStateText != nil }
}

extension DeviceManager {
    /// What the watch saves, as the phone saves a manager: `managerIdentifier` and `state`.
    var watchRawValue: [String: Any] {
        ["managerIdentifier": pluginIdentifier, "state": rawState]
    }
}
