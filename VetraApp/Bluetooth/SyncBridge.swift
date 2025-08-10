// SyncBridge.swift
import Foundation
import Combine

/// Bridges BLE events into Core Data repositories and manages delta requests.
final class SyncBridge: ObservableObject {
    private let bt: BluetoothManager
    private let puffRepo: PuffRepositoryCoreData
    private let activeRepo: ActivePhaseRepositoryCoreData

    private var cancellables = Set<AnyCancellable>()
    private var lastSeen: Int = 0
    private var isCatchingUp = false

    init(
        bluetoothManager: BluetoothManager,
        puffRepo: PuffRepositoryCoreData = PuffRepositoryCoreData(),
        activeRepo: ActivePhaseRepositoryCoreData = ActivePhaseRepositoryCoreData()
    ) {
        self.bt = bluetoothManager
        self.puffRepo = puffRepo
        self.activeRepo = activeRepo

        // initialize lastSeen from store
        self.lastSeen = puffRepo.maxPuffNumber()

        bind()
    }

    private func bind() {
        // Connection lifecycle → request deltas
        bt.connectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    self.lastSeen = self.puffRepo.maxPuffNumber()
                    self.bt.readActivePhase()
                    self.isCatchingUp = true
                    self.bt.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 50)
                } else {
                    self.isCatchingUp = false
                }
            }
            .store(in: &cancellables)

        // ActivePhase updates
        bt.activePhasePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ap in
                self?.activeRepo.saveActivePhase(ap)
            }
            .store(in: &cancellables)

        // Puffs stream
        bt.puffsBatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batch in
                guard let self else { return }
                self.handlePuffs(batch)
            }
            .store(in: &cancellables)

        // Backfill done (device should send as Indication)
        bt.puffsBackfillComplete
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
        if lastSeen > 0 && first != lastSeen + 1 {
            // Gap detected → re-request from lastSeen again (idempotent)
            bt.requestPuffs(startAfter: UInt16(clamping: lastSeen), maxCount: 50)
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
            bt.requestPuffs(startAfter: UInt16(clamping: lastSeen), maxCount: 50)
        }
    }
}
