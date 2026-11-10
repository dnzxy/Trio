import Foundation
import G6SensorCore
import G6SensorKit
import LoopKit
import Testing

@testable import Trio

// The simulator's stand-in session first touches state ~5 s after init; every test finishes before that.

private typealias NativeG6Manager = G6SensorKit.G6CGMManager

private enum G6Fixture {
    static let transmitterID = "8GSYN1"

    static func state(
        passive: Bool = false,
        slot: TransmitterSlot = .default,
        anubis: Bool = false,
        _ configure: (inout G6CGMManagerState) -> Void = { _ in }
    ) -> G6CGMManagerState {
        var state = G6CGMManagerState(
            transmitterID: transmitterID,
            passiveModeEnabled: passive,
            transmitterSlot: slot,
            transmitterExpiryInDays: anubis ? 180 : 90,
            isOnboarded: true
        )
        configure(&state)
        return state
    }

    static func reading(at date: Date, mgdL: Double = 120) -> G6StoredReading {
        G6StoredReading(
            date: date,
            glucoseMgDL: mgdL,
            trendRateMgDLPerMinute: 0.5,
            isDisplayOnly: false,
            syncIdentifier: "synthetic-\(Int(date.timeIntervalSince1970))",
            calibrationStateRawValue: 6
        )
    }

    /// The export as the watch receives it: through a binary property list, without its time (AppleWatchManager).
    static func wire(_ configuration: SharedDeviceConfiguration) throws -> SharedDeviceConfiguration {
        let sent = SharedDeviceConfiguration(
            managerIdentifier: configuration.managerIdentifier,
            asOf: .distantPast,
            state: configuration.state
        )
        let data = try PropertyListSerialization.data(fromPropertyList: sent.rawValue, format: .binary, options: 0)
        let raw = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(SharedDeviceConfiguration(rawValue: raw))
    }

    /// The watch rebuilds only when this differs (WatchCGMHost compares the states as NSDictionary).
    static func wireState(of manager: NativeG6Manager) throws -> NSDictionary {
        try wire(manager.exportConfiguration()).state as NSDictionary
    }

    static func watchSlot(of manager: NativeG6Manager) throws -> TransmitterSlot {
        let state = try #require(G6CGMManagerState(rawValue: wire(manager.exportConfiguration()).state))
        return state.transmitterSlot
    }

    static func adopted(from phone: NativeG6Manager) throws -> NativeG6Manager {
        try #require(NativeG6Manager(adopting: wire(phone.exportConfiguration()), localState: nil))
    }
}

// MARK: - Watch slot

@Suite("G6SensorKit: watch slot") struct G6WatchSlotTests {
    @Test("Stock transmitter, phone on the default slot: the watch takes the receiver slot") func stockDefault() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        #expect(phone.state.effectiveTransmitterSlot == .phoneApp)
        #expect(try G6Fixture.watchSlot(of: phone) == .receiverOrPump)
    }

    @Test("Stock transmitter, phone on the receiver slot: the watch takes the phone app slot") func stockReceiver() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(slot: .receiverOrPump))
        #expect(try G6Fixture.watchSlot(of: phone) == .phoneApp)
    }

    @Test("Anubis, phone on the default slot: the watch takes the Anubis extra slot") func anubisDefault() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(anubis: true))
        #expect(try G6Fixture.watchSlot(of: phone) == .anubisExtra)
    }

    @Test("Anubis, phone on the receiver slot: the watch takes the Anubis extra slot") func anubisReceiver() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(slot: .receiverOrPump, anubis: true))
        #expect(try G6Fixture.watchSlot(of: phone) == .anubisExtra)
    }

    @Test("Anubis, phone on the Anubis extra slot: the watch takes the receiver slot") func anubisExtra() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(slot: .anubisExtra, anubis: true))
        #expect(phone.state.effectiveTransmitterSlot == .anubisExtra)
        #expect(try G6Fixture.watchSlot(of: phone) == .receiverOrPump)
    }

    @Test("Anubis slot stored on a transmitter not known to be Anubis resolves to the default") func anubisSlotOnStock() throws {
        let unknown = NativeG6Manager(state: G6Fixture.state(slot: .anubisExtra) { $0.transmitterExpiryInDays = nil })
        #expect(unknown.state.effectiveTransmitterSlot == .phoneApp)
        #expect(try G6Fixture.watchSlot(of: unknown) == .receiverOrPump)
    }

    @Test("Passive mode: the Dexcom app's slot counts as the phone's, whatever slot is stored") func passive() throws {
        for slot in TransmitterSlot.allCases {
            let stock = NativeG6Manager(state: G6Fixture.state(passive: true, slot: slot))
            #expect(try G6Fixture.watchSlot(of: stock) == .receiverOrPump, "stock, stored slot \(slot)")

            let anubis = NativeG6Manager(state: G6Fixture.state(passive: true, slot: slot, anubis: true))
            #expect(try G6Fixture.watchSlot(of: anubis) == .anubisExtra, "Anubis, stored slot \(slot)")
        }
    }

    @Test("The watch never shares the phone's slot and only takes one the transmitter accepts") func neverThePhonesSlot() throws {
        for slot in TransmitterSlot.allCases {
            for anubis in [false, true] {
                for passive in [false, true] {
                    let state = G6Fixture.state(passive: passive, slot: slot, anubis: anubis)
                    let phoneSlot = passive ? TransmitterSlot.phoneApp : state.effectiveTransmitterSlot
                    let watch = try G6Fixture.watchSlot(of: NativeG6Manager(state: state))
                    let context = "stored \(slot), anubis \(anubis), passive \(passive)"
                    #expect(watch != phoneSlot, "\(context)")
                    #expect(TransmitterSlot.available(isAnubis: anubis).contains(watch), "\(context)")
                    #expect(watch == state.secondaryTransmitterSlot, "\(context)")
                    if anubis, phoneSlot != .anubisExtra {
                        #expect(watch == .anubisExtra, "\(context)")
                    }
                }
            }
        }
    }

    @Test("A 110-day transmitter is not Anubis") func nonStandardLifetime() throws {
        let phone = NativeG6Manager(state: G6Fixture.state { $0.transmitterExpiryInDays = 110 })
        #expect(!phone.state.isAnubis)
        #expect(try G6Fixture.watchSlot(of: phone) == .receiverOrPump)
    }
}

// MARK: - Export

@Suite("G6SensorKit: watch export") struct G6WatchExportTests {
    @Test("The export names the plugin and carries only what the watch needs") func exportContents() throws {
        let start = Date().addingTimeInterval(-.hours(30))
        let phone = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.peripheralIdentifier = UUID()
            $0.transmitterStartDate = start.addingTimeInterval(-.hours(24 * 20))
            $0.sensorStartDate = start
            $0.sensorCode = "5915"
            $0.sensorLifeDays = 14
            $0.latestReading = G6Fixture.reading(at: Date())
            $0.recentReadings = [G6Fixture.reading(at: Date())]
            $0.firmwareVersion = "1.2.3.4"
            $0.shareUploadEnabled = true
            $0.watchDirectReadEnabled = true
            $0.algorithmStateRawValue = 6
            $0.batteryVoltageA = 300
            $0.batteryVoltageB = 290
            $0.lastBatteryReadDate = Date()
            $0.pendingCommands = [Command.stopSensor(at: Date()).rawValue]
        })

        let export = phone.exportConfiguration()
        #expect(export.managerIdentifier == "G6SensorKit")
        #expect(export.managerIdentifier == phone.pluginIdentifier)

        let local = [
            "peripheralIdentifier", "transmitterStartDate", "sensorStartDate", "sensorCode", "latestReading",
            "recentReadings", "firmwareVersion", "shareUploadEnabled", "watchDirectReadEnabled", "algorithmState",
            "batteryVoltageA", "batteryVoltageB", "lastBatteryReadDate", "pendingCommands", "setupStep",
            "undeliveredCommand", "lastSessionStartFailure"
        ]
        for key in local {
            #expect(export.state[key] == nil, "\(key) is local to the phone and must not be exported")
        }

        let shared = try #require(G6CGMManagerState(rawValue: G6Fixture.wire(export).state))
        #expect(shared.transmitterID == G6Fixture.transmitterID)
        #expect(shared.transmitterExpiryInDays == 180)
        #expect(shared.sensorLifeDays == 14)
        #expect(shared.transmitterSlot == .anubisExtra)
        #expect(shared.configuredByAnotherController)
        #expect(shared.isOnboarded)
        #expect(!shared.passiveModeEnabled)
    }

    @Test("Re-read dates, readings, battery and local settings leave the export unchanged")  func stableAcrossLocalChanges() throws {
        let baseline = NativeG6Manager(state: G6Fixture.state(anubis: true))
        let now = Date()
        let churned = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.transmitterStartDate = now.addingTimeInterval(-.hours(24 * 20) + 1)
            $0.sensorStartDate = now.addingTimeInterval(-.hours(30) + 1)
            $0.latestReading = G6Fixture.reading(at: now)
            $0.recentReadings = [G6Fixture.reading(at: now.addingTimeInterval(-300)), G6Fixture.reading(at: now)]
            $0.batteryVoltageA = 301
            $0.batteryVoltageB = 289
            $0.batteryResistance = 700
            $0.batteryRuntimeDays = 20
            $0.batteryTemperature = 30
            $0.lastBatteryReadDate = now
            $0.peripheralIdentifier = UUID()
            $0.firmwareVersion = "1.2.3.4"
            $0.sensorCode = "5915"
            $0.algorithmStateRawValue = 6
            $0.shareUploadEnabled = true
            $0.shouldSyncToRemoteService = false
            $0.watchDirectReadEnabled = true
        })
        #expect(try G6Fixture.wireState(of: baseline) == G6Fixture.wireState(of: churned))
    }

    @Test("Turning Read on Apple Watch on or off leaves the export unchanged") func stableAcrossSharingToggle() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        let before = try G6Fixture.wireState(of: phone)
        phone.setWatchDirectReadEnabled(true)
        #expect(try before == G6Fixture.wireState(of: phone))
    }

    @Test("Changing the phone's slot changes the export") func changesWithSlot() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        let before = try G6Fixture.wireState(of: phone)
        phone.setTransmitterSlot(.receiverOrPump)
        #expect(try before != G6Fixture.wireState(of: phone))
        #expect(try G6Fixture.watchSlot(of: phone) == .phoneApp)
    }

    @Test("Switching passive mode changes the export when it moves the watch's slot") func changesWithPassiveMode() throws {
        let stock = NativeG6Manager(state: G6Fixture.state(slot: .receiverOrPump))
        let direct = try G6Fixture.wireState(of: stock)
        stock.setPassiveModeEnabled(true)
        #expect(try direct != G6Fixture.wireState(of: stock))
        #expect(try G6Fixture.watchSlot(of: stock) == .receiverOrPump)

        let anubis = NativeG6Manager(state: G6Fixture.state(slot: .anubisExtra, anubis: true))
        let anubisDirect = try G6Fixture.wireState(of: anubis)
        anubis.setPassiveModeEnabled(true)
        #expect(try anubisDirect != G6Fixture.wireState(of: anubis))
        #expect(try G6Fixture.watchSlot(of: anubis) == .anubisExtra)
    }

    @Test("Switching passive mode on the default slot keeps the watch's slot and export") func passiveOnDefaultSlot() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        let direct = try G6Fixture.wireState(of: phone)
        phone.setPassiveModeEnabled(true)
        #expect(try G6Fixture.watchSlot(of: phone) == .receiverOrPump)
        #expect(try direct == G6Fixture.wireState(of: phone))
    }

    @Test("Replacing the transmitter changes the export") func changesWithTransmitterID() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        let before = try G6Fixture.wireState(of: phone)
        phone.replaceTransmitter(id: "8GSYN2")
        let after = try G6Fixture.wireState(of: phone)
        #expect(before != after)
        #expect(after["transmitterID"] as? String == "8GSYN2")
    }

    @Test("Detecting Anubis changes the export and moves the watch to the extra slot") func changesWithAnubisDetection() throws {
        let unknown = NativeG6Manager(state: G6Fixture.state { $0.transmitterExpiryInDays = nil })
        let anubis = NativeG6Manager(state: G6Fixture.state(anubis: true))
        #expect(try G6Fixture.wireState(of: unknown) != G6Fixture.wireState(of: anubis))
        #expect(try G6Fixture.watchSlot(of: unknown) == .receiverOrPump)
        #expect(try G6Fixture.watchSlot(of: anubis) == .anubisExtra)
    }
}

// MARK: - Adopting an export

@Suite("G6SensorKit: adopting an export") struct G6AdoptionTests {
    @Test("An adopted manager reads directly, onboarded, on the exported slot") func adoptedState() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(passive: true, anubis: true) {
            $0.sensorLifeDays = 14
            $0.transmitterStartDate = Date().addingTimeInterval(-.hours(24 * 20))
            $0.sensorStartDate = Date().addingTimeInterval(-.hours(30))
            $0.peripheralIdentifier = UUID()
            $0.watchDirectReadEnabled = true
        })
        let watch = try G6Fixture.adopted(from: phone)

        #expect(watch.isOnboarded)
        #expect(watch.state.configuredByAnotherController)
        #expect(!watch.state.passiveModeEnabled)
        #expect(watch.state.transmitterID == G6Fixture.transmitterID)
        #expect(watch.state.transmitterSlot == .anubisExtra)
        #expect(watch.state.effectiveTransmitterSlot == .anubisExtra)
        #expect(watch.state.transmitterExpiryInDays == 180)
        #expect(watch.state.sensorLifeDays == 14)
        #expect(watch.state.transmitterStartDate == nil)
        #expect(watch.state.sensorStartDate == nil)
        #expect(watch.state.peripheralIdentifier == nil)
        #expect(watch.state.setupStep == nil)
        #expect(!watch.state.watchDirectReadEnabled)
        #expect(!watch.isConfigurationSharingEnabled)
        #expect(watch.pluginIdentifier == "G6SensorKit")
    }

    @Test("A stock phone's watch adopts the receiver slot") func adoptedStockSlot() throws {
        let watch = try G6Fixture.adopted(from: NativeG6Manager(state: G6Fixture.state()))
        #expect(watch.state.transmitterSlot == .receiverOrPump)
        #expect(watch.state.effectiveTransmitterSlot == .receiverOrPump)
    }

    @Test("An adopted manager drops every command") func adoptedDropsCommands() throws {
        let watch = try G6Fixture.adopted(from: NativeG6Manager(state: G6Fixture.state()))
        let code = try #require(SensorCode("5915"))
        let commands: [Command] = [
            .startSensor(at: Date(), sensorCode: code),
            .startSensor(at: Date(), sensorCode: .none),
            .stopSensor(at: Date()),
            .calibrateSensor(toMgDL: 120, at: Date()),
            .resetTransmitter
        ]
        for command in commands {
            watch.enqueue(command)
            watch.enqueue(command, notifyIfUndelivered: true)
        }
        #expect(watch.state.pendingCommands.isEmpty)
        #expect(watch.state.sensorCode == nil)
        #expect(watch.state.sensorStartDate == nil)
        #expect(watch.state.undeliveredCommand == nil)
    }

    @Test("An adopted manager restored from its rawState is still another controller's") func adoptedSurvivesRelaunch() throws {
        let watch = try G6Fixture.adopted(from: NativeG6Manager(state: G6Fixture.state(anubis: true)))
        let raw = try PropertyListSerialization.data(fromPropertyList: watch.rawState, format: .binary, options: 0)
        let decoded = try #require(PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])
        let restored = try #require(NativeG6Manager(rawState: decoded))

        #expect(restored.state == watch.state)
        #expect(restored.state.configuredByAnotherController)
        #expect(restored.state.effectiveTransmitterSlot == .anubisExtra)
        restored.enqueue(.stopSensor(at: Date()))
        #expect(restored.state.pendingCommands.isEmpty)
    }

    @Test("Anything that is not a G6 export is refused") func refusesNonExports() throws {
        let plainState = NativeG6Manager(state: G6Fixture.state()).rawState
        let legacy: [String: Any] = ["transmitterID": G6Fixture.transmitterID, "transmitterStartDate": Date()]
        let g7Shaped: [String: Any] = ["sensorID": "DXCMS1", "configuredByAnotherController": true]
        let cases: [(String, [String: Any])] = [
            ("a phone's own rawState", plainState),
            ("a CGMBLEKit state", legacy),
            ("a G7-shaped state", g7Shaped),
            ("an empty state", [:])
        ]
        for (name, state) in cases {
            let configuration = SharedDeviceConfiguration(managerIdentifier: "G6SensorKit", asOf: Date(), state: state)
            #expect(NativeG6Manager(adopting: configuration, localState: nil) == nil, "\(name)")
        }
    }
}

// MARK: - Sharing toggle

@Suite("G6SensorKit: Read on Apple Watch setting") struct G6SharingToggleTests {
    @Test("Sharing is off by default and follows the setting") func followsSetting() {
        let phone = NativeG6Manager(state: G6Fixture.state())
        #expect(!phone.isConfigurationSharingEnabled)

        phone.setWatchDirectReadEnabled(true)
        #expect(phone.isConfigurationSharingEnabled)
        #expect(phone.state.watchDirectReadEnabled)
        #expect(phone.rawState["watchDirectReadEnabled"] as? Bool == true)

        phone.setWatchDirectReadEnabled(false)
        #expect(!phone.isConfigurationSharingEnabled)
        #expect(phone.rawState["watchDirectReadEnabled"] == nil)
    }

    @Test("The setting survives a relaunch") func survivesRelaunch() throws {
        let phone = NativeG6Manager(state: G6Fixture.state())
        phone.setWatchDirectReadEnabled(true)
        let restored = try #require(NativeG6Manager(rawState: phone.rawState))
        #expect(restored.isConfigurationSharingEnabled)
    }
}

// MARK: - Persistence

@Suite("G6SensorKit: rawState") struct G6RawStateTests {
    @Test("A fully populated state round-trips through a property list") func roundTrip() throws {
        let now = Date()
        var state = G6Fixture.state(passive: false, slot: .anubisExtra, anubis: true) {
            $0.peripheralIdentifier = UUID()
            $0.transmitterStartDate = now.addingTimeInterval(-.hours(24 * 20))
            $0.sensorStartDate = now.addingTimeInterval(-.hours(30))
            $0.sensorCode = "5915"
            $0.sensorLifeDays = 14
            $0.latestReading = G6Fixture.reading(at: now)
            $0.recentReadings = [G6Fixture.reading(at: now.addingTimeInterval(-300)), G6Fixture.reading(at: now)]
            $0.firmwareVersion = "1.2.3.4"
            $0.shareUploadEnabled = true
            $0.setupStep = .warmup
            $0.algorithmStateRawValue = 6
            $0.pendingCommands = [Command.stopSensor(at: now).rawValue]
            $0.lastSessionStartFailure = "synthetic failure"
            $0.batteryVoltageA = 300
            $0.batteryVoltageB = 290
            $0.batteryResistance = 700
            $0.batteryRuntimeDays = 20
            $0.batteryTemperature = 30
            $0.lastBatteryReadDate = now
        }
        state.configuredByAnotherController = true
        state.watchDirectReadEnabled = true

        let data = try PropertyListSerialization.data(fromPropertyList: state.rawValue, format: .binary, options: 0)
        let raw = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let decoded = try #require(G6CGMManagerState(rawValue: raw))
        #expect(decoded == state)
        #expect(decoded.configuredByAnotherController)
        #expect(decoded.watchDirectReadEnabled)
        #expect(decoded.transmitterSlot == .anubisExtra)
        #expect(decoded.transmitterExpiryInDays == 180)
    }

    @Test("Flags and defaults are left out of rawState") func sparseKeys() {
        let raw = G6CGMManagerState(transmitterID: G6Fixture.transmitterID).rawValue
        for key in [
            "configuredByAnotherController", "watchDirectReadEnabled", "transmitterSlot", "isOnboarded",
            "shareUploadEnabled", "pendingCommands", "recentReadings"
        ] {
            #expect(raw[key] == nil, "\(key) should be omitted when false or default")
        }
        #expect(raw["passiveModeEnabled"] as? Bool == false)
        #expect(raw["sensorLifeDays"] as? Int == TransmitterManagerState.defaultSensorLifeDays)
    }

    @Test("Each slot persists as its raw byte; an unknown byte falls back to the default") func slotPersistence() {
        for slot in TransmitterSlot.allCases where slot != .default {
            let raw = G6CGMManagerState(transmitterID: G6Fixture.transmitterID, transmitterSlot: slot).rawValue
            #expect(raw["transmitterSlot"] as? Int == Int(slot.rawValue))
            #expect(G6CGMManagerState(rawValue: raw)?.transmitterSlot == slot)
        }
        for bad in [0, 4, 255, 256, -1] {
            let raw: [String: Any] = ["transmitterID": G6Fixture.transmitterID, "sensorLifeDays": 10, "transmitterSlot": bad]
            #expect(G6CGMManagerState(rawValue: raw)?.transmitterSlot == .default, "slot \(bad)")
        }
    }

    @Test("Persisted readings are capped at the most recent twelve") func readingsCap() throws {
        let now = Date()
        let readings = (0 ..< 20).map { G6Fixture.reading(at: now.addingTimeInterval(TimeInterval($0 * 300))) }
        let state = G6Fixture.state { $0.recentReadings = readings }
        let decoded = try #require(G6CGMManagerState(rawValue: state.rawValue))
        #expect(decoded.recentReadings == Array(readings.suffix(12)))
    }

    @Test("A CGMBLEKit-shaped state migrates to passive mode, onboarded") func legacyMigration() throws {
        let activation = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [UInt32(86400) as Any, 86400 as Any] {
            let legacy: [String: Any] = [
                "transmitterID": G6Fixture.transmitterID,
                "transmitterStartDate": activation,
                "sensorStartOffset": offset,
                "shouldSyncToRemoteService": false
            ]
            let state = try #require(G6CGMManagerState(rawValue: legacy))
            #expect(state.passiveModeEnabled)
            #expect(state.isOnboarded)
            #expect(state.sensorStartDate == activation.addingTimeInterval(86400))
            #expect(!state.shouldSyncToRemoteService)
            #expect(state.transmitterSlot == .default)
            #expect(!state.configuredByAnotherController)
            #expect(!state.watchDirectReadEnabled)
        }
    }

    @Test("A G6SensorKit state is not mistaken for a CGMBLEKit one") func notLegacy() throws {
        let fresh = G6CGMManagerState(transmitterID: G6Fixture.transmitterID).rawValue
        let state = try #require(G6CGMManagerState(rawValue: fresh))
        #expect(!state.passiveModeEnabled)
        #expect(!state.isOnboarded)

        let onlyLife: [String: Any] = ["transmitterID": G6Fixture.transmitterID, "sensorLifeDays": 10]
        #expect(G6CGMManagerState(rawValue: onlyLife)?.passiveModeEnabled == false)
        let onlyMode: [String: Any] = ["transmitterID": G6Fixture.transmitterID, "passiveModeEnabled": false]
        #expect(G6CGMManagerState(rawValue: onlyMode)?.isOnboarded == false)
    }

    @Test("A state without a transmitter ID is refused") func missingID() {
        #expect(G6CGMManagerState(rawValue: ["sensorLifeDays": 10]) == nil)
        #expect(NativeG6Manager(rawState: [:]) == nil)
    }
}

// MARK: - Status

@Suite("G6SensorKit: inoperable and signal loss") struct G6StatusTests {
    private static let day: TimeInterval = .hours(24)

    @Test("A fresh transmitter is neither inoperable nor in signal loss") func fresh() {
        let manager = NativeG6Manager(state: G6CGMManagerState(transmitterID: G6Fixture.transmitterID))
        #expect(!manager.isInoperable)
        #expect(!manager.inSignalLoss)
        #expect(!manager.cgmManagerStatus.isInoperable)
    }

    @Test("A transmitter past its reported lifetime is inoperable once its session has ended") func expiredTransmitter() {
        let expired = NativeG6Manager(state: G6Fixture.state {
            $0.transmitterStartDate = Date().addingTimeInterval(-91 * Self.day)
        })
        #expect(expired.isInoperable)
        #expect(expired.cgmManagerStatus.isInoperable)

        let stillReading = NativeG6Manager(state: G6Fixture.state {
            $0.transmitterStartDate = Date().addingTimeInterval(-91 * Self.day)
            $0.sensorStartDate = Date().addingTimeInterval(-3 * Self.day)
        })
        #expect(!stillReading.isInoperable)

        let live = NativeG6Manager(state: G6Fixture.state {
            $0.transmitterStartDate = Date().addingTimeInterval(-89 * Self.day)
        })
        #expect(!live.isInoperable)

        let anubis = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.transmitterStartDate = Date().addingTimeInterval(-150 * Self.day)
        })
        #expect(!anubis.isInoperable)
    }

    @Test("An old transmitter whose lifetime is not yet known is not called expired") func unknownLifetime() {
        let manager = NativeG6Manager(state: G6Fixture.state {
            $0.transmitterExpiryInDays = nil
            $0.transmitterStartDate = Date().addingTimeInterval(-170 * Self.day)
        })
        #expect(!manager.isInoperable)
    }

    @Test("A failed sensor is inoperable", arguments: [UInt8(11), 12, 15, 16, 17]) func failedSensor(raw: UInt8) {
        let manager = NativeG6Manager(state: G6Fixture.state { $0.algorithmStateRawValue = raw })
        #expect(manager.isInoperable)
        #expect(manager.state.isSensorFailed)
    }

    @Test(
        "Other sensor states are not a failure",
        arguments: [UInt8(1), 2, 4, 6, 7, 8, 13, 14, 18, 99]
    )  func notFailed(raw: UInt8) {
        let manager = NativeG6Manager(state: G6Fixture.state { $0.algorithmStateRawValue = raw })
        #expect(!manager.isInoperable)
        #expect(!manager.state.isSensorFailed)
    }

    @Test("A session past its length is inoperable") func expiredSession() {
        let stockExpired = NativeG6Manager(state: G6Fixture.state {
            $0.sensorStartDate = Date().addingTimeInterval(-10 * Self.day - 60)
        })
        #expect(stockExpired.isInoperable)

        let stockRunning = NativeG6Manager(state: G6Fixture.state {
            $0.sensorStartDate = Date().addingTimeInterval(-9 * Self.day)
        })
        #expect(!stockRunning.isInoperable)

        let stockLong = NativeG6Manager(state: G6Fixture.state {
            $0.sensorLifeDays = 14
            $0.sensorStartDate = Date().addingTimeInterval(-11 * Self.day)
        })
        #expect(stockLong.isInoperable)

        let anubisLong = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.sensorLifeDays = 14
            $0.sensorStartDate = Date().addingTimeInterval(-11 * Self.day)
        })
        #expect(!anubisLong.isInoperable)

        let anubisDone = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.sensorLifeDays = 14
            $0.sensorStartDate = Date().addingTimeInterval(-14 * Self.day - 60)
        })
        #expect(anubisDone.isInoperable)
    }

    @Test("Signal loss needs a session past warm-up and a reading older than 20 minutes") func signalLoss() {
        let now = Date()
        func manager(started: Date?, lastReading: Date?) -> NativeG6Manager {
            NativeG6Manager(state: G6Fixture.state {
                $0.sensorStartDate = started
                $0.latestReading = lastReading.map { G6Fixture.reading(at: $0) }
            })
        }
        let pastWarmup = now.addingTimeInterval(-.hours(3))
        let inWarmup = now.addingTimeInterval(-.hours(1))

        #expect(manager(started: pastWarmup, lastReading: now.addingTimeInterval(-.minutes(21))).inSignalLoss)
        #expect(!manager(started: pastWarmup, lastReading: now.addingTimeInterval(-.minutes(19))).inSignalLoss)
        #expect(!manager(started: inWarmup, lastReading: now.addingTimeInterval(-.minutes(45))).inSignalLoss)
        #expect(!manager(started: nil, lastReading: now.addingTimeInterval(-.hours(2))).inSignalLoss)
        #expect(!manager(started: pastWarmup, lastReading: nil).inSignalLoss)
    }

    @Test("Anubis warm-up is shorter, so signal loss can start sooner") func anubisWarmup() {
        let now = Date()
        let manager = NativeG6Manager(state: G6Fixture.state(anubis: true) {
            $0.sensorStartDate = now.addingTimeInterval(-.hours(1))
            $0.latestReading = G6Fixture.reading(at: now.addingTimeInterval(-.minutes(21)))
        })
        #expect(!manager.state.isInWarmup)
        #expect(manager.inSignalLoss)
    }
}

// MARK: - Trio integration

@Suite("Trio: native G6 integration") struct G6TrioIntegrationTests {
    @Test("The catalog offers the native driver under its own identifier") func catalogEntry() throws {
        let entry = try #require(DeviceCatalog.cgmEntry(id: NativeG6Manager.pluginIdentifier))
        #expect(entry.id == "G6SensorKit")
        #expect(entry.cgmType == .plugin)
        #expect(entry.manufacturer == .dexcom)
        #expect(entry.name == "Dexcom G6 / ONE (native)")
        #expect(entry.isSelectableInPicker)
        let type = try #require(entry.managerType)
        #expect(ObjectIdentifier(type) == ObjectIdentifier(NativeG6Manager.self))
        #expect(DeviceCatalog.cgmManagerEntries.contains { $0.id == "G6SensorKit" })

        let legacy = try #require(DeviceCatalog.cgmEntry(id: "DexG6Transmitter"))
        #expect(legacy.managerType.map { ObjectIdentifier($0) } != ObjectIdentifier(NativeG6Manager.self))
    }

    @Test("A saved native G6 is restored as the native manager from its catalog type") func restoresFromCatalog() throws {
        let phone = NativeG6Manager(state: G6Fixture.state(slot: .receiverOrPump))
        phone.setWatchDirectReadEnabled(true)
        let type = try #require(DeviceCatalog.cgmEntry(id: phone.pluginIdentifier)?.managerType)
        let restored = try #require(type.init(rawState: phone.rawState) as? NativeG6Manager)
        #expect(restored.state == phone.state)
        #expect(restored.isConfigurationSharingEnabled)
    }

    @Test("Direct mode owns its alerts; passive mode leaves them to the Dexcom app") func alertOwnership() throws {
        let direct = NativeG6Manager(state: G6Fixture.state())
        #expect(CGMManagerAlertOwnership.owningApp(manager: direct, sourceType: .plugin) == nil)
        #expect(!CGMManagerAlertOwnership.providesOwnGlucoseAlerts(manager: direct, sourceType: .plugin))

        let passive = NativeG6Manager(state: G6Fixture.state(passive: true))
        let app = try #require(CGMManagerAlertOwnership.owningApp(manager: passive, sourceType: .plugin))
        #expect(app.name == "Dexcom G6 / One")
        #expect(app.deepLink == URL(string: "dexcomg6://"))
        #expect(CGMManagerAlertOwnership.providesOwnGlucoseAlerts(manager: passive, sourceType: .plugin))

        direct.setPassiveModeEnabled(true)
        #expect(CGMManagerAlertOwnership.owningApp(manager: direct, sourceType: .plugin) != nil)
        passive.setPassiveModeEnabled(false)
        #expect(CGMManagerAlertOwnership.owningApp(manager: passive, sourceType: .plugin) == nil)
    }

    @Test("A watch-style adopted manager owns its alerts too") func adoptedAlertOwnership() throws {
        let watch = try G6Fixture.adopted(from: NativeG6Manager(state: G6Fixture.state(passive: true)))
        #expect(CGMManagerAlertOwnership.owningApp(manager: watch, sourceType: .plugin) == nil)
    }

    @Test("Exported logs redact the transmitter ID and Bluetooth identifier") func redaction() {
        let peripheral = UUID(uuidString: "8C1D2E3F-0000-4000-8000-00000000AB12")!
        let manager = NativeG6Manager(state: G6Fixture.state { $0.peripheralIdentifier = peripheral })
        var values = SensitiveValues()
        values.add(manager)
        let redactor = Redactor(exactValues: values.values)
        #expect(
            redactor.redact("Transmitter 8GSYN1 connected at \(peripheral.uuidString)") ==
                "Transmitter <cgm-serial-1> connected at <device-1>"
        )
    }
}
