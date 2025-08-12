//
//  BluetoothManager.swift
//  VetraApp
//
//  Non-UI BLE central manager with logging, restoration, and safe timers.
//

import Foundation
import CoreBluetooth
import Combine
import UIKit
import os

final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // Published state surfaced to app
    @Published var isConnected = false
    @Published var peripheralName: String?
    @Published var bluetoothState: CBManagerState = .unknown

    // BLE Core
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let centralQueue = DispatchQueue(label: "ble.central.queue")

    // Services/Characteristics
    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")

    private let ntpCharacteristicUUID         = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")
    private let keepAliveCharacteristicUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef4")
    private let puffCharacteristicUUID       = CBUUID(string: "12345678-1234-5678-1234-56789abcdef5")
    private let phaseCharacteristicUUID       = CBUUID(string: "12345678-1234-5678-1234-56789abcdef6")

    private var ntpCharacteristic: CBCharacteristic?
    private var keepAliveCharacteristic: CBCharacteristic?
    private var puffCharacteristic: CBCharacteristic?
    private var phaseCharacteristic: CBCharacteristic?

    // KeepAlive via GCD timer (safe on non-main queue)
    private var keepAliveSource: DispatchSourceTimer?

    // Publishers to the bridge
    let puffBatchPublisher        = PassthroughSubject<[PuffModel], Never>()
    let puffBackfillComplete      = PassthroughSubject<Void, Never>()
    let phaseBatchPublisher        = PassthroughSubject<[PartialPhaseModel], Never>()
    let phaseBackfillComplete      = PassthroughSubject<Void, Never>()
    let connectionPublisher        = PassthroughSubject<Bool, Never>()

    // Request queueing
    private var pendingPuffRequests: [Data] = []
    private var isPuffNotifyOn = false // true for either notifications or indications
    
    // Request queueing
    private var pendingPhaseRequests: [Data] = []
    private var isPhaseNotifyOn = false // true for either notifications or indications

    // Reconnect backoff (for didFailToConnect)
    private var connectRetryAttempts = 0
    private let connectRetryMax = 3

    // Logging
    private let logger = Logger(subsystem: "com.vetra.app", category: "BLE")
    private func log(_ msg: String) { logger.debug("\(msg, privacy: .public)") }

    override init() {
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        centralManager = CBCentralManager(
            delegate: self,
            queue: centralQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.vetra.central"
            ]
        )
        
        bluetoothState = centralManager.state
    }

    deinit {
        stopKeepAliveTimer()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API used by SyncBridge

    /// Ask device to send puffs strictly greater than `startAfter`. Optional cap with `maxCount`.
    /// Request wire format (all LE):
    /// [u8 msgType=0x10][u16 startAfter][u8 maxCount] (maxCount=0 => device default)
    func requestPuffs(startAfter: UInt16, maxCount: UInt8? = nil) {
        var payload = Data()
        payload.append(0x10) // request message
        payload.append(contentsOf: Self.leBytes(of: startAfter))
        payload.append(maxCount ?? 0) // 0 = device default

        log("Queue requestPuffs startAfter=\(startAfter) maxCount=\(maxCount ?? 0)")

        // Enqueue; will auto-flush when Puffs is ready
        pendingPuffRequests.append(payload)
        flushPuffQueueIfReady()
    }
    
    /// Ask device to send phases strictly greater than `startAfter`. Optional cap with `maxCount`.
    /// Request wire format (all LE):
    /// [u8 msgType=0x10][u16 startAfter][u8 maxCount] (maxCount=0 => device default)
    func requestPhases(startAfter: UInt16, maxCount: UInt8? = nil) {
        var payload = Data()
        payload.append(0x10) // request message
        payload.append(contentsOf: Self.leBytes(of: startAfter))
        payload.append(maxCount ?? 0) // 0 = device default

        log("Queue requestPhases startAfter=\(startAfter) maxCount=\(maxCount ?? 0)")

        // Enqueue; will auto-flush when Phases is ready
        pendingPhaseRequests.append(payload)
        flushPhaseQueueIfReady()
    }


    private func flushPuffQueueIfReady() {
        guard isPuffNotifyOn,
              let peripheral = peripheral,
              let puffChar = puffCharacteristic
        else { return }

        log("Flushing \(pendingPuffRequests.count) queued puff request(s)")
        while !pendingPuffRequests.isEmpty {
            let payload = pendingPuffRequests.removeFirst()
            peripheral.writeValue(payload, for: puffChar, type: .withResponse)
            log("Sent Puff request (len=\(payload.count))")
        }
    }
    
    private func flushPhaseQueueIfReady() {
        guard isPhaseNotifyOn,
              let peripheral = peripheral,
              let phaseChar = phaseCharacteristic
        else { return }

        log("Flushing \(pendingPhaseRequests.count) queued phase request(s)")
        while !pendingPhaseRequests.isEmpty {
            let payload = pendingPhaseRequests.removeFirst()
            peripheral.writeValue(payload, for: phaseChar, type: .withResponse)
            log("Sent Phase request (len=\(payload.count))")
        }
    }

    // MARK: - Central delegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state -> \(central.state.rawValue)")
        if central.state == .poweredOn {
            bluetoothState = .poweredOn
            log("Powered on; scanning for service \(serviceUUID)")
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            bluetoothState = .unknown
            // publish on main to avoid thread-safety issues with @Published
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectionPublisher.send(false)
            }
            log("State \(central.state.rawValue) — marked disconnected")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        log("willRestoreState keys: \(Array(dict.keys))")

        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restoredPeripherals.first {
            self.peripheral = p
            p.delegate = self
            self.peripheralName = p.name ?? "unknown-device"

            if p.state == .connected {
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.connectionPublisher.send(true)
                }
                log("Restored connected peripheral; discovering services…")
                p.discoverServices([serviceUUID])
                startKeepAliveTimer()
            } else {
                log("Restored peripheral not connected; rescanning…")
                central.scanForPeripherals(withServices: [serviceUUID], options: nil)
            }
        } else {
            log("No peripherals in restore state; scanning…")
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        log("Discovered \(peripheral.name ?? "Unknown") RSSI=\(RSSI)")
        centralManager.stopScan()
        connectRetryAttempts = 0
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectRetryAttempts = 0
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionPublisher.send(true)
            self.peripheralName = peripheral.name ?? "unknown-device"
        }
        log("Connected to \(peripheral.name ?? "unknown-device"); discovering services…")
        peripheral.discoverServices([serviceUUID])
        startKeepAliveTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect \(peripheral.name ?? "Unknown"): \(error?.localizedDescription ?? "nil")")
        guard connectRetryAttempts < connectRetryMax else {
            log("Connect retry max reached; rescanning.")
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
            return
        }
        connectRetryAttempts += 1
        let delay = 0.5 + Double.random(in: 0...0.5)
        centralQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.log("Retrying connect attempt \(self.connectRetryAttempts)/\(self.connectRetryMax) after \(String(format: "%.2f", delay))s")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected from \(peripheral.name ?? "Unknown"): \(String(describing: error))")
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionPublisher.send(false)
        }

        stopKeepAliveTimer()

        // Reset readiness + drop queued requests (fresh handshake next time)
        isPuffNotifyOn = false
        pendingPuffRequests.removeAll()

        isPhaseNotifyOn = false
        pendingPhaseRequests.removeAll()

        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    // MARK: - Peripheral delegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("didDiscoverServices (error: \(String(describing: error)))")
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            log("Discovering characteristics for service \(serviceUUID)…")
            peripheral.discoverCharacteristics(
                [
                    ntpCharacteristicUUID,
                    keepAliveCharacteristicUUID,
                    puffCharacteristicUUID,
                    phaseCharacteristicUUID
                ],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for c in characteristics {
            switch c.uuid {
            case ntpCharacteristicUUID:
                ntpCharacteristic = c
                log("Found NTP characteristic")

            case keepAliveCharacteristicUUID:
                keepAliveCharacteristic = c
                log("Found KeepAlive characteristic")

            case puffCharacteristicUUID:
                puffCharacteristic = c
                peripheral.setNotifyValue(true, for: c) // subscribe to notify/indicate
                log("Found Puff characteristic")

            case phaseCharacteristicUUID:
                phaseCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                log("Found Phase characteristic")

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log("Notify/Indicate state changed for \(characteristic.uuid): isNotifying=\(characteristic.isNotifying), error=\(String(describing: error))")
        guard error == nil else { return }

        if characteristic.uuid == puffCharacteristicUUID {
            isPuffNotifyOn = characteristic.isNotifying
            log("Puffs subscribed: \(isPuffNotifyOn)")
            if isPuffNotifyOn {
                flushPuffQueueIfReady()
            }
        } else if characteristic.uuid == phaseCharacteristicUUID {
            isPhaseNotifyOn = characteristic.isNotifying
            log("Phases subscribed: \(isPhaseNotifyOn)")
            if isPhaseNotifyOn {
                flushPhaseQueueIfReady()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Puffs/Phase write failed: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == puffCharacteristicUUID {
            log("Puff write ACK")
        } else if characteristic.uuid == phaseCharacteristicUUID {
            log("Phase write ACK")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Error receiving updated value: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == puffCharacteristicUUID {
//            log("RAW Puffs (\(data.count)B): \(hex(data))")
            handlePuffPayload(data)
        } else if characteristic.uuid == phaseCharacteristicUUID {
//            log("RAW Phases (\(data.count)B): \(hex(data))")
            handlePhasePayload(data)
        } else if characteristic.uuid == ntpCharacteristicUUID {
            if let s = String(data: data, encoding: .utf8) { log("NTP response: \(s)") }
        } else if characteristic.uuid == keepAliveCharacteristicUUID {
            log("KeepAlive ack")
        }
    }

    // MARK: - KeepAlive

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        let src = DispatchSource.makeTimerSource(queue: centralQueue)
        src.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        src.setEventHandler { [weak self] in self?.keepAlive() }
        src.resume()
        keepAliveSource = src
        log("KeepAlive timer started (20s, GCD)")
    }

    private func stopKeepAliveTimer() {
        if keepAliveSource != nil {
            keepAliveSource?.cancel()
            keepAliveSource = nil
            log("KeepAlive timer stopped")
        }
    }

    private func keepAlive() {
        log("KeepAlive tick — reading keepAlive characteristic…")
        guard let keepAliveChar = keepAliveCharacteristic, let peripheral = peripheral else { return }
        peripheral.readValue(for: keepAliveChar)
    }

    @objc private func appDidEnterBackground() {
        stopKeepAliveTimer()
    }

    @objc private func appWillEnterForeground() {
        if isConnected { startKeepAliveTimer() }
    }

    // MARK: - Parsing

    /// Puffs frames:
    /// Batch: [u8 type=0x01][u16 firstPuffNumber][u8 count] + count * Puff(9B)
    /// Done:  [u8 type=0x02]
    private func handlePuffPayload(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01: // batch
            if let batch = Self.parsePuffBatch(data) {
                dumpPuffs(batch, label: "Parsed puff batch")
                puffBatchPublisher.send(batch)
            } else {
                log("Failed to parse puff batch")
            }

        case 0x02: // done
            log("Puff backfill DONE")
            puffBackfillComplete.send(())

        default:
            log("Unknown puff message type: \(type)")
        }
    }

    static func parsePuffBatch(_ data: Data) -> [PuffModel]? {
        var idx = 0
        // Guard header length before any indexed reads
        guard data.count >= 1 + 2 + 1 else { return nil }
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPuff = data.readLEU16(&idx)
        let count     = data.readU8(&idx)

        let stride = 9 // u16 puffNumber, u32 ts, u16 duration_ms, u8 phaseIndex
        guard data.count == idx + Int(count) * stride else {
            print("[BLE] Puff batch length mismatch: data=\(data.count) idx=\(idx) count=\(count) stride=\(stride)")
            return nil
        }

        var items: [PuffModel] = []
        items.reserveCapacity(Int(count))

        for _ in 0..<count {
            let puffNumber  = Int(data.readLEU16(&idx))
            let tsSeconds   = TimeInterval(data.readLEU32(&idx)) // device epoch (s)
            let durationMs  = TimeInterval(data.readLEU16(&idx))
            let phaseIndex  = Int(data.readU8(&idx))

            let puff = PuffModel(
                puffNumber: puffNumber,
                timestamp: Date(timeIntervalSince1970: tsSeconds),
                duration: durationMs / 1000.0,
                phaseIndex: phaseIndex
            )
            items.append(puff)
        }

        // Optional sanity: verify continuity with header
        if let first = items.first, first.puffNumber != Int(firstPuff) {
            print("[BLE] Header/payload puffNumber mismatch: header=\(firstPuff) payloadFirst=\(first.puffNumber)")
        }
        return items
    }

    /// Phase frames:
    /// Batch: [u8 type=0x01][u16 firstPuffIndex][u8 count] + count * Phase(5B)
    /// Done:  [u8 type=0x02]
    private func handlePhasePayload(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01: // batch
            if let batch = Self.parsePhaseBatch(data) {
                dumpPhases(batch, label: "Parsed phase batch")
                phaseBatchPublisher.send(batch)
            } else {
                log("Failed to parse phase batch")
            }

        case 0x02: // done
            log("Phase backfill DONE")
            phaseBackfillComplete.send(())

        default:
            log("Unknown phase message type: \(type)")
        }
    }

    static func parsePhaseBatch(_ data: Data) -> [PartialPhaseModel]? {
        var idx = 0
        // Guard header length before any indexed reads
        guard data.count >= 1 + 2 + 1 else { return nil }
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPhase = data.readLEU16(&idx)
        let count     = data.readU8(&idx)

        let stride = 5 // u8 phaseIndex, u32 sd
        guard data.count == idx + Int(count) * stride else {
            print("[BLE] Phase batch length mismatch: data=\(data.count) idx=\(idx) count=\(count) stride=\(stride)")
            return nil
        }

        var items: [PartialPhaseModel] = []
        items.reserveCapacity(Int(count))

        for _ in 0..<count {
            let phaseIndex  = Int(data.readU8(&idx))
            let startTs   = TimeInterval(data.readLEU32(&idx))

            let activePhase = PartialPhaseModel(
                phaseIndex: phaseIndex,
                phaseStartDate: Date(timeIntervalSince1970: startTs)
            )
            items.append(activePhase)
        }

        // Optional sanity: verify continuity with header
        if let first = items.first, first.phaseIndex != Int(firstPhase) {
            print("[BLE] Header/payload phaseIndex mismatch: header=\(firstPhase) payloadFirst=\(first.phaseIndex)")
        }
        return items
    }

    // MARK: - Utils

    private static func leBytes(of v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
}

// MARK: - Data read helpers (LE)
private extension Data {
    func readU8(_ idx: inout Int) -> UInt8 {
        defer { idx += 1 }; return self[idx]
    }
    func readLEU16(_ idx: inout Int) -> UInt16 {
        let v = UInt16(self[idx]) | (UInt16(self[idx+1]) << 8)
        idx += 2
        return v
    }
    func readLEU32(_ idx: inout Int) -> UInt32 {
        let b0 = UInt32(self[idx])
        let b1 = UInt32(self[idx+1]) << 8
        let b2 = UInt32(self[idx+2]) << 16
        let b3 = UInt32(self[idx+3]) << 24
        idx += 4
        return b0 | b1 | b2 | b3
    }
}

private let puffDumpLimit = 10
private let phaseDumpLimit = 10

private func hex(_ data: Data, limit: Int = 256) -> String {
    let bytes = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return data.count > limit ? "\(bytes) …(+\(data.count - limit)B)" : bytes
}

private func dumpPuffs(_ items: [PuffModel], label: String) {
    guard !items.isEmpty else { return }
    let shown = items.prefix(puffDumpLimit)
    let iso = ISO8601DateFormatter()
    print("[BLE] \(label): \(items.count) item(s)")
    for p in shown {
        let tsStr  = iso.string(from: p.timestamp)
        let durStr = String(format: "%.3f", p.duration)
        print("[BLE]   #\(p.puffNumber) ts=\(tsStr) dur=\(durStr)s phase=\(p.phaseIndex)")
    }
    if items.count > shown.count {
        print("[BLE]   …and \(items.count - shown.count) more")
    }
}

private func dumpPhases(_ items: [PartialPhaseModel], label: String) {
    guard !items.isEmpty else { return }
    let shown = items.prefix(phaseDumpLimit)
    let iso = ISO8601DateFormatter()
    print("[BLE] \(label): \(items.count) item(s)")
    for p in shown {
        let sdStr  = iso.string(from: p.phaseStartDate)
        print("[BLE]   #pi=\(p.phaseIndex) sd=\(sdStr)")
    }
    if items.count > shown.count {
        print("[BLE]   …and \(items.count - shown.count) more")
    }
}
