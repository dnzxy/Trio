import Foundation
import LoopKit

/// Basal delivery as one contiguous series of doses: Glooko renders a basal only as a segment
/// closed by the next one, and totals delivery per hour, so gaps and overlaps both misreport.
enum GlookoBasalTimeline {
    /// `pumpHistory`: temp basals (scheduled-basal reports included), suspends and resumes.
    /// Returns `.tempBasal`, `.basal` (inferred schedule) and `.suspend` doses clipped to `start...now`.
    static func doses(
        pumpHistory: [PumpHistoryEvent],
        profile: [BasalProfileEntry],
        start: Date,
        now: Date
    ) -> [DoseEntry] {
        let suspensions = BaseTDDStorage.suspensionSpans(
            suspends: pumpHistory.filter { $0.type == .pumpSuspend },
            resumes: pumpHistory.filter { $0.type == .pumpResume },
            now: now
        )
        let temps = tempSegments(pumpHistory: pumpHistory, suspensions: suspensions, now: now)

        // the sweep fills only what the clipped temps and suspensions leave uncovered
        var timeline = temps.map { ScheduledBasalInference.TimelineEvent(start: $0.start, end: $0.end, kind: .tempBasal) }
        timeline += pumpHistory.compactMap { event in
            switch event.type {
            case .pumpSuspend: return ScheduledBasalInference.TimelineEvent(start: event.timestamp, kind: .suspend)
            case .pumpResume: return ScheduledBasalInference.TimelineEvent(start: event.timestamp, kind: .resume)
            // a scheduled-basal report covers nothing but anchors the window's start
            case .tempBasal where event.isScheduledBasal == true:
                return ScheduledBasalInference.TimelineEvent(start: event.timestamp, kind: .tempBasal)
            default: return nil
            }
        }
        let scheduled = ScheduledBasalInference.segments(events: timeline, profile: profile, now: now)

        var segments = temps.map { (start: $0.start, end: $0.end, rate: $0.rate, type: DoseType.tempBasal) }
        segments += scheduled.map { (start: $0.start, end: $0.end, rate: $0.rate, type: DoseType.basal) }
        segments += suspensions.map { (start: $0.start, end: $0.end, rate: Decimal(0), type: DoseType.suspend) }

        return segments
            .compactMap { segment -> DoseEntry? in
                let clippedStart = max(segment.start, start)
                let clippedEnd = min(segment.end, now)
                guard clippedEnd > clippedStart else { return nil }
                return DoseEntry(
                    type: segment.type,
                    startDate: clippedStart,
                    endDate: clippedEnd,
                    value: Double(truncating: segment.rate as NSNumber),
                    unit: .unitsPerHour,
                    automatic: segment.type == .tempBasal
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Each temp runs until its programmed end, the next temp, a suspension or `now`, whichever is first;
    /// a resume hands delivery back to the schedule, so a temp never continues past a suspension.
    private static func tempSegments(
        pumpHistory: [PumpHistoryEvent],
        suspensions: [(start: Date, end: Date)],
        now: Date
    ) -> [(start: Date, end: Date, rate: Decimal)] {
        let temps = pumpHistory
            .filter { $0.type == .tempBasal && $0.isScheduledBasal != true }
            .sorted { $0.timestamp < $1.timestamp }

        return temps.enumerated().compactMap { index, temp in
            guard let rate = temp.amount, let duration = temp.duration else { return nil }
            let start = temp.timestamp
            guard !suspensions.contains(where: { $0.start <= start && start < $0.end }) else { return nil }

            var end = min(start.addingTimeInterval(TimeInterval(duration * 60)), now)
            if index < temps.count - 1 { end = min(end, temps[index + 1].timestamp) }
            if let suspension = suspensions.first(where: { $0.start > start && $0.start < end }) {
                end = suspension.start
            }
            guard end > start else { return nil }
            return (start: start, end: end, rate: rate)
        }
    }
}
