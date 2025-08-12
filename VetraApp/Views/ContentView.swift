import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext   // UI reads
    let writerContextProvider: () -> NSManagedObjectContext        // created only when invoked

    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var bridge: SyncBridge? = nil   // we don't need to observe it

    var body: some View {
        ZStack {
            if bluetoothManager.isConnected {
                TrackerView().transition(.slide)
            } else {
//                BluetoothView(bluetoothManager: bluetoothManager).transition(.slide)
                TrackerView().transition(.slide)

            }
        }
        .animation(.easeInOut(duration: 0.35), value: bluetoothManager.isConnected)
        .onReceive(bluetoothManager.connectionPublisher.receive(on: RunLoop.main)) { connected in
                    if connected {
                        if bridge == nil {
                            bridge = SyncBridge(
                                bluetoothManager: bluetoothManager,
                                context: writerContextProvider()
                            )
                        }
                    } else {
                        bridge = nil
                    }
                }
                // Safety: if we mounted after a connection already happened, create once
        .onAppear {
            if bluetoothManager.isConnected && bridge == nil {
                bridge = SyncBridge(
                    bluetoothManager: bluetoothManager,
                    context: writerContextProvider()
                )
            }
        }
    }
}

#Preview {
    let pc = PersistenceController.preview
    return ContentView(writerContextProvider: { pc.writerContext })
        .environment(\.managedObjectContext, pc.container.viewContext)
}
