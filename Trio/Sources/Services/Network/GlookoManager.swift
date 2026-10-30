import Combine
import CoreData
import Foundation
import GlookoServiceKit
import LoopKit
import LoopKitUI
import Swinject
import UIKit

/// What keeps Trio's data from reaching Glooko, worst first.
enum GlookoUploadIssue: Equatable {
    case loginRequired
    case uploadsFailing
}

protocol GlookoManager {
    var glookoUploadIssue: CurrentValueSubject<GlookoUploadIssue?, Never> { get }
    func addGlookoService(service: Service)
    func getGlookoServiceUI() -> ServiceUI?
    func getGlookoPluginHost() -> PluginHost?
    func uploadCarbs() async
    func deleteCarbs(withSyncId id: UUID, carbs: Decimal, at: Date, enteredBy: String)
    func uploadInsulin() async
    func deleteInsulin(withSyncId id: String, amount: Decimal, at: Date)
    func uploadGlucose() async
    func forceGlookoDataUpload()
}

final class BaseGlookoManager: GlookoManager, Injectable {
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var notificationCenter: NotificationCenter!

    // Resolved on use, so the alert manager's own dependencies needn't resolve this manager
    private let resolver: Resolver

    /// Serializes uploads so concurrent requests can't each re-sign-in, and coalesces bursts per pipeline.
    private let uploadSerializer = TidepoolUploadSerializer(serviceName: "Glooko", category: .glooko)

    /// Basal history resent before the oldest pending event, so recently completed hours reach Glooko
    /// even when no new pump event falls inside them.
    static let snapshotLookback: TimeInterval = 6 * 60 * 60

    private var glookoService: GlookoService? {
        didSet {
            rawGlookoManager = glookoService?.rawValue
            observeGlookoService()
        }
    }

    let glookoUploadIssue = CurrentValueSubject<GlookoUploadIssue?, Never>(nil)
    private var serviceSubscription: AnyCancellable?

    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    private var subscriptions = Set<AnyCancellable>()

    // MARK: - Upload triggers

    //
    // Same as Tidepool: each pipeline is driven by an NSFetchedResultsController over the
    // "not yet uploaded to Glooko" set, which fires whenever pending items appear or drop out.

    let glucoseUploadControllerDelegate = FetchedResultsControllerDelegate()
    private lazy var glucoseUploadController: NSFetchedResultsController<GlucoseStored> = {
        let request = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate.glucoseNotYetUploadedToGlooko(isManual: false),
            NSPredicate.glucoseNotYetUploadedToGlooko(isManual: true)
        ])
        request.fetchBatchSize = 50
        let controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = glucoseUploadControllerDelegate
        return controller
    }()

    let carbsUploadControllerDelegate = FetchedResultsControllerDelegate()
    private lazy var carbsUploadController: NSFetchedResultsController<CarbEntryStored> = {
        let request = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: true)]
        request.predicate = NSPredicate.carbsNotYetUploadedToGlooko
        request.fetchBatchSize = 50
        let controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = carbsUploadControllerDelegate
        return controller
    }()

    let insulinUploadControllerDelegate = FetchedResultsControllerDelegate()
    private lazy var insulinUploadController: NSFetchedResultsController<PumpEventStored> = {
        let request = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PumpEventStored.timestamp, ascending: true)]
        request.predicate = NSPredicate.pumpEventsNotYetUploadedToGlooko
        request.fetchBatchSize = 50
        let controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = insulinUploadControllerDelegate
        return controller
    }()

    @PersistedProperty(key: "GlookoState") var rawGlookoManager: Service.RawValue?

    init(resolver: Resolver) {
        self.resolver = resolver
        injectServices(resolver)
        loadGlookoManager()

        registerUploadControllers()

        notificationCenter
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task(priority: .utility) { await self.uploadSerializer.recoverIfWedged() }
            }
            .store(in: &subscriptions)
    }

    private func registerUploadControllers() {
        glucoseUploadControllerDelegate.onContentChange = { [weak self] in
            Task { await self?.uploadGlucose() }
        }
        carbsUploadControllerDelegate.onContentChange = { [weak self] in
            Task { await self?.uploadCarbs() }
        }
        insulinUploadControllerDelegate.onContentChange = { [weak self] in
            Task { await self?.uploadInsulin() }
        }

        // performFetch must run on the viewContext's queue (main).
        Task { @MainActor in
            do {
                try self.glucoseUploadController.performFetch()
                try self.carbsUploadController.performFetch()
                try self.insulinUploadController.performFetch()
            } catch {
                warning(.glooko, "Failed to set up Glooko upload controllers", error: error)
            }
        }
    }

    private func loadGlookoManager() {
        guard let rawState = rawGlookoManager?["state"] as? Service.RawStateValue,
              let service = GlookoService(rawState: rawState)
        else { return }
        glookoService = service
        service.serviceDelegate = self
        service.stateDelegate = self
    }

    func getGlookoServiceUI() -> ServiceUI? {
        glookoService as? ServiceUI
    }

    func getGlookoPluginHost() -> PluginHost? {
        self as PluginHost
    }

    func addGlookoService(service: Service) {
        guard let service = service as? GlookoService else { return }
        service.serviceDelegate = self
        service.stateDelegate = self
        glookoService = service
    }

    func sourceInfo() -> [String: Any]? {
        nil
    }

    /// Mirrors the service's sign-in state and active alerts; both change with `stats`
    private func observeGlookoService() {
        guard let service = glookoService else {
            serviceSubscription = nil
            glookoUploadIssue.send(nil)
            return
        }
        serviceSubscription = service.$stats
            .sink { [weak self, weak service] stats in
                guard let service else { return }
                self?.glookoUploadIssue.send(Self.uploadIssue(
                    isAuthenticated: service.isAuthenticated,
                    activeAlerts: stats.activeAlerts ?? []
                ))
            }
    }

    static func uploadIssue(isAuthenticated: Bool, activeAlerts: [String]) -> GlookoUploadIssue? {
        if !isAuthenticated || activeAlerts.contains(GlookoService.AlertKind.authenticationNeeded.rawValue) {
            return .loginRequired
        }
        if activeAlerts.contains(GlookoService.AlertKind.uploadsStalled.rawValue) { return .uploadsFailing }
        return nil
    }

    func forceGlookoDataUpload() {
        Task {
            await uploadInsulin()
            await uploadCarbs()
            await uploadGlucose()
        }
    }
}

extension BaseGlookoManager: ServiceDelegate {
    var hostIdentifier: String {
        "org.nightscout.Trio"
    }

    var hostVersion: String {
        var semanticVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String

        while semanticVersion.split(separator: ".").count < 3 {
            semanticVersion += ".0"
        }

        semanticVersion += "+\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String)"

        return semanticVersion
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        warning(.glooko, "Glooko alert issued: \(alert.identifier.alertIdentifier)")
        resolver.resolve(TrioAlertManager.self)?.issueAlert(alert)
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        info(.glooko, "Glooko alert retracted: \(identifier.alertIdentifier)")
        resolver.resolve(TrioAlertManager.self)?.retractAlert(identifier: identifier)
    }

    func enactRemoteOverride(name _: String, durationTime _: TimeInterval?, remoteAddress _: String) async throws {}

    func cancelRemoteOverride() async throws {}

    func deliverRemoteCarbs(
        amountInGrams _: Double,
        absorptionTime _: TimeInterval?,
        foodType _: String?,
        startDate _: Date?
    ) async throws {}

    func deliverRemoteBolus(amountInUnits _: Double) async throws {}
}

extension BaseGlookoManager: StatefulPluggableDelegate {
    func pluginDidUpdateState(_: LoopKit.StatefulPluggable) {
        // persists sign-in and upload stats, which change after setup
        rawGlookoManager = glookoService?.rawValue
    }

    func pluginWantsDeletion(_: LoopKit.StatefulPluggable) {
        glookoService = nil
    }
}

/// Carb Upload and Deletion Functionality
extension BaseGlookoManager {
    func uploadCarbs() async {
        guard glookoService != nil else { return }
        await uploadSerializer.enqueue(.carbs) { [weak self] generation in
            await self?.performCarbsUpload(generation: generation)
        }
    }

    private func performCarbsUpload(generation: Int) async {
        guard let glookoService = self.glookoService else { return }

        let carbs: [CarbsEntry]
        do {
            carbs = try await carbsStorage.getCarbsNotYetUploadedToGlooko()
        } catch {
            warning(.glooko, "Failed to load pending carbs for Glooko upload", error: error)
            return
        }
        guard !carbs.isEmpty else { return }

        for chunk in carbs.chunks(ofCount: glookoService.carbDataLimit ?? 100) {
            guard await uploadSerializer.isCurrent(generation) else { return }

            let syncCarb: [SyncCarbObject] = Array(chunk).map { $0.convertSyncCarb() }

            let result = await TidepoolUploadSerializer.awaitUpload("carbs") { completion in
                glookoService.uploadCarbData(created: syncCarb, updated: [], deleted: [], completion: completion)
            }

            switch result {
            case .success:
                info(.glooko, "Uploaded \(chunk.count) carb entries to Glooko")
                await markCarbsAsUploaded(chunk.compactMap(\.id).compactMap(UUID.init(uuidString:)))
            case let .failure(error):
                warning(.glooko, "Glooko upload of \(chunk.count) carb entries failed", error: error)
            }
        }
    }

    private func markCarbsAsUploaded(_ ids: [UUID]) async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "markCarbsAsUploadedToGlooko"
        await context.perform {
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as NSArray)

            do {
                for result in try context.fetch(fetchRequest) {
                    result.isUploadedToGlooko = true
                }
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Failed to mark carb entries as uploaded to Glooko", error: error)
            }
        }
    }

    func deleteCarbs(withSyncId id: UUID, carbs: Decimal, at: Date, enteredBy: String) {
        guard let glookoService = self.glookoService else { return }

        let syncCarb = [SyncCarbObject(
            absorptionTime: nil,
            createdByCurrentApp: true,
            foodType: nil,
            grams: Double(carbs),
            startDate: at,
            uuid: id,
            provenanceIdentifier: enteredBy,
            syncIdentifier: id.uuidString,
            syncVersion: nil,
            userCreatedDate: nil,
            userUpdatedDate: nil,
            userDeletedDate: nil,
            operation: LoopKit.Operation.delete,
            addedDate: nil,
            supercededDate: nil
        )]

        Task { [weak self] in
            await self?.uploadSerializer.enqueue(.carbsDelete) { _ in
                let result = await TidepoolUploadSerializer.awaitUpload("carbs-delete") { completion in
                    glookoService.uploadCarbData(created: [], updated: [], deleted: syncCarb, completion: completion)
                }
                switch result {
                case .success:
                    debug(.glooko, "Carb entry deletion synced to Glooko")
                case let .failure(error):
                    warning(.glooko, "Glooko carb entry deletion failed", error: error)
                }
            }
        }
    }
}

/// Insulin Upload and Deletion Functionality
extension BaseGlookoManager {
    func uploadInsulin() async {
        guard glookoService != nil else { return }
        await uploadSerializer.enqueue(.dose) { [weak self] _ in
            await self?.performDoseUpload()
        }
    }

    /// Sends pending boluses with the basal timeline covering them. Both backends deduplicate
    /// a resent window, so the whole window goes up each time.
    private func performDoseUpload() async {
        guard let glookoService = self.glookoService else { return }

        let pending: [PumpHistoryEvent]
        let history: [PumpHistoryEvent]
        do {
            pending = try await pumpHistoryStorage.getPumpHistoryNotYetUploadedToGlooko()
            guard !pending.isEmpty else { return }
            history = try await pumpHistoryStorage.getPumpHistory()
        } catch {
            warning(.glooko, "Failed to load pending pump history for Glooko upload", error: error)
            return
        }

        let now = Date()
        let basal = GlookoBasalTimeline.doses(
            pumpHistory: history,
            profile: basalProfile(),
            start: Self.snapshotStart(pending: pending, now: now),
            now: now
        )
        let boluses = pending.compactMap(Self.bolusDose)

        let result = await TidepoolUploadSerializer.awaitUpload("dose") { completion in
            glookoService.uploadPumpSnapshot(basal: basal, boluses: boluses, carbs: [], now: now, completion: completion)
        }
        switch result {
        case .success:
            info(.glooko, "Uploaded \(boluses.count) boluses and \(basal.count) basal segments to Glooko")
            await markPumpEventsAsUploaded(pending.map(\.id))
        case let .failure(error):
            warning(.glooko, "Glooko upload of \(boluses.count) boluses and \(basal.count) basal segments failed", error: error)
        }
    }

    /// Hour-aligned start of the resent window: the oldest pending event or the lookback, whichever is earlier.
    static func snapshotStart(pending: [PumpHistoryEvent], now: Date) -> Date {
        let oldest = min(pending.map(\.timestamp).min() ?? now, now.addingTimeInterval(-snapshotLookback))
        return Date(timeIntervalSince1970: (oldest.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// A pump bolus as a dose; external insulin (pens, injections) didn't come from the pump and is not sent.
    static func bolusDose(_ event: PumpHistoryEvent) -> DoseEntry? {
        guard event.type == .bolus, event.isExternal != true, let amount = event.amount else { return nil }
        return DoseEntry(
            type: .bolus,
            startDate: event.timestamp,
            endDate: event.timestamp,
            value: Double(event.programmedAmount ?? amount),
            unit: .units,
            deliveredUnits: Double(amount),
            syncIdentifier: event.id,
            automatic: event.isSMB ?? true,
            manuallyEntered: false
        )
    }

    private func basalProfile() -> [BasalProfileEntry] {
        storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
            ?? []
    }

    private func markPumpEventsAsUploaded(_ ids: [String]) async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "markPumpEventsAsUploadedToGlooko"
        await context.perform {
            let fetchRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as NSArray)

            do {
                for result in try context.fetch(fetchRequest) {
                    result.isUploadedToGlooko = true
                }
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Failed to mark pump events as uploaded to Glooko", error: error)
            }
        }
    }

    func deleteInsulin(withSyncId id: String, amount: Decimal, at: Date) {
        guard let glookoService = self.glookoService else { return }

        let doseDataToDelete = [DoseEntry(
            type: .bolus,
            startDate: at,
            value: Double(amount),
            unit: .units,
            syncIdentifier: id
        )]

        Task { [weak self] in
            await self?.uploadSerializer.enqueue(.doseDelete) { _ in
                let result = await TidepoolUploadSerializer.awaitUpload("dose-delete") { completion in
                    glookoService.uploadDoseData(created: [], deleted: doseDataToDelete, completion: completion)
                }
                switch result {
                case .success:
                    debug(.glooko, "Dose deletion synced to Glooko")
                case let .failure(error):
                    warning(.glooko, "Glooko dose deletion failed", error: error)
                }
            }
        }
    }
}

/// Glucose Upload Functionality
extension BaseGlookoManager {
    func uploadGlucose() async {
        guard glookoService != nil else { return }
        await uploadSerializer.enqueue(.glucose) { [weak self] generation in
            await self?.performGlucoseUpload(generation: generation)
        }
    }

    private func performGlucoseUpload(generation: Int) async {
        guard let glookoService = self.glookoService else { return }

        let glucose: [StoredGlucoseSample]
        do {
            glucose = try await glucoseStorage.getGlucoseNotYetUploadedToGlooko()
        } catch {
            warning(.glooko, "Failed to load pending glucose for Glooko upload", error: error)
            return
        }
        guard !glucose.isEmpty else { return }

        for chunk in glucose.chunks(ofCount: glookoService.glucoseDataLimit ?? 100) {
            guard await uploadSerializer.isCurrent(generation) else { return }

            let result = await TidepoolUploadSerializer.awaitUpload("glucose") { completion in
                glookoService.uploadGlucoseData(Array(chunk), completion: completion)
            }

            switch result {
            case .success:
                info(.glooko, "Uploaded \(chunk.count) glucose values to Glooko")
                await markGlucoseAsUploaded(chunk.compactMap { $0.syncIdentifier.flatMap(UUID.init(uuidString:)) })
            case let .failure(error):
                warning(.glooko, "Glooko upload of \(chunk.count) glucose values failed", error: error)
            }
        }
    }

    private func markGlucoseAsUploaded(_ ids: [UUID]) async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "markGlucoseAsUploadedToGlooko"
        await context.perform {
            let fetchRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as NSArray)

            do {
                for result in try context.fetch(fetchRequest) {
                    result.isUploadedToGlooko = true
                }
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Failed to mark glucose as uploaded to Glooko", error: error)
            }
        }
    }
}
