import Foundation
import LoopKit
import Testing

@testable import Trio

/// Pure-function tests for the basal series sent to Glooko: one contiguous, non-overlapping
/// run of temp, scheduled and suspended segments, clipped to the upload window.
@Suite("Glooko Basal Timeline Tests") struct GlookoBasalTimelineTests {
    // MARK: - Fixtures

    private var flatProfile: [BasalProfileEntry] {
        [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.0)]
    }

    private var splitProfile: [BasalProfileEntry] {
        [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 1.0),
            BasalProfileEntry(start: "12:00", minutes: 720, rate: 0.5)
        ]
    }

    // Wall-clock times on one calendar day, matching the sweep's boundary math
    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    private func temp(_ start: Date, minutes: Int, rate: Decimal, scheduled: Bool = false) -> PumpHistoryEvent {
        PumpHistoryEvent(
            id: UUID().uuidString,
            type: .tempBasal,
            timestamp: start,
            amount: rate,
            duration: minutes,
            isScheduledBasal: scheduled
        )
    }

    private func suspend(_ date: Date) -> PumpHistoryEvent {
        PumpHistoryEvent(id: UUID().uuidString, type: .pumpSuspend, timestamp: date)
    }

    private func resume(_ date: Date) -> PumpHistoryEvent {
        PumpHistoryEvent(id: UUID().uuidString, type: .pumpResume, timestamp: date)
    }

    private func doses(
        _ history: [PumpHistoryEvent],
        profile: [BasalProfileEntry]? = nil,
        start: Date? = nil,
        now: Date
    ) -> [DoseEntry] {
        GlookoBasalTimeline.doses(
            pumpHistory: history,
            profile: profile ?? flatProfile,
            start: start ?? .distantPast,
            now: now
        )
    }

    private func near(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }

    private func isContiguous(_ doses: [DoseEntry]) -> Bool {
        zip(doses, doses.dropFirst()).allSatisfy { near($0.endDate, $1.startDate) }
    }

    private func units(_ doses: [DoseEntry]) -> Double {
        doses.reduce(0) { $0 + $1.unitsPerHour * $1.endDate.timeIntervalSince($1.startDate) / 3600 }
    }

    // MARK: - Shape

    @Test("No pump history yields no basal") func testEmptyHistory() {
        #expect(doses([], now: time(12)).isEmpty)
    }

    @Test("Nothing is fabricated before the first event") func testNoBasalBeforeFirstEvent() {
        let result = doses([temp(time(10), minutes: 30, rate: 2)], now: time(12))
        #expect(result.first.map { near($0.startDate, time(10)) } == true)
    }

    @Test("A temp basal is followed by the schedule up to now") func testTempThenScheduled() {
        let result = doses([temp(time(10), minutes: 30, rate: 2)], now: time(12))

        #expect(result.count == 2)
        #expect(result[0].type == .tempBasal)
        #expect(result[0].unitsPerHour == 2)
        #expect(near(result[0].endDate, time(10, 30)))
        #expect(result[1].type == .basal)
        #expect(result[1].unitsPerHour == 1)
        #expect(near(result[1].endDate, time(12)))
        #expect(isContiguous(result))
    }

    @Test("A newer temp basal cuts the previous one short") func testSupersededTemp() {
        let result = doses(
            [temp(time(10), minutes: 30, rate: 2), temp(time(10, 10), minutes: 30, rate: 3)],
            now: time(10, 40)
        )

        let temps = result.filter { $0.type == .tempBasal }
        #expect(temps.count == 2)
        #expect(near(temps[0].endDate, time(10, 10)))
        #expect(temps[1].unitsPerHour == 3)
        #expect(isContiguous(result))
    }

    @Test("A running temp basal ends at now") func testRunningTempClippedAtNow() {
        let result = doses([temp(time(10), minutes: 30, rate: 2)], now: time(10, 15))
        #expect(result.count == 1)
        #expect(near(result[0].endDate, time(10, 15)))
    }

    @Test("A zero-duration temp basal (cancel) hands back to the schedule") func testCancelTemp() {
        let result = doses(
            [temp(time(10), minutes: 30, rate: 2), temp(time(10, 10), minutes: 0, rate: 0)],
            now: time(10, 30)
        )

        #expect(result.map(\.type) == [.tempBasal, .basal])
        #expect(near(result[0].endDate, time(10, 10)))
        #expect(near(result[1].startDate, time(10, 10)))
    }

    // MARK: - Suspensions

    @Test("A suspension ends the temp basal and the schedule resumes after it") func testSuspendInsideTemp() {
        let result = doses(
            [temp(time(10), minutes: 60, rate: 2), suspend(time(10, 20)), resume(time(10, 40))],
            now: time(11, 30)
        )

        #expect(result.map(\.type) == [.tempBasal, .suspend, .basal])
        #expect(near(result[0].endDate, time(10, 20)))
        #expect(result[1].unitsPerHour == 0)
        #expect(near(result[1].endDate, time(10, 40)))
        #expect(result[2].unitsPerHour == 1)
        #expect(isContiguous(result))
    }

    @Test("An open suspension runs to now") func testOpenSuspension() {
        let result = doses([temp(time(10), minutes: 30, rate: 2), suspend(time(10, 10))], now: time(11))

        #expect(result.last?.type == .suspend)
        #expect(result.last.map { near($0.endDate, time(11)) } == true)
        #expect(isContiguous(result))
    }

    @Test("A temp basal programmed while suspended delivers nothing") func testTempDuringSuspension() {
        let result = doses(
            [suspend(time(10)), temp(time(10, 10), minutes: 30, rate: 2), resume(time(10, 20))],
            now: time(10, 30)
        )
        #expect(!result.contains { $0.type == .tempBasal })
    }

    @Test("Suspended time adds no insulin") func testSuspensionUnits() {
        let result = doses([temp(time(10), minutes: 0, rate: 1), suspend(time(10)), resume(time(11))], now: time(12))
        #expect(abs(units(result) - 1.0) < 0.001)
    }

    // MARK: - Schedule

    @Test("Scheduled basal splits at profile boundaries") func testProfileBoundarySplit() {
        let result = doses([temp(time(11), minutes: 0, rate: 0, scheduled: true)], profile: splitProfile, now: time(13))

        #expect(result.map(\.unitsPerHour) == [1.0, 0.5])
        #expect(near(result[0].endDate, time(12)))
        #expect(abs(units(result) - 1.5) < 0.001)
    }

    @Test("A scheduled-basal report anchors the series but covers nothing") func testScheduledReportAnchors() {
        let result = doses([temp(time(10), minutes: 30, rate: 0.8, scheduled: true)], now: time(11))

        #expect(!result.contains { $0.type == .tempBasal })
        #expect(result.first.map { near($0.startDate, time(10)) } == true)
        #expect(result.allSatisfy { $0.unitsPerHour == 1 })
    }

    // MARK: - Window

    @Test("Doses are clipped to the window start") func testClipToWindowStart() {
        let result = doses([temp(time(9, 30), minutes: 60, rate: 2)], start: time(10), now: time(11))

        #expect(result.first.map { near($0.startDate, time(10)) } == true)
        #expect(result.first?.type == .tempBasal)
        #expect(result.allSatisfy { $0.startDate >= time(10) })
    }

    @Test("A mixed day is contiguous with no overlaps") func testMixedDayContiguous() {
        let history = [
            temp(time(8), minutes: 30, rate: 1.5),
            temp(time(8, 20), minutes: 30, rate: 0),
            suspend(time(9)),
            resume(time(9, 15)),
            temp(time(10), minutes: 120, rate: 2),
            temp(time(11), minutes: 30, rate: 0.5)
        ]
        let result = doses(history, profile: splitProfile, now: time(13))

        #expect(isContiguous(result))
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.endDate <= $1.startDate.addingTimeInterval(1) })
        #expect(near(result.first!.startDate, time(8)))
        #expect(near(result.last!.endDate, time(13)))
    }

    @Test("Doses are units-per-hour, and only temps are marked automatic") func testDoseFields() {
        let result = doses([temp(time(10), minutes: 30, rate: 2)], now: time(11))
        #expect(result.allSatisfy { $0.unit == .unitsPerHour })
        #expect(result.first { $0.type == .tempBasal }?.automatic == true)
        #expect(result.first { $0.type == .basal }?.automatic == false)
    }
}
