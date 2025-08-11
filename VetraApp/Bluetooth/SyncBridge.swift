// =============================================
// SyncBridge.swift — with logging
// =============================================

import Foundation
import Combine
import CoreData

/// Bridges BLE events into Core Data repositories and manages delta requests.
final class SyncBridge: ObservableObject {
    // MARK: - Dependencies
    private let source: PuffsSource
    private let puffRepo: PuffRepositoryCoreData
    private let activeRepo: ActivePhaseRepositoryCoreData

    // MARK: - State
    private var cancellables = Set<AnyCancellable>()
    private var lastSeen: Int = 0
    private var isCatchingUp = false

    // Gap retry/backoff
    private var gapRetryCount = 0
    private let gapRetryMax = 3
    private let gapRetryDelay: TimeInterval = 0.25

    // MARK: - Log helper
    private func log(_ msg: String) { print("[SyncBridge] \(msg)") }
    
    private func dumpInserted(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        print("[SyncBridge] INSERT \(items.count) puff(s)")
        for p in items {
            let tsStr  = iso.string(from: p.timestamp)
            let durStr = String(format: "%.3f", p.duration)
            print("[SyncBridge]   #\(p.puffNumber) ts=\(tsStr) dur=\(durStr)s phase=\(p.phaseIndex)")
        }
    }

    // MARK: - Inits
    /// App code path
    init(bluetoothManager: BluetoothManager, context: NSManagedObjectContext) {
        self.source   = bluetoothManager
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        log("Init(app): lastSeen=\(self.lastSeen)")
        bind()
    }

    /// Test code path
    init(source: PuffsSource, context: NSManagedObjectContext) {
        self.source   = source
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        log("Init(test): lastSeen=\(self.lastSeen)")
        bind()
    }

    // MARK: - Wiring
    private func bind() {
        // Connection lifecycle → request deltas
        source.connectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    self.lastSeen = self.puffRepo.maxPuffNumber()
                    self.log("Connected. lastSeen=\(self.lastSeen). Reading ActivePhase + requesting backfill…")
                    self.source.readActivePhase()
                    self.isCatchingUp = true
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 50)
                } else {
                    self.isCatchingUp = false
                    self.log("Disconnected.")
                }
            }
            .store(in: &cancellables)

        // ActivePhase updates
        source.activePhasePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ap in
                self?.log("ActivePhase update -> index=\(ap.phaseIndex) start=\(ap.phaseStartDate)")
                self?.handleActivePhase(ap)
            }
            .store(in: &cancellables)

        // Puffs stream
        source.puffsBatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batch in
                self?.handlePuffs(batch)
            }
            .store(in: &cancellables)

        // Backfill done (device should send as Indication)
        source.puffsBackfillComplete
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.isCatchingUp = false
                self?.log("Backfill complete. Live mode engaged.")
            }
            .store(in: &cancellables)
    }

    // MARK: - Delta ingest
    private func handleActivePhase(_ ap: ActivePhaseModel) {
        let current = self.activeRepo.activePhaseIndex()
        guard ap.phaseIndex > current else {
            self.log("ActivePhase ignored (new=\(ap.phaseIndex) <= current=\(current))")
            return
        }

        self.log("ActivePhase update -> index=\(ap.phaseIndex) start=\(ap.phaseStartDate)")
        self.activeRepo.saveActivePhase(ap)
    }

    
    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }

        var expected = lastSeen + 1
        var toInsert: [PuffModel] = []

        log("handlePuffs: received=\(items.count) expectedFirst=\(expected) batchFirst=\(items.first!.puffNumber) batchLast=\(items.last!.puffNumber)")

        for p in items {
            switch p.puffNumber {
            case ..<expected:
                // head overlap / duplicate — ignore
                continue

            case expected:
                // exactly next — accumulate (contiguous segment)
                toInsert.append(p)
                expected += 1

            default:
                // true gap (> expected) — backoff & retry from lastSeen
                log("Gap detected: expected=\(expected) got=\(p.puffNumber). Requesting from lastSeen=\(lastSeen) with backoff…")
                requestFromLastSeen(withBackoff: true)
                return
            }
        }

        if !toInsert.isEmpty {
            // persist in one shot
            puffRepo.addPuffs(toInsert)
            dumpInserted(toInsert)      // <— add this line
            lastSeen = toInsert.last!.puffNumber
            gapRetryCount = 0
            log("Inserted \(toInsert.count) puff(s); lastSeen -> \(lastSeen)")

            if isCatchingUp {
                log("Still catching up — requesting from lastSeen=\(lastSeen)")
                requestFromLastSeen(withBackoff: false)
            }
        }
    }

    // MARK: - Request helpers
    private func requestFromLastSeen() {
        requestFromLastSeen(withBackoff: false)
    }

    private func requestFromLastSeen(withBackoff: Bool) {
        if withBackoff {
            gapRetryCount += 1
            log("requestFromLastSeen(withBackoff=true) attempt=\(gapRetryCount)/\(gapRetryMax) lastSeen=\(lastSeen)")
            if gapRetryCount <= gapRetryMax {
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 50)
                    self.log("Re-requested from lastSeen=\(self.lastSeen) after backoff=\(self.gapRetryDelay)s")
                }
            } else {
                // give up for now; next connect or explicit request will retry
                log("Backoff max reached; pausing re-requests. lastSeen=\(lastSeen)")
                gapRetryCount = 0
            }
        } else {
            self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 15)
            log("Requested from lastSeen=\(lastSeen) (no backoff)")
        }
    }
}

// MARK: - BLE source abstraction (for DI/testing)
protocol PuffsSource {
    var puffsBatchPublisher: PassthroughSubject<[PuffModel], Never> { get }
    var puffsBackfillComplete: PassthroughSubject<Void, Never> { get }
    var activePhasePublisher: PassthroughSubject<ActivePhaseModel, Never> { get }
    var connectionPublisher: PassthroughSubject<Bool, Never> { get }
    func requestPuffs(startAfter: UInt16, maxCount: UInt8?)
    func readActivePhase()
}

// Make the real Bluetooth manager the source
extension BluetoothManager: PuffsSource {}
