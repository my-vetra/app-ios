import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var bridge: SyncBridge? = nil   // we don't need to observe it

    var body: some View {
        ZStack {
            if bluetoothManager.isConnected {
                TrackerView()
                    .transition(.slide)
            } else {
                BluetoothView(bluetoothManager: bluetoothManager)
                    .transition(.slide)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: bluetoothManager.isConnected)
        .onAppear {
            // create once; binds to connectionPublisher internally
            if bridge == nil {
                bridge = SyncBridge(bluetoothManager: bluetoothManager, context: context)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
