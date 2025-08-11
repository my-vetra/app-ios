//
//  SyncBridge.swift
//  VetraApp
//
//  Bridges BLE events into Core Data repositories and manages delta requests.
//  Uses a background writer context; puffs are processed off-main.
//

import Foundation
import Combine
import CoreData
import os

/// BLE source abstraction (for DI/testing)
protocol PuffsSource {
    var puffsBatchPublisher: PassthroughSubject<[PuffModel], Never> { get }
    var puffsBackfillComplete: PassthroughSubject<Void, Never> { get }
    var activePhasePublisher: PassthroughSubject<ActivePhaseModel, Never> { get }
    var connectionPublisher: PassthroughSubject<Bool, Never> { get }
    func requestPuffs(startAfter: UInt16, maxCount: UInt8?)
    func readActivePhase()
}

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

    // Processing queue (off-main)
    private let processingQueue: DispatchQueue

    // Logging
    private let logger = Logger(subsystem: "com.vetra.app", category: "Sync")
    private func log(_ msg: String) { logger.debug("\(msg, privacy: .public)") }

    // MARK: - Inits
    /// App code path — pass the background writer context here.
    init(bluetoothManager: BluetoothManager, context: NSManagedObjectContext,
         processingQueue: DispatchQueue = DispatchQueue(label: "sync.bridge.queue")) {
        self.processingQueue = processingQueue
        self.source   = bluetoothManager
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.activeRepo = ActivePhaseRepositoryCoreData(context: context)
        self.lastSeen = puffRepo.maxPuffNumber()
        log("Init(app): lastSeen=\(self.lastSeen)")
        bind()
    }

    /// Test code path
    init(source: PuffsSource, context: NSManagedObjectContext,
         processingQueue: DispatchQueue = DispatchQueue(label: "sync.bridge.queue")) {
        self.processingQueue = processingQueue
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
            .receive(on: processingQueue)
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
            .receive(on: processingQueue)
            .sink { [weak self] ap in
                self?.handleActivePhase(ap)
            }
            .store(in: &cancellables)

        // Puffs stream — process off-main to keep UI smooth
        source.puffsBatchPublisher
            .receive(on: processingQueue)
            .sink { [weak self] batch in
                self?.handlePuffs(batch)
            }
            .store(in: &cancellables)

        // Backfill done
        source.puffsBackfillComplete
            .receive(on: processingQueue)
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

        self.log("ActivePhase update -> index=\(ap.phaseIndex) start=\(ap.phaseStartDate.timeIntervalSince1970)")
        self.activeRepo.saveActivePhase(ap)
    }

    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }
        var expected = lastSeen + 1
        var toInsert: [PuffModel] = []

        for p in items {
            switch p.puffNumber {
            case ..<expected:
                continue
            case expected:
                toInsert.append(p); expected += 1
            default:
                insertValidPuffs()
                log("Gap detected: expected=\(expected) got=\(p.puffNumber). Requesting from lastSeen=\(lastSeen) with backoff…")
                requestFromLastSeen(withBackoff: true)
                return
            }
        }

        insertValidPuffs()

        if isCatchingUp {
            log("Still catching up — requesting from lastSeen=\(lastSeen)")
            requestFromLastSeen(withBackoff: false)
        }

        func insertValidPuffs() {
            guard !toInsert.isEmpty else { return }
            puffRepo.addPuffs(toInsert)
            dumpInserted(toInsert)
            lastSeen = toInsert.last!.puffNumber
            gapRetryCount = 0
            toInsert.removeAll()
        }
    }

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

    // MARK: - Request helpers
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
                log("Backoff max reached; pausing re-requests. lastSeen=\(lastSeen)")
                gapRetryCount = 0
            }
        } else {
            self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeen), maxCount: 15)
            log("Requested from lastSeen=\(lastSeen) (no backoff)")
        }
    }
}

// Make the real Bluetooth manager the source
extension BluetoothManager: PuffsSource {}
