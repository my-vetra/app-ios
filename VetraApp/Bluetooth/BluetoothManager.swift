//
//  BluetoothManager.swift
//  VetraApp
//
//  A non-UI BLE central manager with logging, restoration, safe timers,
//  and lightweight presence/expiry to drive the "Connect" affordance.
//
//  This class is responsible for:
//  - Scanning, discovery and user-initiated connection
//  - Service/characteristic discovery and subscriptions
//  - Backfill requests/queues for puffs and phases
//  - Periodic keep-alive reads while connected
//  - Publishing connection and data events to the rest of the app
//

import CoreBluetooth
import Combine
import Foundation
import os
import UIKit

// MARK: - BluetoothManager

final class BluetoothManager: NSObject, ObservableObject {

    // MARK: Published state (UI-facing)

    /// True while the peripheral is connected.
    @Published var isConnected = false

    /// The name of the connected peripheral (if any).
    @Published var peripheralName: String?

    /// Current CoreBluetooth manager state.
    @Published var bluetoothState: CBManagerState = .unknown

    /// Transient name shown when a device is discovered but not yet connected.
    /// Cleared automatically if we haven’t re-seen the device recently.
    @Published var discoveredPeripheralName: String?
    
    ///True while the peripheral was ever connected.
    @Published var everConnected = false
    private var lastConnectedIdentifier: UUID?

    // MARK: BLE Core

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let centralQueue = DispatchQueue(label: "ble.central.queue")

    // MARK: Services & Characteristics

    private let serviceUUID                 = CBUUID(string: "56a63ec7-0623-4242-9a66-f2ad8f9f270b")
    private let ntpCharacteristicUUID       = CBUUID(string: "c8646c82-aa4b-4ac8-b6d5-cb45677ebcaa")
    private let keepAliveCharacteristicUUID = CBUUID(string: "ac4678ba-8131-4a70-8ffd-a7c7f0ed23b0")
    private let puffCharacteristicUUID     = CBUUID(string: "cedf9ce5-2953-4d18-b38c-100a3a90f987")
    private let phaseCharacteristicUUID = CBUUID(string: "9016b7fe-7192-40ce-8a83-451fc2ae5a97")
    private let loggerCharacteristicUUID    = CBUUID(string: "332e04f5-7a8a-491d-a730-f4748a6116e2")


    private var ntpCharacteristic: CBCharacteristic?
    private var keepAliveCharacteristic: CBCharacteristic?
    private var puffCharacteristic: CBCharacteristic?
    private var phaseCharacteristic: CBCharacteristic?
    private var loggerCharacteristic: CBCharacteristic?

    private var isPuffNotifyOn = false
    private var isPhaseNotifyOn = false
    private var isLoggerNotifyOn = false

    // MARK: Timers

    private var keepAliveSource: DispatchSourceTimer?   // while connected
    private var presenceTimer: DispatchSourceTimer?     // while scanning (discovery expiry)
    private var lastDiscoveryAt: Date?

    // MARK: Data publishers (bridge-facing)

    let puffBatchPublisher   = PassthroughSubject<[PuffModel], Never>()
    let puffBackfillComplete = PassthroughSubject<Void, Never>()

    let phaseBatchPublisher   = PassthroughSubject<[PartialPhaseModel], Never>()
    let phaseBackfillComplete = PassthroughSubject<Void, Never>()

    let connectionPublisher   = PassthroughSubject<Bool, Never>()

    // MARK: Outbound request queues

    private var pendingPuffRequests: [Data] = []   // flushed when notify/indicate is active
    private var pendingPhaseRequests: [Data] = []

    // MARK: Reconnect policy

    private var connectRetryAttempts = 0
    private let connectRetryMax = 3

    // MARK: Logging

    private let logger = Logger(subsystem: "com.vetra.app", category: "BLE")
    private func log(_ msg: String) { logger.debug("[BLE] \(msg, privacy: .public)") }

    // MARK: Lifecycle

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        centralManager = CBCentralManager(
            delegate: self,
            queue: centralQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.vetra.central"]
        )
        bluetoothState = centralManager.state
    }

    deinit {
        stopKeepAliveTimer()
        stopPresenceTimer()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API (used by SyncBridge)

    /// Ask device to send puffs strictly greater than `startAfter`. Optional cap with `maxCount`.
    /// Wire format (LE): [u8 msgType=0x10][u16 startAfter][u8 maxCount] (0 => device default)
    func requestPuffs(startAfter: UInt16, maxCount: UInt8? = nil) {
        var payload = Data()
        payload.append(0x10)
        payload.append(contentsOf: Self.leBytes(of: startAfter))
        payload.append(maxCount ?? 0)

        log("Queue requestPuffs startAfter=\(startAfter) maxCount=\(maxCount ?? 0)")
        pendingPuffRequests.append(payload)
        flushPuffQueueIfReady()
    }

    /// Ask device to send phases strictly greater than `startAfter`. Optional cap with `maxCount`.
    /// Wire format (LE): [u8 msgType=0x10][u16 startAfter][u8 maxCount] (0 => device default)
    func requestPhases(startAfter: UInt16, maxCount: UInt8? = nil) {
        var payload = Data()
        payload.append(0x10)
        payload.append(contentsOf: Self.leBytes(of: startAfter))
        payload.append(maxCount ?? 0)

        log("Queue requestPhases startAfter=\(startAfter) maxCount=\(maxCount ?? 0)")
        pendingPhaseRequests.append(payload)
        flushPhaseQueueIfReady()
    }

    /// Connect to the most recently discovered peripheral (user-initiated).
    func connectDiscovered() {
        guard let p = peripheral else { return }
        connectRetryAttempts = 0
        centralManager.connect(p, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state -> \(central.state.rawValue)")

        if central.state == .poweredOn {
            bluetoothState = .poweredOn
            log("Powered on; scanning for service \(serviceUUID)")
            centralManager.scanForPeripherals(withServices: [serviceUUID],
                                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            bluetoothState = .unknown
            // Publish on main to avoid @Published threading issues
            DispatchQueue.main.async {
                self.isConnected = false
                self.discoveredPeripheralName = nil
                self.connectionPublisher.send(false)
            }
            stopPresenceTimer()
            log("State \(central.state.rawValue) — marked disconnected")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("willRestoreState keys: \(Array(dict.keys))")

        if
            let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let p = restoredPeripherals.first
        {
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
                central.scanForPeripherals(withServices: [serviceUUID],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        } else {
            log("No peripherals in restore state; scanning…")
            central.scanForPeripherals(withServices: [serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var name: String = ""
        DispatchQueue.main.async {
            name = peripheral.name ?? "Unknown"
            self.discoveredPeripheralName = name
        }
        
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        self.lastDiscoveryAt = Date()

        startPresenceTimer()
        
        if self.everConnected,
           let lastId = self.lastConnectedIdentifier,
           peripheral.identifier == lastId {
            central.stopScan()
            central.connect(peripheral, options: nil)
            return
        }

        log("Discovered \(name) RSSI=\(RSSI) — waiting for user to connect")
        // Note: we intentionally keep scanning; presenceTimer expires the popup if the device disappears.
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectRetryAttempts = 0

        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionPublisher.send(true)
            self.peripheralName = peripheral.name ?? "unknown-device"
            self.discoveredPeripheralName = nil
            self.everConnected = true
        }

        self.peripheral = peripheral
        self.peripheral?.delegate = self
        
        self.lastConnectedIdentifier = peripheral.identifier

        log("Connected to \(peripheral.name ?? "unknown-device"); discovering services…")
        peripheral.discoverServices([serviceUUID])
        startKeepAliveTimer()
        stopPresenceTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect \(peripheral.name ?? "Unknown"): \(error?.localizedDescription ?? "nil")")

        DispatchQueue.main.async { self.discoveredPeripheralName = nil }

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

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("Disconnected from \(peripheral.name ?? "Unknown"): \(String(describing: error))")

        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionPublisher.send(false)
            self.discoveredPeripheralName = nil
        }

        stopKeepAliveTimer()
        startPresenceTimer() // re-arm expiry while scanning

        // Reset readiness + drop queued requests (fresh handshake next time)
        isPuffNotifyOn = false
        pendingPuffRequests.removeAll()

        isPhaseNotifyOn = false
        pendingPhaseRequests.removeAll()

        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        log("didDiscoverServices (error: \(String(describing: error)))")
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == serviceUUID {
            log("Discovering characteristics for service \(serviceUUID)…")
            peripheral.discoverCharacteristics(
                [
                    ntpCharacteristicUUID,
                    keepAliveCharacteristicUUID,
                    puffCharacteristicUUID,
                    phaseCharacteristicUUID,
                    loggerCharacteristicUUID
                ],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }

        for c in characteristics {
            switch c.uuid {
            case ntpCharacteristicUUID:
                ntpCharacteristic = c
                log("Found NTP characteristic")
                sendNTP()

            case keepAliveCharacteristicUUID:
                keepAliveCharacteristic = c
                log("Found KeepAlive characteristic")

            case puffCharacteristicUUID:
                puffCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                log("Found Puff characteristic")

            case phaseCharacteristicUUID:
                phaseCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                log("Found Phase characteristic")

            case loggerCharacteristicUUID:
                loggerCharacteristic = c
                let props = c.properties
                log("Found Logger characteristic (notify=\(props.contains(.notify)) indicate=\(props.contains(.indicate)))")
                peripheral.discoverDescriptors(for: c)
                if props.contains(.notify) || props.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                } else {
                    log("Logger not notifiable — check firmware props/CCCD")
                }

            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            log("Descriptor discovery error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        let ids = (characteristic.descriptors ?? []).map { $0.uuid.uuidString }
        log("Descriptors for \(characteristic.uuid): \(ids)")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        if let error = error {
            log("Descriptor value update error for \(descriptor.uuid): \(error.localizedDescription)")
            return
        }
        log("Descriptor \(descriptor.uuid) value=\(String(describing: descriptor.value))")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        log("Notify/Indicate state changed for \(characteristic.uuid): isNotifying=\(characteristic.isNotifying), error=\(String(describing: error))")
        guard error == nil else { return }

        switch characteristic.uuid {
        case puffCharacteristicUUID:
            isPuffNotifyOn = characteristic.isNotifying
            log("Puffs subscribed: \(isPuffNotifyOn)")
            if isPuffNotifyOn { flushPuffQueueIfReady() }

        case phaseCharacteristicUUID:
            isPhaseNotifyOn = characteristic.isNotifying
            log("Phases subscribed: \(isPhaseNotifyOn)")
            if isPhaseNotifyOn { flushPhaseQueueIfReady() }

        case loggerCharacteristicUUID:
            isLoggerNotifyOn = characteristic.isNotifying
            log("Logger subscribed: \(isLoggerNotifyOn)")

        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
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

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            log("Error receiving updated value: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case puffCharacteristicUUID:
            handlePuffPayload(data)
        case phaseCharacteristicUUID:
            handlePhasePayload(data)
        case ntpCharacteristicUUID:
            if let s = String(data: data, encoding: .utf8) { log("NTP response: \(s)") }
        case keepAliveCharacteristicUUID:
            // keep-alive ACK; nothing to do
            break
        case loggerCharacteristicUUID:
            handleLoggerPayload(data)
        default:
            break
        }
    }
}

// MARK: - KeepAlive

private extension BluetoothManager {

    /// Send epoch seconds to the device (LE u32).
    func sendNTP() {
        guard let ntp = ntpCharacteristic, let p = peripheral else { return }
        var now = UInt32(Date().timeIntervalSince1970).littleEndian
        let data = withUnsafeBytes(of: &now) { Data($0) }
        p.writeValue(data, for: ntp, type: .withResponse)
        log("Sent NTP epoch seconds")
    }

    func startKeepAliveTimer() {
        stopKeepAliveTimer()
        let src = DispatchSource.makeTimerSource(queue: centralQueue)
        src.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        src.setEventHandler { [weak self] in self?.keepAlive() }
        src.resume()
        keepAliveSource = src
        log("KeepAlive timer started (20s, GCD)")
    }

    func stopKeepAliveTimer() {
        if keepAliveSource != nil {
            keepAliveSource?.cancel()
            keepAliveSource = nil
            log("KeepAlive timer stopped")
        }
    }

    func keepAlive() {
        guard let keepAliveChar = keepAliveCharacteristic, let peripheral = peripheral else { return }
        peripheral.readValue(for: keepAliveChar)
    }

    @objc func appDidEnterBackground() {
        stopKeepAliveTimer()
    }

    @objc func appWillEnterForeground() {
        if isConnected { startKeepAliveTimer() }
    }
}

// MARK: - Discovery presence (expiry for "Connect" popup)

private extension BluetoothManager {

    /// Start a lightweight presence monitor. If we don't re-see the device for ~2s,
    /// clear `discoveredPeripheralName` so the UI hides the connect prompt.
    func startPresenceTimer() {
        if presenceTimer != nil { return }
        let src = DispatchSource.makeTimerSource(queue: centralQueue)
        src.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.isConnected == false else { return }
            if self.discoveredPeripheralName != nil,
               let last = self.lastDiscoveryAt,
               Date().timeIntervalSince(last) > 2 {
                self.log("Discovery expired — clearing connect popup")
                DispatchQueue.main.async { self.discoveredPeripheralName = nil }
           }
        }
        src.resume()
        presenceTimer = src
    }

    func stopPresenceTimer() {
        presenceTimer?.cancel()
        presenceTimer = nil
    }
}

// MARK: - Parsing

private extension BluetoothManager {

    /// Puff frames:
    ///   Batch: [u8 0x01][u16 firstPuffNumber][u8 count] + count * Puff(9B)
    ///   Done : [u8 0x02]
    func handlePuffPayload(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01:
            if let batch = parsePuffBatch(data) {
                dumpPuffs(batch, label: "Parsed puff batch")
                puffBatchPublisher.send(batch)
            } else {
                log("Failed to parse puff batch")
            }
        case 0x02:
            log("Puff backfill DONE")
            puffBackfillComplete.send(())
        default:
            log("Unknown puff message type: \(type)")
        }
    }

    func parsePuffBatch(_ data: Data) -> [PuffModel]? {
        var idx = 0
        guard data.count >= 1 + 2 + 1 else { return nil }  // header guard
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPuff = data.readLEU16(&idx)
        let count     = data.readU8(&idx)

        let stride = 9 // u16 puffNumber, u32 ts, u16 duration_ms, u8 phaseIndex
        guard data.count == idx + Int(count) * stride else {
            log("Puff batch length mismatch: data=\(data.count) idx=\(idx) count=\(count) stride=\(stride)")
            return nil
        }

        var items: [PuffModel] = []
        items.reserveCapacity(Int(count))

        for _ in 0..<count {
            let puffNumber  = Int(data.readLEU16(&idx))
            let tsSeconds   = TimeInterval(data.readLEU32(&idx))
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

        if let first = items.first, first.puffNumber != Int(firstPuff) {
            log("Header/payload puffNumber mismatch: header=\(firstPuff) payloadFirst=\(first.puffNumber)")
        }
        return items
    }

    /// Phase frames:
    ///   Batch: [u8 0x01][u16 firstPhaseIndex][u8 count] + count * Phase(5B)
    ///   Done : [u8 0x02]
    func handlePhasePayload(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01:
            if let batch = parsePhaseBatch(data) {
                dumpPhases(batch, label: "Parsed phase batch")
                phaseBatchPublisher.send(batch)
            } else {
                log("Failed to parse phase batch")
            }
        case 0x02:
            log("Phase backfill DONE")
            phaseBackfillComplete.send(())
        default:
            log("Unknown phase message type: \(type)")
        }
    }

    func parsePhaseBatch(_ data: Data) -> [PartialPhaseModel]? {
        var idx = 0
        guard data.count >= 1 + 2 + 1 else { return nil }  // header guard
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPhase = data.readLEU16(&idx)
        let count      = data.readU8(&idx)

        let stride = 5 // u8 phaseIndex, u32 startSeconds
        guard data.count == idx + Int(count) * stride else {
            log("Phase batch length mismatch: data=\(data.count) idx=\(idx) count=\(count) stride=\(stride)")
            return nil
        }

        var items: [PartialPhaseModel] = []
        items.reserveCapacity(Int(count))

        for _ in 0..<count {
            let phaseIndex = Int(data.readU8(&idx))
            let startTs    = TimeInterval(data.readLEU32(&idx))

            let active = PartialPhaseModel(
                phaseIndex: phaseIndex,
                phaseStartDate: Date(timeIntervalSince1970: startTs)
            )
            items.append(active)
        }

        if let first = items.first, first.phaseIndex != Int(firstPhase) {
            log("Header/payload phaseIndex mismatch: header=\(firstPhase) payloadFirst=\(first.phaseIndex)")
        }
        return items
    }
}

// MARK: - Request flushing (private)

private extension BluetoothManager {
    func flushPuffQueueIfReady() {
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

    func flushPhaseQueueIfReady() {
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
}


// MARK: - Utilities

private extension BluetoothManager {

    static func leBytes(of v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private var puffDumpLimit: Int { 10 }
    private var phaseDumpLimit: Int { 10 }

    func dumpPuffs(_ items: [PuffModel], label: String) {
        guard !items.isEmpty else { return }
        let shown = items.prefix(puffDumpLimit)
        let iso = ISO8601DateFormatter()
        log("\(label): \(items.count) item(s)")
        for p in shown {
            let tsStr  = iso.string(from: p.timestamp)
            let durStr = String(format: "%.3f", p.duration)
            log("  #pn=\(p.puffNumber) ts=\(tsStr) dur=\(durStr)s phase=\(p.phaseIndex)")
        }
        if items.count > shown.count {
            log("  …and \(items.count - shown.count) more")
        }
    }

    func dumpPhases(_ items: [PartialPhaseModel], label: String) {
        guard !items.isEmpty else { return }
        let shown = items.prefix(phaseDumpLimit)
        let iso = ISO8601DateFormatter()
        log("\(label): \(items.count) item(s)")
        for p in shown {
            let sdStr = iso.string(from: p.phaseStartDate)
            log("  #pi=\(p.phaseIndex) sd=\(sdStr)")
        }
        if items.count > shown.count {
            log("  …and \(items.count - shown.count) more")
        }
    }
}

// MARK: - Data helpers (LE)

private extension Data {
    func readU8(_ idx: inout Int) -> UInt8 {
        defer { idx += 1 }
        return self[idx]
    }

    func readLEU16(_ idx: inout Int) -> UInt16 {
        let v = UInt16(self[idx]) | (UInt16(self[idx + 1]) << 8)
        idx += 2
        return v
    }

    func readLEU32(_ idx: inout Int) -> UInt32 {
        let b0 = UInt32(self[idx])
        let b1 = UInt32(self[idx + 1]) << 8
        let b2 = UInt32(self[idx + 2]) << 16
        let b3 = UInt32(self[idx + 3]) << 24
        idx += 4
        return b0 | b1 | b2 | b3
    }
}

// MARK: - Firmware logger helper

private let fwLogger = Logger(subsystem: "com.vetra.app", category: "FW")

private func hex(_ data: Data, limit: Int = 256) -> String {
    let bytes = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return data.count > limit ? "\(bytes) …(+\(data.count - limit)B)" : bytes
}

private func handleLoggerPayload(_ data: Data) {
    if let s = String(data: data, encoding: .utf8), !s.isEmpty {
        fwLogger.info("[FW] \(s, privacy: .public)")
    } else {
        fwLogger.info("[FW] hex=\(hex(data, limit: 64), privacy: .public)")
    }
}
