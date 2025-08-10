import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @StateObject private var bluetoothManager = BluetoothManager()

    var body: some View {
        ZStack {
            if bluetoothManager.isConnected {
                // Pass the same context into MainView and SyncBridge
                MainView(context: viewContext, bluetoothManager: bluetoothManager)
                    .transition(.slide)
            } else {
                BluetoothView(bluetoothManager: bluetoothManager)
                    .transition(.slide)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: bluetoothManager.isConnected)
    }
}
