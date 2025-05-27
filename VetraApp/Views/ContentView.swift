import SwiftUI

struct ContentView: View {
    @StateObject private var bluetoothManager: BluetoothManager
    @StateObject private var trackerData: TrackerDataModel

    init(bluetoothManager: BluetoothManager = BluetoothManager()) {
        _bluetoothManager = StateObject(wrappedValue: bluetoothManager)
        _trackerData = StateObject(wrappedValue: TrackerDataModel(bluetoothManager: bluetoothManager))
    }

    var body: some View {
        ZStack {
            if bluetoothManager.isConnected {
                // When connected, transition to TrackerView
                TrackerView(trackerData: trackerData)
                    .transition(.slide)
            } else {
                // Otherwise, show the Bluetooth view
                BluetoothView(bluetoothManager: bluetoothManager)
                    .transition(.slide)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: bluetoothManager.isConnected)
    }
}

#Preview {
    ContentView()
}
