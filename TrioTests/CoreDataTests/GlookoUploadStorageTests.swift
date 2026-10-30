import CoreData
import Foundation
import Swinject
import Testing

@testable import LoopKit
@testable import Trio

/// Store-level tests for which rows are pending upload to Glooko.
@Suite("Glooko Upload Storage Tests", .serialized) struct GlookoUploadStorageTests: Injectable {
    @Injected() var glucoseStorage: GlucoseStorage!
    @Injected() var carbsStorage: CarbsStorage!
    @Injected() var pumpHistoryStorage: PumpHistoryStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    // MARK: - Helpers

    @discardableResult private func insertGlucose(
        _ value: Int16,
        minutesAgo: Double,
        isManual: Bool,
        uploaded: Bool? = false
    ) async throws -> UUID {
        let id = UUID()
        try await testContext.perform {
            let glucose = GlucoseStored(context: testContext)
            glucose.id = id
            glucose.date = Date().addingTimeInterval(-minutesAgo * 60)
            glucose.glucose = value
            glucose.isManual = isManual
            glucose.isUploadedToTidepool = false
            // nil models a row that must never be uploaded
            if let uploaded { glucose.isUploadedToGlooko = uploaded }
            try testContext.save()
        }
        return id
    }

    private func insertCarbs(_ grams: Double, isFPU: Bool, uploaded: Bool? = false) async throws {
        try await testContext.perform {
            let carbs = CarbEntryStored(context: testContext)
            carbs.id = UUID()
            carbs.date = Date().addingTimeInterval(-10 * 60)
            carbs.carbs = grams
            carbs.isFPU = isFPU
            if let uploaded { carbs.isUploadedToGlooko = uploaded }
            try testContext.save()
        }
    }

    private func bolusEvent(_ syncIdentifier: String, minutesAgo: Double, isMutable: Bool = false) -> NewPumpEvent {
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        return NewPumpEvent(
            date: date,
            dose: DoseEntry(
                type: .bolus,
                startDate: date,
                value: 1.0,
                unit: .units,
                deliveredUnits: isMutable ? 0.4 : 1.0,
                syncIdentifier: syncIdentifier,
                automatic: false,
                isMutable: isMutable
            ),
            raw: Data(syncIdentifier.utf8),
            title: "Bolus",
            type: .bolus
        )
    }

    // MARK: - Glucose

    @Test("CGM and manual glucose are both pending, each flagged by its own source") func testGlucoseSplitsManual() async throws {
        let cgm = try await insertGlucose(120, minutesAgo: 10, isManual: false)
        let manual = try await insertGlucose(95, minutesAgo: 20, isManual: true)

        let pending = try await glucoseStorage.getGlucoseNotYetUploadedToGlooko()

        #expect(pending.count == 2)
        #expect(pending.first { $0.syncIdentifier == cgm.uuidString }?.wasUserEntered == false)
        #expect(pending.first { $0.syncIdentifier == manual.uuidString }?.wasUserEntered == true)
    }

    @Test("Uploaded, unflagged and day-old glucose is not pending") func testGlucoseExclusions() async throws {
        try await insertGlucose(120, minutesAgo: 10, isManual: false, uploaded: true)
        try await insertGlucose(130, minutesAgo: 15, isManual: false, uploaded: nil)
        try await insertGlucose(140, minutesAgo: 25 * 60, isManual: false)

        #expect(try await glucoseStorage.getGlucoseNotYetUploadedToGlooko().isEmpty)
    }

    @Test("Glucose stored from a CGM starts out pending for Glooko") func testStoredGlucoseIsPending() async throws {
        let date = Date().addingTimeInterval(-5 * 60)
        try await glucoseStorage.storeGlucose([
            BloodGlucose(
                id: UUID().uuidString,
                sgv: 110,
                direction: .flat,
                date: Decimal(date.timeIntervalSince1970 * 1000),
                dateString: date,
                unfiltered: nil,
                filtered: nil,
                noise: nil,
                glucose: 110
            )
        ])

        let pending = try await glucoseStorage.getGlucoseNotYetUploadedToGlooko()
        #expect(pending.count == 1)
        #expect(pending.first?.wasUserEntered == false)
    }

    @Test("The Tidepool glucose fetch is unchanged by the shared helper") func testTidepoolFetchUnchanged() async throws {
        try await insertGlucose(120, minutesAgo: 10, isManual: false)
        try await insertGlucose(95, minutesAgo: 20, isManual: true)

        let cgm = try await glucoseStorage.getGlucoseNotYetUploadedToTidepool()
        let manual = try await glucoseStorage.getManualGlucoseNotYetUploadedToTidepool()

        #expect(cgm.count == 2)
        #expect(cgm.allSatisfy { !$0.wasUserEntered })
        #expect(manual.count == 1)
        #expect(manual.allSatisfy { $0.wasUserEntered })
    }

    // MARK: - Carbs

    @Test("Carb entries are pending, FPU equivalents and uploaded entries are not") func testCarbsPending() async throws {
        try await insertCarbs(30, isFPU: false)
        try await insertCarbs(10, isFPU: true, uploaded: nil)
        try await insertCarbs(20, isFPU: false, uploaded: true)

        let pending = try await carbsStorage.getCarbsNotYetUploadedToGlooko()

        #expect(pending.count == 1)
        #expect(pending.first?.carbs == 30)
    }

    @Test("Locally stored carbs start out pending, carb equivalents never do") func testStoredCarbsPending() async throws {
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: Date().addingTimeInterval(-5 * 60),
            carbs: 40,
            fat: 20,
            protein: 20,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: UUID().uuidString
        )
        try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)

        let pending = try await carbsStorage.getCarbsNotYetUploadedToGlooko()
        #expect(pending.count == 1)
        #expect(pending.first?.carbs == 40)
    }

    // MARK: - Pump events

    @Test("Final boluses are pending, mutable ones wait") func testPumpEventsPending() async throws {
        try await pumpHistoryStorage.storePumpEvents(
            [bolusEvent("glooko-final", minutesAgo: 10), bolusEvent("glooko-running", minutesAgo: 2, isMutable: true)],
            replacePendingEvents: false
        )

        let pending = try await pumpHistoryStorage.getPumpHistoryNotYetUploadedToGlooko()

        #expect(pending.count == 1)
        #expect(pending.first?.type == .bolus)
        #expect(pending.first?.amount == 1)
    }

    @Test("External insulin is pending so it gets marked, and is flagged external") func testExternalInsulinPending() async throws {
        await pumpHistoryStorage.storeExternalInsulinEvent(amount: 2, timestamp: Date().addingTimeInterval(-5 * 60))

        let pending = try await pumpHistoryStorage.getPumpHistoryNotYetUploadedToGlooko()

        #expect(pending.count == 1)
        #expect(pending.first?.isExternal == true)
        #expect(pending.first.flatMap(BaseGlookoManager.bolusDose) == nil)
    }

    @Test("Uploaded pump events are not pending") func testUploadedPumpEventsExcluded() async throws {
        try await pumpHistoryStorage.storePumpEvents([bolusEvent("glooko-done", minutesAgo: 10)], replacePendingEvents: false)
        try await testContext.perform {
            for event in try testContext.fetch(PumpEventStored.fetchRequest()) {
                event.isUploadedToGlooko = true
            }
            try testContext.save()
        }

        #expect(try await pumpHistoryStorage.getPumpHistoryNotYetUploadedToGlooko().isEmpty)
    }
}
