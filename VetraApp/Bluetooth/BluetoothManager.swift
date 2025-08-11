// =============================================
// BluetoothManager.swift (App) — with logging
// =============================================

import SwiftUI
import CoreBluetooth
import Combine

final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected = false
    @Published var peripheralName: String?

    // BLE Core
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    // Service/Characteristics
    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")

    private let ntpCharacteristicUUID         = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")
    private let keepAliveCharacteristicUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef4")

    // south-side data model chars
    private let puffsCharacteristicUUID       = CBUUID(string: "12345678-1234-5678-1234-56789abcdef5")
    private let activePhaseCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef6")

    private var ntpCharacteristic: CBCharacteristic?
    private var keepAliveCharacteristic: CBCharacteristic?
    private var puffsCharacteristic: CBCharacteristic?
    private var activePhaseCharacteristic: CBCharacteristic?

    private var keepAliveTimer: Timer?

    // Publishers to the bridge
    let puffsBatchPublisher        = PassthroughSubject<[PuffModel], Never>()
    let puffsBackfillComplete      = PassthroughSubject<Void, Never>()
    let activePhasePublisher       = PassthroughSubject<ActivePhaseModel, Never>()
    let connectionPublisher        = PassthroughSubject<Bool, Never>()
    
    private var pendingPuffsRequests: [Data] = []
    private var isPuffsNotifyOn = false // true for either notifications or indications
    
    // Native Bluetooth state
    @Published var bluetoothState: CBManagerState = .unknown

    // MARK: - Log helper
    private func log(_ msg: String) { print("[BLE] \(msg)") }

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
        log("Init CBCentralManager")
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
        pendingPuffsRequests.append(payload)
        flushPuffsQueueIfReady()
    }
    
    private func flushPuffsQueueIfReady() {
        guard isPuffsNotifyOn,
              let peripheral = peripheral,
              let puffsChar = puffsCharacteristic
        else { return }

        log("Flushing \(pendingPuffsRequests.count) queued puffs request(s)")
        while !pendingPuffsRequests.isEmpty {
            let payload = pendingPuffsRequests.removeFirst()
            peripheral.writeValue(payload, for: puffsChar, type: .withResponse)
            log("Sent Puffs request (len=\(payload.count))")
        }
    }

    /// One-shot read of ActivePhase (for instant UI bootstrap).
    func readActivePhase() {
        guard let peripheral, let c = activePhaseCharacteristic else { return }
        log("Reading ActivePhase characteristic…")
        peripheral.readValue(for: c)
    }

    // MARK: - Central delegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state -> \(central.state)")
        if central.state == .poweredOn {
            bluetoothState = .poweredOn
            log("Powered on; scanning for service \(serviceUUID)")
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            bluetoothState = .unknown
            isConnected = false
            log("State \(central.state) — marked disconnected")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        log("Discovered \(peripheral.name ?? "Unknown") RSSI=\(RSSI)")
        centralManager.stopScan()
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.isConnected = true
        self.connectionPublisher.send(true)
        peripheralName = peripheral.name ?? "Vetra"
        log("Connected to \(peripheralName!); discovering services…")
        peripheral.discoverServices([serviceUUID])
        // Re-enable KeepAlive schedule (safe no-op until char is discovered)
        startKeepAliveTimer()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected from \(peripheral.name ?? "Unknown"): \(String(describing: error))")
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionPublisher.send(false)
            self.keepAliveTimer?.invalidate()
            self.keepAliveTimer = nil

            // Reset readiness + drop queued requests (fresh handshake next time)
            self.isPuffsNotifyOn = false
            self.pendingPuffsRequests.removeAll()

            self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: nil)
        }
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
                    puffsCharacteristicUUID,
                    activePhaseCharacteristicUUID
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

            case puffsCharacteristicUUID:
                puffsCharacteristic = c
                peripheral.setNotifyValue(true, for: c) // subscribe to notify/indicate
                log("Subscribed to Puffs (notify/indicate)")

            case activePhaseCharacteristicUUID:
                activePhaseCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                log("Subscribed to ActivePhase; bootstrapping read…")
                // Optional immediate bootstrap
                readActivePhase()

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        log("didUpdateValueFor \(characteristic.uuid) (len=\(characteristic.value?.count ?? 0), error: \(String(describing: error)))")
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == puffsCharacteristicUUID {
            log("RX Puffs payload: \(data.count) bytes")
            if characteristic.uuid == puffsCharacteristicUUID {
                print("[BLE] RAW Puffs (\(data.count)B): \(hex(data))")
                handlePuffsPayload(data)
            }
            
            handlePuffsPayload(data)

        } else if characteristic.uuid == activePhaseCharacteristicUUID {
            if let ap = Self.parseActivePhase(data) {
                log("RX ActivePhase: phaseIndex=\(ap.phaseIndex), start=\(ap.phaseStartDate)")
                activePhasePublisher.send(ap)
            }

        } else if characteristic.uuid == ntpCharacteristicUUID {
            if let s = String(data: data, encoding: .utf8) { log("NTP response: \(s)") }

        } else if characteristic.uuid == keepAliveCharacteristicUUID {
            log("KeepAlive ack")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        log("Notify/Indicate state changed for \(characteristic.uuid): isNotifying=\(characteristic.isNotifying), error=\(String(describing: error))")
        guard error == nil else { return }

        if characteristic.uuid == puffsCharacteristicUUID {
            isPuffsNotifyOn = characteristic.isNotifying
            log("Puffs subscribed: \(isPuffsNotifyOn)")
            if isPuffsNotifyOn {
                flushPuffsQueueIfReady()
            }
        } else if characteristic.uuid == activePhaseCharacteristicUUID {
            if characteristic.isNotifying {
                // Optional: bootstrap the UI instantly
                readActivePhase()
            }
        }
    }

    // MARK: - KeepAlive

    private func startKeepAliveTimer() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.keepAlive()
        }
        log("KeepAlive timer started (20s)")
    }

    private func keepAlive() {
        log("KeepAlive tick — reading keepAlive characteristic…")
        guard let keepAliveChar = keepAliveCharacteristic, let peripheral = peripheral else { return }
        peripheral.readValue(for: keepAliveChar)
    }

    // MARK: - Parsing

    /// Puffs frames:
    /// Batch: [u8 type=0x01][u16 firstPuffNumber][u8 count] + count * Puff(9B)
    /// Done:  [u8 type=0x02]
    private func handlePuffsPayload(_ data: Data) {
        guard let type = data.first else { return }
        switch type {
        case 0x01: // batch
            if let batch = Self.parsePuffsBatch(data) {
                dumpPuffs(batch, label: "Parsed puffs batch")
                log("Parsed puffs batch: \(batch.count) item(s) — first=\(batch.first?.puffNumber ?? -1) last=\(batch.last?.puffNumber ?? -1)")
                puffsBatchPublisher.send(batch)
            } else {
                log("Failed to parse puffs batch")
            }

        case 0x02: // done
            log("Puffs backfill DONE")
            puffsBackfillComplete.send(())

        default:
            log("Unknown puffs message type: \(type)")
        }
    }

    static func parsePuffsBatch(_ data: Data) -> [PuffModel]? {
        var idx = 0
        guard data.count >= 1 else { return nil }
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPuff = data.readLEU16(&idx)
        let count     = data.readU8(&idx)

        let stride = 9 // u16 puffNumber, u32 ts, u16 duration_ms, u8 phaseIndex
        guard data.count == idx + Int(count) * stride else {
            print("[BLE] Puffs batch length mismatch: data=\(data.count) idx=\(idx) count=\(count) stride=\(stride)")
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

    static func parseActivePhase(_ data: Data) -> ActivePhaseModel? {
        var idx = 0
        guard data.count >= 5 else { return nil }
        let phaseIndex = Int(data.readU8(&idx))
        let startTs    = TimeInterval(data.readLEU32(&idx))
        return ActivePhaseModel(phaseIndex: phaseIndex, phaseStartDate: Date(timeIntervalSince1970: startTs))
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

private let puffDumpLimit = 20

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
        print("[SyncBridge]   #\(p.puffNumber) ts=\(tsStr) dur=\(durStr)s phase=\(p.phaseIndex)")
    }
    if items.count > shown.count {
        print("[BLE]   …and \(items.count - shown.count) more")
    }
}
