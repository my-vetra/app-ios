import SwiftUI
import CoreBluetooth
import Combine

final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected = false
    @Published var peripheralName: String = "Vetra"

    // BLE Core
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?

    // Service/Characteristics
    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")

    private let ntpCharacteristicUUID         = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")
    private let keepAliveCharacteristicUUID   = CBUUID(string: "12345678-1234-5678-1234-56789abcdef4")

    // NEW: south-side data model chars
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

    // Native Bluetooth state
    @Published var bluetoothState: CBManagerState = .unknown

    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API used by SyncBridge

    /// Ask device to send puffs strictly greater than `startAfter`. Optional cap with `maxCount`.
    /// Request wire format (all LE):
    /// [u8 msgType=0x10][u16 startAfter][u8 maxCount]
    func requestPuffs(startAfter: UInt16, maxCount: UInt8? = nil) {
        guard let peripheral, let puffsChar = puffsCharacteristic else { return }
        var payload = Data()
        payload.append(0x10) // request message
        payload.append(contentsOf: Self.leBytes(of: startAfter))
        payload.append(maxCount ?? 0) // 0 means "device default"
        peripheral.writeValue(payload, for: puffsChar, type: .withResponse)
    }

    /// One-shot read of ActivePhase (for instant UI bootstrap).
    func readActivePhase() {
        guard let peripheral, let c = activePhaseCharacteristic else { return }
        peripheral.readValue(for: c)
    }

    // MARK: - Central delegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            bluetoothState = .poweredOn
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            bluetoothState = .unknown
            isConnected = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        centralManager.stopScan()
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.isConnected = true
        self.connectionPublisher.send(true)
        peripheralName = peripheral.name ?? "Sylo"
        peripheral.discoverServices([serviceUUID])
        startKeepAliveTimer()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionPublisher.send(false)
            self.keepAliveTimer?.invalidate()
            self.keepAliveTimer = nil
            self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: nil)
        }
    }

    // MARK: - Peripheral delegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
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
            case ntpCharacteristicUUID:         ntpCharacteristic = c
            case keepAliveCharacteristicUUID:   keepAliveCharacteristic = c

            case puffsCharacteristicUUID:
                puffsCharacteristic = c
                peripheral.setNotifyValue(true, for: c)

            case activePhaseCharacteristicUUID:
                activePhaseCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                // Optional immediate bootstrap
                readActivePhase()

            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == puffsCharacteristicUUID {
            handlePuffsPayload(data)
        } else if characteristic.uuid == activePhaseCharacteristicUUID {
            if let ap = Self.parseActivePhase(data) {
                activePhasePublisher.send(ap)
            }
        } else if characteristic.uuid == ntpCharacteristicUUID {
            if let s = String(data: data, encoding: .utf8) { print("NTP response: \(s)") }
        } else if characteristic.uuid == keepAliveCharacteristicUUID {
            print("KeepAlive ack")
        }
    }

    // MARK: - KeepAlive

    private func startKeepAliveTimer() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.keepAlive()
        }
    }

    private func keepAlive() {
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
                puffsBatchPublisher.send(batch)
            }
        case 0x02: // done
            puffsBackfillComplete.send(())
        default:
            print("Unknown puffs message type: \(type)")
        }
    }

    private static func parsePuffsBatch(_ data: Data) -> [PuffModel]? {
        var idx = 0
        guard data.count >= 1 else { return nil }
        let msgType = data.readU8(&idx)
        guard msgType == 0x01 else { return nil }

        let firstPuff = data.readLEU16(&idx)
        let count     = data.readU8(&idx)

        let stride = 9 // u16 puffNumber, u32 ts, u16 duration_ms, u8 phaseIndex
        guard data.count == idx + Int(count) * stride else {
            print("Puffs batch length mismatch")
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
            print("Header/payload puffNumber mismatch: \(firstPuff) vs \(first.puffNumber)")
        }
        return items
    }

    private static func parseActivePhase(_ data: Data) -> ActivePhaseModel? {
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
