// SyncBridge.swift
import Foundation
import Combine
import CoreData


/// Bridges BLE events into Core Data repositories and manages delta requests.
final class SyncBridge: ObservableObject {
    private let source: PuffsSource
    private let puffRepo: PuffRepositoryCoreData
    private let activeRepo: ActivePhaseRepositoryCoreData

    private var cancellables = Set<AnyCancellable>()
    private var lastSeen: Int = 0
    private var isCatchingUp = false

    init(bluetoothManager: BluetoothManager, context: NSManagedObjectContext) {
        self.source = bluetoothManager
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        bind()
    }

    // Test code path
    init(source: PuffsSource, context: NSManagedObjectContext) {
        self.source = source
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        bind()
    }


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
                guard let self else { return }
                self.handlePuffs(batch)
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

    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }

        // Continuity check (simple, since device guarantees monotonically increasing puffNumber)
        let first = items[0].puffNumber
        if first != lastSeen + 1 {
            // Gap detected → re-request from lastSeen again (idempotent)
            source.requestPuffs(startAfter: UInt16(clamping: lastSeen), maxCount: 50)
            return
        }

        // Dedup & persist
        var advanced = false
        for puff in items {
            if puff.puffNumber <= lastSeen { continue } // dedup protects retry cases
            if puffRepo.exists(puffNumber: puff.puffNumber) {
                // already persisted (e.g., retry)
                continue
            }
            puffRepo.addPuff(puff)
            lastSeen = puff.puffNumber
            advanced = true
        }

        // If we're catching up, keep pulling until device signals done (or we can keep asking in chunks)
        if isCatchingUp, advanced {
            source.requestPuffs(startAfter: UInt16(clamping: lastSeen), maxCount: 50)
        }
    }
}

protocol PuffsSource {
    var puffsBatchPublisher: PassthroughSubject<[PuffModel], Never> { get }
    var puffsBackfillComplete: PassthroughSubject<Void, Never> { get }
    var activePhasePublisher: PassthroughSubject<ActivePhaseModel, Never> { get }
    var connectionPublisher: PassthroughSubject<Bool, Never> { get }
    func requestPuffs(startAfter: UInt16, maxCount: UInt8?)
    func readActivePhase()
}

extension BluetoothManager: PuffsSource {}
