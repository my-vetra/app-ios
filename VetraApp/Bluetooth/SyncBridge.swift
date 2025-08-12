//
//  SyncBridge.swift
//  VetraApp
//
//  Bridges BLE events into Core Data repositories and manages delta requests.
//  Uses a background writer context; processed off-main.
//

import Foundation
import Combine
import CoreData
import os

/// BLE source abstraction (for DI/testing)
protocol DataSource {
    var puffBatchPublisher: PassthroughSubject<[PuffModel], Never> { get }
    var puffBackfillComplete: PassthroughSubject<Void, Never> { get }
    var phaseBatchPublisher: PassthroughSubject<[PartialPhaseModel], Never> { get }
    var phaseBackfillComplete: PassthroughSubject<Void, Never> { get }
    var connectionPublisher: PassthroughSubject<Bool, Never> { get }
    func requestPuffs(startAfter: UInt16, maxCount: UInt8?)
    func requestPhases(startAfter: UInt16, maxCount: UInt8?)
}

/// Bridges BLE events into Core Data repositories and manages delta requests.
final class SyncBridge: ObservableObject {
    // MARK: - Dependencies
    private let source: DataSource
    private let puffRepo: PuffRepositoryCoreData
    private let phaseRepo: PhaseRepositoryCoreData

    // MARK: - State
    private var cancellables = Set<AnyCancellable>()
    private var lastSeenPuff: Int = 0
    private var isPuffsCatchingUp = false    
    private var lastSeenPhase: Int = 0
    private var isPhaseCatchingUp = false

    // Gap retry/backoff
    private var puffGapRetryCount = 0
    private var phaseGapRetryCount = 0
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
        self.phaseRepo = PhaseRepositoryCoreData(context: context)
        self.lastSeenPuff = puffRepo.maxPuffNumber()
        self.lastSeenPhase = phaseRepo.getActivePhaseIndex()
        log("Init(test): lastSeenPuff=\(self.lastSeenPuff)")
        log("Init(test): lastSeenPhase=\(self.lastSeenPhase)")
        bind()
    }

    /// Test code path
    init(source: DataSource, context: NSManagedObjectContext,
         processingQueue: DispatchQueue = DispatchQueue(label: "sync.bridge.queue")) {
        self.processingQueue = processingQueue
        self.source   = source
        self.puffRepo = PuffRepositoryCoreData(context: context)
        self.phaseRepo = PhaseRepositoryCoreData(context: context)
        self.lastSeenPuff = puffRepo.maxPuffNumber()
        self.lastSeenPhase = phaseRepo.getActivePhaseIndex()
        log("Init(test): lastSeenPuff=\(self.lastSeenPuff)")
        log("Init(test): lastSeenPhase=\(self.lastSeenPhase)")
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
                    self.lastSeenPuff = self.puffRepo.maxPuffNumber()
                    self.lastSeenPhase = self.phaseRepo.getActivePhaseIndex()
                    self.log("Connected. lastSeenPuff=\(self.lastSeenPuff) requesting backfill…")
                    self.log("Connected. lastSeenPhase=\(self.lastSeenPhase) requesting backfill…")
                    self.isPuffsCatchingUp = true
                    self.isPhaseCatchingUp = true
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeenPuff), maxCount: 50)
                    self.source.requestPhases(startAfter: UInt16(clamping: self.lastSeenPhase), maxCount: 50)
                } else {
                    self.isPuffsCatchingUp = false
                    self.isPhaseCatchingUp = false
                    self.log("Disconnected.")
                }
            }
            .store(in: &cancellables)

        // Puffs stream — process off-main to keep UI smooth
        source.puffBatchPublisher
            .receive(on: processingQueue)
            .sink { [weak self] batch in
                self?.handlePuffs(batch)
            }
            .store(in: &cancellables)

        // Puffs Backfill done
        source.puffBackfillComplete
            .receive(on: processingQueue)
            .sink { [weak self] in
                self?.isPuffsCatchingUp = false
                self?.log("Puff Backfill complete. Live mode engaged.")
            }
            .store(in: &cancellables)

        // Phase stream — process off-main to keep UI smooth
        source.phaseBatchPublisher
            .receive(on: processingQueue)
            .sink { [weak self] batch in
                self?.handlePhases(batch)
            }
            .store(in: &cancellables)

        // Phase Backfill done
        source.phaseBackfillComplete
            .receive(on: processingQueue)
            .sink { [weak self] in
                self?.isPhaseCatchingUp = false
                self?.log("Phase Backfill complete. Live mode engaged.")
            }
            .store(in: &cancellables)
    }

    // MARK: - Delta ingest
    private func handlePhases(_ items: [PartialPhaseModel]) {
        guard !items.isEmpty else { return }
        var expected = lastSeenPhase + 1
        var toUpdate: [PartialPhaseModel] = []

        for p in items {
            switch p.phaseIndex {
            case ..<expected:
                continue
            case expected:
                toUpdate.append(p);
                expected += 1
            default:
                updateValidPhases()
                log("Gap detected: expected=\(expected) got=\(p.phaseIndex). Requesting from lastSeenPhase=\(lastSeenPhase) with backoff…")
                requestFromLastSeenPhase(withBackoff: true)
                return
            }
        }

        updateValidPhases()

        if isPhaseCatchingUp {
            log("Still catching up — requesting from lastSeenPhase=\(lastSeenPhase)")
            requestFromLastSeenPhase(withBackoff: false)
        }

        func updateValidPhases() {
            guard !toUpdate.isEmpty else { return }
            phaseRepo.updatePhases(toUpdate)
            lastSeenPhase = toUpdate.last!.phaseIndex
            phaseGapRetryCount = 0
            toUpdate.removeAll()
        }
    }

    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else { return }
        var expected = lastSeenPuff + 1
        var toInsert: [PuffModel] = []

        for p in items {
            switch p.puffNumber {
            case ..<expected:
                continue
            case expected:
                toInsert.append(p); expected += 1
            default:
                insertValidPuffs()
                log("Gap detected: expected=\(expected) got=\(p.puffNumber). Requesting from lastSeenPuff=\(lastSeenPuff) with backoff…")
                requestFromLastSeenPuff(withBackoff: true)
                return
            }
        }

        insertValidPuffs()

        if isPuffsCatchingUp {
            log("Still catching up — requesting from lastSeenPuff=\(lastSeenPuff)")
            requestFromLastSeenPuff(withBackoff: false)
        }

        func insertValidPuffs() {
            guard !toInsert.isEmpty else { return }
            puffRepo.addPuffs(toInsert)
            lastSeenPuff = toInsert.last!.puffNumber
            puffGapRetryCount = 0
            toInsert.removeAll()
        }
    }
    // MARK: - Request helpers
    private func requestFromLastSeenPuff(withBackoff: Bool) {
        if withBackoff {
            puffGapRetryCount += 1
            log("requestFromLastSeenPuff(withBackoff=true) attempt=\(puffGapRetryCount)/\(gapRetryMax) lastSeen=\(lastSeenPuff)")
            if puffGapRetryCount <= gapRetryMax {
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeenPuff), maxCount: 50)
                    self.log("Re-requested from lastSeenPuff=\(self.lastSeenPuff) after backoff=\(self.gapRetryDelay)s")
                }
            } else {
                log("Backoff max reached; pausing re-requests. lastSeenPuff=\(lastSeenPuff)")
                puffGapRetryCount = 0
            }
        } else {
            self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeenPuff), maxCount: 15)
            log("Requested from lastSeenPuff=\(lastSeenPuff) (no backoff)")
        }
    }
    
    private func requestFromLastSeenPhase(withBackoff: Bool) {
        if withBackoff {
            phaseGapRetryCount += 1
            log("requestFromLastSeenPhase(withBackoff=true) attempt=\(phaseGapRetryCount)/\(gapRetryMax) lastSeen=\(lastSeenPhase)")
            if phaseGapRetryCount <= gapRetryMax {
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPhases(startAfter: UInt16(clamping: self.lastSeenPhase), maxCount: 50)
                    self.log("Re-requested from lastSeenPhase=\(self.lastSeenPhase) after backoff=\(self.gapRetryDelay)s")
                }
            } else {
                log("Backoff max reached; pausing re-requests. lastSeenPhase=\(lastSeenPhase)")
                phaseGapRetryCount = 0
            }
        } else {
            self.source.requestPhases(startAfter: UInt16(clamping: self.lastSeenPhase), maxCount: 15)
            log("Requested from lastSeenPhase=\(lastSeenPhase) (no backoff)")
        }
    }
}

// Make the real Bluetooth manager the source
extension BluetoothManager: DataSource {}
