// SyncBridge.swift
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

    // MARK: - Inits
    /// App code path
    init(bluetoothManager: BluetoothManager, context: NSManagedObjectContext) {
        self.source   = bluetoothManager
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        bind()
    }

    /// Test code path
    init(source: PuffsSource, context: NSManagedObjectContext) {
        self.source   = source
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
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
                    self.source.readActivePhase()
                    self.isCatchingUp = true
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 50)
                } else {
                    self.isCatchingUp = false
                }
            }
            .store(in: &cancellables)

        // ActivePhase updates
        source.activePhasePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ap in
                self?.activeRepo.saveActivePhase(ap)
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
            }
            .store(in: &cancellables)
    }

    // MARK: - Delta ingest
    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }

        // 1) Front-door continuity: first must be exactly lastSeen+1
        let first = items[0].puffNumber
        if first != lastSeen + 1 {
            requestFromLastSeen(withBackoff: true)
            return
        }

        // Reset backoff as we're in lockstep now
        gapRetryCount = 0

        // 2) Walk the batch strictly in sequence using an `expected` pointer
        var expected = lastSeen + 1
        var advanced = false

        for p in items {
            switch p.puffNumber {
            case ..<expected:
                // duplicate/overlap inside batch — ignore
                continue

            case expected:
                // strictly next in sequence — persist
                if !puffRepo.exists(puffNumber: p.puffNumber) {
                    puffRepo.addPuff(p)
                }
                lastSeen = expected
                expected += 1
                advanced = true

            default:
                // 3) Mid-batch gap — stop ingesting and re-request from current lastSeen (with backoff)
                requestFromLastSeen(withBackoff: true)
                return
            }
        }

        // 4) If we advanced and are still catching up, immediately ask for the next chunk
        if isCatchingUp, advanced {
            requestFromLastSeen(withBackoff: false)
        }
    }

    // MARK: - Request helpers
    private func requestFromLastSeen() {
        requestFromLastSeen(withBackoff: false)
    }

    private func requestFromLastSeen(withBackoff: Bool) {
        if withBackoff {
            gapRetryCount += 1
            if gapRetryCount <= gapRetryMax {
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 50)
                }
            } else {
                // give up for now; next connect or explicit request will retry
                gapRetryCount = 0
            }
        } else {
            source.requestPuffs(startAfter: UInt16(clamping: lastSeen), maxCount: 50)
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
