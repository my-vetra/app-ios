//
// SyncBridge.swift
// VetraApp
//
// Bridges BLE events into Core Data repositories and manages delta requests.
// Uses a background writer context; processed off-main.
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
    private var lastSeenPuff: Int = -1
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
    private func log(_ msg: String) { logger.debug("[Syc] \(msg, privacy: .public)") }
    
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
        log("Binding publishers on queue=\(String(describing: processingQueue.label))")
        
        // Connection lifecycle → request deltas
        source.connectionPublisher
            .receive(on: processingQueue)
            .sink { [weak self] connected in
                guard let self else { return }
                self.log("connectionPublisher -> connected=\(connected)")
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
                    self.log("Disconnected. Resetting catch-up flags.")
                }
            }
            .store(in: &cancellables)
        
        // Puffs stream — process off-main to keep UI smooth
        source.puffBatchPublisher
            .receive(on: processingQueue)
            .sink { [weak self] batch in
                self?.log("puffBatchPublisher -> received batch size=\(batch.count)")
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
                self?.log("phaseBatchPublisher -> received batch size=\(batch.count)")
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
        guard !items.isEmpty else {
            log("handlePhases: empty batch — nothing to do.")
            return
        }
        
        var expected = lastSeenPhase + 1
        var toUpdate: [PartialPhaseModel] = []
        var overlapCount = 0
        
        let firstIdx = items.first?.phaseIndex ?? -1
        let lastIdx  = items.last?.phaseIndex ?? -1
        log("handlePhases: received=\(items.count) lastSeenPhase=\(lastSeenPhase) expectedFirst=\(expected) batchFirst=\(firstIdx) batchLast=\(lastIdx)")
        
        for p in items {
            switch p.phaseIndex {
            case ..<expected:
                overlapCount += 1
                log("handlePhases: overlap/duplicate phaseIndex=\(p.phaseIndex) (< expected \(expected)) — skipping")
                
            case expected:
                toUpdate.append(p)
                expected += 1
                log("handlePhases: accepted phaseIndex=\(p.phaseIndex) (expected now \(expected))")
                
            default:
                updateValidPhases()
                log("Gap detected: expected=\(expected) got=\(p.phaseIndex). Requesting from lastSeenPhase=\(lastSeenPhase) with backoff…")
                requestFromLastSeenPhase(withBackoff: true)
                return
            }
        }
        
        updateValidPhases()
        
        if isPhaseCatchingUp {
            log("handlePhases: still catching up — requesting from lastSeenPhase=\(lastSeenPhase)")
            requestFromLastSeenPhase(withBackoff: false)
        } else {
            log("handlePhases: live mode — no further backfill request.")
        }
        
        if overlapCount > 0 {
            log("handlePhases: ignored \(overlapCount) overlapping/duplicate item(s)")
        }
        
        func updateValidPhases() {
            guard !toUpdate.isEmpty else {
                log("handlePhases.updateValidPhases: nothing to update (toUpdate empty)")
                return
            }
            let indices = toUpdate.map { $0.phaseIndex }
            log("handlePhases.updateValidPhases: applying \(indices.count) update(s); indices=\(indices)")
            phaseRepo.updatePhases(toUpdate)
            lastSeenPhase = toUpdate.last!.phaseIndex
            phaseGapRetryCount = 0
            log("handlePhases.updateValidPhases: lastSeenPhase -> \(lastSeenPhase); reset phaseGapRetryCount")
            toUpdate.removeAll()
        }
    }
    
    private func handlePuffs(_ items: [PuffModel]) {
        guard !items.isEmpty else {
            log("handlePuffs: empty batch — nothing to do.")
            return
        }
        
        var expected = lastSeenPuff + 1
        var toInsert: [PuffModel] = []
        var overlapCount = 0
        
        let firstNo = items.first?.puffNumber ?? -1
        let lastNo  = items.last?.puffNumber ?? -1
        log("handlePuffs: received=\(items.count) lastSeenPuff=\(lastSeenPuff) expectedFirst=\(expected) batchFirst=\(firstNo) batchLast=\(lastNo)")
        
        for p in items {
            switch p.puffNumber {
            case ..<expected:
                overlapCount += 1
                log("handlePuffs: overlap/duplicate puff=\(p.puffNumber) (< expected \(expected)) — skipping")
                
            case expected:
                toInsert.append(p)
                expected += 1
                if toInsert.count <= 5 {
                    log("handlePuffs: accepted puff=\(p.puffNumber) (toInsert now \(toInsert.count), next expected \(expected))")
                }
                // If a very large batch, avoid spamming logs for every item;
                // summary is logged later in insertValidPuffs().
                
            default:
                insertValidPuffs()
                log("Gap detected: expected=\(expected) got=\(p.puffNumber). Requesting from lastSeenPuff=\(lastSeenPuff) with backoff…")
                requestFromLastSeenPuff(withBackoff: true)
                return
            }
        }
        
        insertValidPuffs()
        
        if isPuffsCatchingUp {
            log("handlePuffs: still catching up — requesting from lastSeenPuff=\(lastSeenPuff)")
            requestFromLastSeenPuff(withBackoff: false)
        } else {
            log("handlePuffs: live mode — no further backfill request.")
        }
        
        if overlapCount > 0 {
            log("handlePuffs: ignored \(overlapCount) overlapping/duplicate item(s)")
        }
        
        func insertValidPuffs() {
            guard !toInsert.isEmpty else {
                log("handlePuffs.insertValidPuffs: nothing to insert (toInsert empty)")
                return
            }
            let first = toInsert.first!.puffNumber
            let last  = toInsert.last!.puffNumber
            log("handlePuffs.insertValidPuffs: inserting \(toInsert.count) puff(s) [#\(first)…#\(last)]")
            puffRepo.addPuffs(toInsert)
            lastSeenPuff = toInsert.last!.puffNumber
            puffGapRetryCount = 0
            log("handlePuffs.insertValidPuffs: lastSeenPuff -> \(lastSeenPuff); reset puffGapRetryCount")
            toInsert.removeAll()
        }
    }
    
    // MARK: - Request helpers
    private func requestFromLastSeenPuff(withBackoff: Bool) {
        if withBackoff {
            puffGapRetryCount += 1
            log("requestFromLastSeenPuff(withBackoff=true) attempt=\(puffGapRetryCount)/\(gapRetryMax) lastSeen=\(lastSeenPuff)")
            if puffGapRetryCount <= gapRetryMax {
                log("requestFromLastSeenPuff: scheduling re-request after \(gapRetryDelay)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeenPuff), maxCount: 50)
                    self.log("requestFromLastSeenPuff: sent re-request startAfter=\(self.lastSeenPuff) maxCount=50 after backoff")
                }
            } else {
                log("requestFromLastSeenPuff: backoff max reached; pausing re-requests. lastSeenPuff=\(lastSeenPuff)")
                puffGapRetryCount = 0
            }
        } else {
            self.source.requestPuffs(startAfter: UInt16(clamping: self.lastSeenPuff), maxCount: 15)
            log("requestFromLastSeenPuff: sent request startAfter=\(lastSeenPuff) maxCount=15 (no backoff)")
        }
    }
    
    private func requestFromLastSeenPhase(withBackoff: Bool) {
        if withBackoff {
            phaseGapRetryCount += 1
            log("requestFromLastSeenPhase(withBackoff=true) attempt=\(phaseGapRetryCount)/\(gapRetryMax) lastSeen=\(lastSeenPhase)")
            if phaseGapRetryCount <= gapRetryMax {
                log("requestFromLastSeenPhase: scheduling re-request after \(gapRetryDelay)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + gapRetryDelay) { [weak self] in
                    guard let self else { return }
                    self.source.requestPhases(startAfter: UInt16(clamping: self.lastSeenPhase), maxCount: 50)
                    self.log("requestFromLastSeenPhase: sent re-request startAfter=\(self.lastSeenPhase) maxCount=50 after backoff")
                }
            } else {
                log("requestFromLastSeenPhase: backoff max reached; pausing re-requests. lastSeenPhase=\(lastSeenPhase)")
                phaseGapRetryCount = 0
            }
        } else {
            self.source.requestPhases(startAfter: UInt16(clamping: self.lastSeenPhase), maxCount: 15)
            log("requestFromLastSeenPhase: sent request startAfter=\(lastSeenPhase) maxCount=15 (no backoff)")
        }
    }
}

// Make the real Bluetooth manager the source
extension BluetoothManager: DataSource {}
