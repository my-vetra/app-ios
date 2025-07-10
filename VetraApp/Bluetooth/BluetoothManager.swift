import SwiftUI
import CoreBluetooth

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected = false
    @Published var peripheralName: String = "Vetra"
    
    // Timer data from the SYNC characteristic (in milliseconds)
    @Published var persistentDuation: CGFloat = 0    // Field 1: Persistent Timer Total (ms)
    @Published var persistentElapsed: CGFloat = 0    // Field 2: Persistent Timer Elapsed (ms)
    @Published var coilDuration: CGFloat = 0           // Field 3: Coil Unlock Total Duration (ms)
    @Published var coilRemaining: CGFloat = 0          // Field 4: Coil Unlock Remaining (ms)
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    
    // Characteristics
    private var timerCharacteristic: CBCharacteristic?
    private var syncCharacteristic: CBCharacteristic?
    private var ntpCharacteristic: CBCharacteristic?
    private var keepAliveCharacteristic: CBCharacteristic?
    
    // UUIDs from the ESP32 firmware
    private let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef0")
    private let timerCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef1")
    private let ntpCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef2")
    private let syncCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef3")
    private let keepAliveCharacteristicUUID = CBUUID(string: "12345678-1234-5678-1234-56789abcdef4")
    
    private var keepAliveTimer: Timer?
    
    // Expose the native Bluetooth state
    @Published var bluetoothState: CBManagerState = .unknown
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
    }
    
    
    // MARK: - Bluetooth Scanning & Connection
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            bluetoothState = .poweredOn
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        } else {
            bluetoothState = .unknown
            self.isConnected = false
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
        peripheralName = peripheral.name ?? "Sylo"
        peripheral.discoverServices([serviceUUID])
        self.startKeepAliveTimer()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.keepAliveTimer?.invalidate()
            self.keepAliveTimer = nil
            self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: nil)
        }
    }
    
    // MARK: - Peripheral Delegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([timerCharacteristicUUID,
                                                    syncCharacteristicUUID,
                                                    ntpCharacteristicUUID,
                                                   keepAliveCharacteristicUUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == timerCharacteristicUUID {
                timerCharacteristic = characteristic
            } else if characteristic.uuid == syncCharacteristicUUID {
                syncCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic) // Subscribe for changes
            } else if characteristic.uuid == ntpCharacteristicUUID {
                ntpCharacteristic = characteristic
//                sendNTPTime()
            } else if characteristic.uuid == keepAliveCharacteristicUUID {
                keepAliveCharacteristic = characteristic
//                sendNTPTime()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == syncCharacteristicUUID {
            let parsed = parseSyncData(data)
            persistentDuation = parsed.persistentDuation
            persistentElapsed = parsed.persistentElapsed
            coilDuration = parsed.coilDuration
            coilRemaining = parsed.coilRemaining
        } else if characteristic.uuid == ntpCharacteristicUUID {
            if let response = String(data: data, encoding: .utf8) {
                print("NTP update response: \(response)")
            }
        } else if characteristic.uuid == timerCharacteristicUUID {
            if let response = String(data: data, encoding: .utf8) {
                print("Timer update response: \(response)")
            }
        } else if characteristic.uuid == keepAliveCharacteristicUUID {
            print("Acknowledged")
        } else {
            print("ERROR: Unknown characteristic")
        }
    }

    
    // MARK: - Parsing ESP32 Sync Data
    // Expected data format (16 bytes): four UInt32 values in little-endian order:
    // Field 1: Persistent Timer Total (ms)
    // Field 2: Persistent Timer Elapsed (ms)
    // Field 3: Coil Unlock Total Duration (ms)
    // Field 4: Coil Unlock Remaining (ms)
    private func parseSyncData(_ data: Data) -> (persistentDuation: CGFloat, persistentElapsed: CGFloat, coilDuration: CGFloat, coilRemaining: CGFloat) {
        guard data.count >= 16 else { return (0, 0, 0, 0) }
        
        let values: [UInt32] = data.withUnsafeBytes { pointer in
            let buffer = pointer.bindMemory(to: UInt32.self)
            return Array(buffer.prefix(4))
        }
        
        // Convert values from little-endian
        let pDuration = CGFloat(UInt32(littleEndian: values[0]))
        let pElapsed = CGFloat(UInt32(littleEndian: values[1]))
        let cDuration = CGFloat(UInt32(littleEndian: values[2]))
        let cRemaining = CGFloat(UInt32(littleEndian: values[3]))
        
        return (persistentDuation: pDuration, persistentElapsed: pElapsed, coilDuration: cDuration, coilRemaining: cRemaining)
    }
    
    // MARK: - Writing Timer Value
    // Sends a new timer value to the ESP32 via the TIMER characteristic.
    func writeTimerValue(_ value: UInt32) {
        guard let timerChar = timerCharacteristic, let peripheral = peripheral else { return }
        var timerValue = value.littleEndian
        let data = Data(bytes: &timerValue, count: MemoryLayout<UInt32>.size)
        peripheral.writeValue(data, for: timerChar, type: .withResponse)
    }
    
    // MARK: - NTP Time Update
    // Sends the current system time (in ms) to the ESP32 via the NTP characteristic.
    func sendNTPTime() {
        guard let ntpChar = ntpCharacteristic, let peripheral = peripheral else { return }
        let now = Date().timeIntervalSince1970  // current time in seconds
        let now_ms = UInt32(now * 1000)         // convert to milliseconds (32-bit)
        var value = now_ms.littleEndian
        let data = Data(bytes: &value, count: MemoryLayout<UInt32>.size)
        peripheral.writeValue(data, for: ntpChar, type: .withResponse)
    }
    
    
    
    
    private func startKeepAliveTimer() {
        // Schedule timer to call keepAlive() every 30 seconds, for example
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            self.keepAlive()
        }
    }
    
    // MARK: - Keep Alive Read
    // Sends the current system time (in ms) to the ESP32 via the NTP characteristic.
    private func keepAlive() {
        guard let keepAliveChar = keepAliveCharacteristic, let peripheral = peripheral else { return }
        peripheral.readValue(for: keepAliveChar)
    }
}
