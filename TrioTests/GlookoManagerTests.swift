import Foundation
import LoopKit
import Testing

@testable import Trio

/// Tests for what `BaseGlookoManager` builds before handing a pump snapshot to GlookoServiceKit.
@Suite("Glooko Manager Tests") struct GlookoManagerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 25 * 60) // 25 min past a UTC hour

    private func bolus(
        _ date: Date,
        amount: Decimal = 1.5,
        programmed: Decimal? = nil,
        isSMB: Bool? = false,
        isExternal: Bool? = false
    ) -> PumpHistoryEvent {
        PumpHistoryEvent(
            id: "bolus-\(date.timeIntervalSince1970)",
            type: .bolus,
            timestamp: date,
            amount: amount,
            isSMB: isSMB,
            isExternal: isExternal,
            programmedAmount: programmed
        )
    }

    // MARK: - Snapshot window

    @Test("Window starts at the lookback when pending events are recent") func testWindowUsesLookback() {
        let start = BaseGlookoManager.snapshotStart(pending: [bolus(now.addingTimeInterval(-600))], now: now)
        let expected = Date(timeIntervalSince1970: 1_800_000_000 - 6 * 3600)
        #expect(start == expected)
    }

    @Test("Window reaches back to the oldest pending event") func testWindowCoversOldestPending() {
        let oldest = now.addingTimeInterval(-10 * 3600)
        let start = BaseGlookoManager.snapshotStart(pending: [bolus(now), bolus(oldest)], now: now)

        #expect(start <= oldest)
        #expect(oldest.timeIntervalSince(start) < 3600)
    }

    @Test("Window start is aligned to a whole UTC hour") func testWindowHourAligned() {
        let start = BaseGlookoManager.snapshotStart(pending: [bolus(now.addingTimeInterval(-7 * 3600 - 17 * 60))], now: now)
        #expect(start.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0)
    }

    // MARK: - Bolus mapping

    @Test("A pump bolus keeps its id, delivered and programmed amounts") func testBolusDoseFields() throws {
        let event = bolus(now, amount: 0.8, programmed: 1.0)
        let dose = try #require(BaseGlookoManager.bolusDose(event))

        #expect(dose.type == .bolus)
        #expect(dose.syncIdentifier == event.id)
        #expect(dose.deliveredUnits == 0.8)
        #expect(dose.programmedUnits == 1.0)
        #expect(dose.startDate == now)
        #expect(dose.isMutable == false)
    }

    @Test("Programmed amount falls back to the delivered amount") func testBolusProgrammedFallback() throws {
        let dose = try #require(BaseGlookoManager.bolusDose(bolus(now, amount: 2, programmed: nil)))
        #expect(dose.programmedUnits == 2)
    }

    @Test("SMBs are automatic, manual boluses are not") func testBolusAutomaticFlag() throws {
        #expect(try #require(BaseGlookoManager.bolusDose(bolus(now, isSMB: true))).automatic == true)
        #expect(try #require(BaseGlookoManager.bolusDose(bolus(now, isSMB: false))).automatic == false)
    }

    @Test("External insulin is not sent as a pump bolus") func testExternalInsulinSkipped() {
        #expect(BaseGlookoManager.bolusDose(bolus(now, isExternal: true)) == nil)
    }

    @Test("Non-bolus events and boluses without an amount are skipped") func testNonBolusSkipped() {
        let tempBasal = PumpHistoryEvent(id: "tb", type: .tempBasal, timestamp: now, amount: 1, duration: 30)
        let empty = PumpHistoryEvent(id: "b", type: .bolus, timestamp: now)

        #expect(BaseGlookoManager.bolusDose(tempBasal) == nil)
        #expect(BaseGlookoManager.bolusDose(empty) == nil)
    }

    // MARK: - Upload issue

    @Test("Signed out or rejected sign-in means login required") func testLoginRequired() {
        #expect(BaseGlookoManager.uploadIssue(isAuthenticated: false, activeAlerts: []) == .loginRequired)
        #expect(BaseGlookoManager.uploadIssue(isAuthenticated: true, activeAlerts: ["authentication-needed"]) == .loginRequired)
        #expect(BaseGlookoManager.uploadIssue(
            isAuthenticated: true,
            activeAlerts: ["authentication-needed", "uploads-stalled"]
        ) == .loginRequired)
    }

    @Test("Stalled uploads while signed in mean uploads failing") func testUploadsFailing() {
        #expect(BaseGlookoManager.uploadIssue(isAuthenticated: true, activeAlerts: ["uploads-stalled"]) == .uploadsFailing)
    }

    @Test("No alerts while signed in means no issue") func testNoIssue() {
        #expect(BaseGlookoManager.uploadIssue(isAuthenticated: true, activeAlerts: []) == nil)
    }
}
